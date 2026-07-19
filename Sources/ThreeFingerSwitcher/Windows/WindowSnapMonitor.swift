import AppKit
import CoreGraphics
import os

private let snapLog = Logger(subsystem: "ThreeFingerSwitcher", category: "WindowGroups")

/// Detects "a window drag ended edge-flush against another window" — the snap-to-bind trigger for
/// window groups. Passive by construction: a `GlobalCursorMonitor` left-down/left-up pair (report-only,
/// never consumed, no new permission) plus CGWindowList frame reads.
///
///   left-down ─► record the window under the cursor + its frame (one point hit-test)
///   left-up ───► did that window's frame change (move OR resize — macOS snaps both)?
///        │ yes
///        ▼ (after `settleDelay` — the magnetic snap ANIMATES the window into its final frame
///           after release, so an immediate read catches the mid-flight frame; a first read that
///           finds NO contact re-checks once more after `lateSettleDelay` for slow animations)
///   scan current on-screen windows for edge adjacency ─► `WindowGroupStore.dragSettled`
///
/// All geometry stays in ONE coordinate space (CG top-left global) — the Cocoa mouse location is
/// converted at entry. Installed only while the window-groups opt-in is on (`setEnabled`), the
/// Dock-preview `setEnabled` idiom; disabling also clears the store (re-enabling never resurrects
/// stale groups). Every stage logs to the "WindowGroups" category so the pipeline is observable via
/// `log stream` on a user machine.
@MainActor
final class WindowSnapMonitor {
    private let cursor = GlobalCursorMonitor()
    private let store: WindowGroupStore
    /// The recorded left-down hit: the window under the cursor and its frame at press time.
    private var pressed: (id: CGWindowID, frame: CGRect)?
    private var settleWork: DispatchWorkItem?
    /// How long after mouse-up to read the settled frame (the snap animates into place on release).
    /// Mirrors the Dock-preview capture-settle idiom; cancellable by a new press or disable.
    var settleDelay: TimeInterval = 0.3
    /// Second-chance delay when the first settled read finds no contact — a slow snap animation can
    /// still be in flight at the first read. Applied once; a read that finds contact never re-runs
    /// (so a late read can never UNDO a bind the first one made).
    var lateSettleDelay: TimeInterval = 0.8

    init(store: WindowGroupStore) {
        self.store = store
        cursor.onLeftDown = { [weak self] point in self?.leftDown(at: point) }
        cursor.onLeftUp = { [weak self] point in self?.leftUp(at: point) }
    }

    func setEnabled(_ enabled: Bool) {
        snapLog.log("snap monitor setEnabled(\(enabled, privacy: .public))")
        if enabled {
            cursor.start()
        } else {
            cursor.stop()
            settleWork?.cancel()
            settleWork = nil
            pressed = nil
            store.clear()
        }
    }

    // MARK: - Event flow

    private func leftDown(at cocoaPoint: CGPoint) {
        settleWork?.cancel()
        settleWork = nil
        let point = Self.cgPoint(fromCocoa: cocoaPoint)
        pressed = Self.window(at: point, in: Self.onScreenWindows())
        if let pressed {
            snapLog.debug("down: window \(pressed.id) frame \(Self.fmt(pressed.frame), privacy: .public)")
        } else {
            snapLog.debug("down: no layer-0 window under cursor \(Self.fmt(point), privacy: .public)")
        }
    }

    private func leftUp(at _: CGPoint) {
        let pressed = self.pressed
        self.pressed = nil
        // The full drag evaluation runs only when the pressed window demonstrably changed frame. But a
        // border-grab RESIZE often can't be attributed to the right window at all — the grab zone sits
        // a few pixels OUTSIDE the frame (or inside the flush NEIGHBOR, which then reads "unchanged") —
        // so whenever groups exist, every mouse-up at least re-checks their geometry (`pruneDetached`):
        // members that no longer touch have detached, regardless of who we thought was dragged.
        if let pressed, let now = Self.frame(of: pressed.id), Self.changed(pressed.frame, now) {
            snapLog.log("up: window \(pressed.id) moved \(Self.fmt(pressed.frame), privacy: .public) -> \(Self.fmt(now), privacy: .public); settling \(self.settleDelay)s")
            schedule(after: settleDelay) { [weak self] in
                self?.evaluateSettled(window: pressed.id, retryOnEmpty: true)
            }
        } else if !store.groups.isEmpty {
            snapLog.debug("up: no attributable drag; geometry re-check for \(self.store.groups.count) group(s)")
            schedule(after: settleDelay) { [weak self] in
                self?.settleWork = nil
                self?.pruneDetachedGroups()
            }
        }
    }

    /// Re-check every group's members for actual edge contact under current frames, dropping what
    /// has detached (connected-component split in the store).
    private func pruneDetachedGroups() {
        guard !store.groups.isEmpty else { return }
        let frames = Dictionary(Self.onScreenWindows().map { ($0.id, $0.frame) }) { first, _ in first }
        if store.pruneDetached(frames: frames) {
            snapLog.log("prune: geometry changed -> groups \(self.store.groups.map { $0.sorted() }, privacy: .public)")
        }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Read the settled frames and resolve the drag: which windows does the dragged one now sit
    /// edge-flush against? When the first read finds nothing, one late re-read catches a snap
    /// animation that was still in flight (a contact-finding read never re-runs, so the late read
    /// can never undo a bind).
    private func evaluateSettled(window id: CGWindowID, retryOnEmpty: Bool) {
        settleWork = nil
        let windows = Self.onScreenWindows()
        guard let dragged = windows.first(where: { $0.id == id }) else {
            snapLog.log("settle: dragged window \(id) gone (closed mid-settle)")
            return
        }
        var snapped: Set<CGWindowID> = []       // flush edges: the BIND trigger
        var attached: Set<CGWindowID> = []      // flush OR overlapping: the STAY-BOUND contact
        for other in windows where other.id != id {
            let d = SnapAdjacency.diagnostic(dragged.frame, other.frame)
            // Log every near-miss so tolerance tuning has real numbers from real machines.
            if min(d.horizontalGap, d.verticalGap) <= 100 {
                snapLog.debug("settle: candidate \(other.id) hGap \(Int(d.horizontalGap)) (vShared \(Int(d.verticalShared))) vGap \(Int(d.verticalGap)) (hShared \(Int(d.horizontalShared)))")
            }
            if SnapAdjacency.adjacent(dragged.frame, other.frame) { snapped.insert(other.id) }
            if SnapAdjacency.attached(dragged.frame, other.frame) { attached.insert(other.id) }
        }
        if snapped.isEmpty, attached.isEmpty, retryOnEmpty {
            snapLog.log("settle: window \(id) no contact yet; late re-check in \(self.lateSettleDelay)s")
            schedule(after: lateSettleDelay) { [weak self] in
                self?.evaluateSettled(window: id, retryOnEmpty: false)
            }
            return
        }
        store.dragSettled(window: id, snapped: snapped, attached: attached)
        // A drag can detach OTHER members than the dragged one (shoving a window through a cluster,
        // or a resize mis-attributed to a window that DID move) — geometry is the arbiter for all.
        store.pruneDetached(frames: Dictionary(windows.map { ($0.id, $0.frame) }) { first, _ in first })
        snapLog.log("settle: window \(id) snapped \(snapped.sorted(), privacy: .public) attached \(attached.sorted(), privacy: .public) -> groups \(self.store.groups.map { $0.sorted() }, privacy: .public)")
    }

    // MARK: - CGWindowList reads (one coordinate space: CG top-left global)

    private struct OnScreenWindow {
        let id: CGWindowID
        let frame: CGRect
    }

    /// Current-Space, layer-0 (normal) on-screen windows, front-to-back, excluding our own app and
    /// non-window debris (fully transparent helpers, sub-50pt fragments) that would otherwise steal
    /// the point hit-test. `optionOnScreenOnly` is inherently current-Space — exactly the population
    /// a snap can bind.
    private static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let selfPid = getpid()
        var result: [OnScreenWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != selfPid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 50, bounds.height >= 50,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { continue }
            result.append(OnScreenWindow(id: id, frame: bounds))
        }
        return result
    }

    private static func window(at point: CGPoint, in windows: [OnScreenWindow]) -> (id: CGWindowID, frame: CGRect)? {
        // The list is front-to-back: the first hit is the window the press actually landed in.
        guard let hit = windows.first(where: { $0.frame.contains(point) }) else { return nil }
        return (hit.id, hit.frame)
    }

    /// The window's current frame, re-read through the SAME on-screen enumeration the hit-test uses
    /// (one option set, one coordinate space). Deliberately NOT `CGWindowListCreateDescriptionFromArray`:
    /// that legacy API expects each array element to be the raw window ID cast directly into the
    /// pointer slot — `[id] as CFArray` bridges to CFNumbers, which it silently fails to unbox,
    /// returning nil for EVERY window (the documented landmine `WindowService.windowIDArray` exists
    /// to avoid; here the enumeration is simpler than the pointer-cast dance).
    private static func frame(of id: CGWindowID) -> CGRect? {
        onScreenWindows().first { $0.id == id }?.frame
    }

    private static func changed(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > 1 || abs(a.origin.y - b.origin.y) > 1
            || abs(a.width - b.width) > 1 || abs(a.height - b.height) > 1
    }

    /// Cocoa global (bottom-left origin, from `NSEvent.mouseLocation`) → CG global (top-left origin).
    /// The flip is against the PRIMARY screen (the one containing (0,0) in Cocoa space).
    private static func cgPoint(fromCocoa p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    private static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    private static func fmt(_ p: CGPoint) -> String {
        "(\(Int(p.x)),\(Int(p.y)))"
    }
}
