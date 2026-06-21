import CoreGraphics

/// The pure brain of the interactive screen-region picker (spec `screen-region-picker`): a synchronous,
/// AppKit-free state machine that turns a press → drag → release into either a designated rectangle to
/// capture or a **cancel**. The AppKit `RegionPickerOverlay` feeds it mouse events and renders its
/// `liveRect`; keeping the geometry and the click-vs-drag verdict here makes both unit-testable headless
/// (no overlay, no ScreenCaptureKit), mirroring how `DockHoverModel` is the pure brain under the Dock
/// preview overlay.
///
/// Coordinates are **Cocoa global (bottom-left origin)** throughout — the overlay converts at the
/// boundary so the model never juggles handedness, matching the project convention (`DockHoverModel`).
struct RegionPickerModel: Equatable {

    /// Below this straight-line drag distance (in points) a release is a **click, not a drag** → cancel.
    /// This is the single "click-without-drag cancels" threshold (spec): a press-and-release that barely
    /// moves defuses the picker, matching the ⌘⇧4 muscle memory of pressing without dragging. Small
    /// enough that any deliberate drag clears it, large enough that an unsteady click does not.
    static let minDragDistance: CGFloat = 6

    /// The press anchor; nil when no drag is in progress.
    private(set) var origin: CGPoint?
    /// The latest pointer position during a drag; nil when no drag is in progress.
    private(set) var current: CGPoint?

    /// The resolution of a completed pick.
    enum Resolution: Equatable {
        /// Capture this rectangle (Cocoa global coords).
        case region(CGRect)
        /// A click without a drag — defuse the picker, capture nothing.
        case cancel
    }

    /// The live selection rectangle to draw while dragging, or nil when no drag is in progress.
    var liveRect: CGRect? {
        guard let origin, let current else { return nil }
        return Self.rect(from: origin, to: current)
    }

    /// Begin a drag at `point` (mouse-down): anchor the origin.
    mutating func begin(at point: CGPoint) {
        origin = point
        current = point
    }

    /// Track the pointer during a drag (mouse-dragged). A no-op if no drag is in progress.
    mutating func drag(to point: CGPoint) {
        guard origin != nil else { return }
        current = point
    }

    /// Resolve the pick at `point` (mouse-up) and reset for the next drag. A release whose straight-line
    /// travel from the origin is below `minDragDistance` is a **cancel** (a click); otherwise the
    /// designated rectangle. A release with no in-progress drag is also a cancel.
    mutating func end(at point: CGPoint) -> Resolution {
        defer { origin = nil; current = nil }
        guard let origin else { return .cancel }
        let dx = point.x - origin.x, dy = point.y - origin.y
        if (dx * dx + dy * dy).squareRoot() < Self.minDragDistance {
            return .cancel   // pressed without dragging → defuse, capture nothing
        }
        return .region(Self.rect(from: origin, to: point))
    }

    /// The normalized rectangle spanned by two points (handles any drag direction).
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
