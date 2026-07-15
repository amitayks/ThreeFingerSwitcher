import Foundation
import CoreGraphics

/// The pure reveal/keep/grace-dismiss brain for the notch home-zone rail (design §8), mirroring
/// `DockHoverModel`: a unified zone+rail live area with a grace-period dismiss, `now:` injected so every
/// transition is deterministically testable. Owns NO AppKit, NO timers. Coordinates are Cocoa global.
/// MLX-free Core.
final class NotchRevealModel {
    /// How long the cursor may sit outside the live zone before the rail dismisses — bridges the travel
    /// from the zone to the rail (or a brief edge slip) without a flicker.
    let graceInterval: TimeInterval

    /// A small DWELL the cursor must stay continuously inside the reveal trigger before the rail reveals —
    /// so a quick pass THROUGH the notch (reaching for the menu bar, travelling to another corner) doesn't
    /// pop the dock. `0` reveals immediately. Runtime-settable from the Hub. Applies to the hidden→shown
    /// transition ONLY (keep-open is instant). While a dwell is pending, `feed` returns `.idle`.
    var dwellInterval: TimeInterval

    enum State: Equatable { case hidden, shown }
    enum Decision: Equatable {
        /// Nothing shown; ensure the rail is closed.
        case idle
        /// Reveal/keep the rail.
        case reveal
        /// Close the rail (grace elapsed after leaving the live zone).
        case dismiss
    }

    private(set) var state: State = .hidden
    private var graceDeadline: TimeInterval?
    private var dwellDeadline: TimeInterval?

    /// True while a reveal dwell is counting down (cursor is in the trigger but the dwell hasn't elapsed) —
    /// the controller keeps its re-feed timer alive on this so a perfectly still cursor still reveals.
    var isDwelling: Bool { dwellDeadline != nil }

    init(graceInterval: TimeInterval = 0.25, dwellInterval: TimeInterval = 0) {
        self.graceInterval = graceInterval
        self.dwellInterval = dwellInterval
    }

    /// Advance the lifecycle for a cursor sample.
    /// - Parameters:
    ///   - cursor: cursor position (Cocoa global).
    ///   - zoneRect: the resting home-zone rect (the reveal trigger).
    ///   - railFrame: the shown rail's frame, or nil when not shown.
    ///   - liveZone: the ONE contiguous live/hit region (zone + connecting band + container, extended up
    ///     into the notch pixels — `NotchHomeZoneAnchor.liveZoneRect`). A cursor anywhere inside it KEEPS
    ///     the rail open, so moving UP into the notch (the docking target) never grace-dismisses. Defaults
    ///     to nil so existing callers/tests fall back to the zone+rail union (no contiguous band).
    ///   - now: a monotonic timestamp (seconds); injected so grace timing is testable.
    func feed(cursor: CGPoint,
              zoneRect: CGRect,
              railFrame: CGRect?,
              liveZone: CGRect? = nil,
              now: TimeInterval) -> Decision {
        // 1. Cursor over the reveal trigger.
        if zoneRect.contains(cursor) {
            graceDeadline = nil
            // Already shown → keep open instantly (no dwell for keep-open).
            if state == .shown {
                dwellDeadline = nil
                return .reveal
            }
            // Hidden → require a short DWELL first, so a quick pass THROUGH the notch doesn't pop the dock.
            if dwellInterval <= 0 {
                dwellDeadline = nil
                state = .shown
                return .reveal
            }
            let deadline = dwellDeadline ?? (now + dwellInterval)
            dwellDeadline = deadline
            if now >= deadline {
                dwellDeadline = nil
                state = .shown
                return .reveal
            }
            return .idle                 // still dwelling — nothing shown yet
        }
        // Cursor left the trigger before the dwell elapsed → cancel it (a fresh entry restarts the dwell).
        dwellDeadline = nil
        // 2. Cursor anywhere in the contiguous live zone while shown (the rail, the connecting band, OR the
        //    notch pixels above the zone) → keep it open. Falls back to the rail frame when no live zone is
        //    supplied. This is the "move into the notch docks instead of dismisses" guarantee (design D5).
        if state == .shown {
            if let liveZone, liveZone.contains(cursor) {
                graceDeadline = nil
                return .reveal
            }
            if let railFrame, railFrame.contains(cursor) {
                graceDeadline = nil
                return .reveal
            }
        }
        // 3. Outside the live zone.
        guard state == .shown else { return .idle }
        let deadline = graceDeadline ?? (now + graceInterval)
        graceDeadline = deadline
        if now >= deadline {
            state = .hidden
            graceDeadline = nil
            return .dismiss
        }
        return .reveal
    }
}
