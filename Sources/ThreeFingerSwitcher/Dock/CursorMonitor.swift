import Foundation
import CoreGraphics

/// The seam onto global cursor tracking. The Dock has no "icon hovered" event, so hover is detected by
/// watching the cursor and hit-testing it against the Dock tile frames. This protocol abstracts the
/// source so a fake can drive the controller in tests (and so the real AppKit monitor is swappable).
///
/// `onMove` is called with the cursor in **Cocoa global coordinates** (bottom-left origin) — the same
/// space as `DockTile.frame`. `start()` installs the monitor; `stop()` removes it. Installed ONLY while
/// the feature is enabled (the controller calls `start`/`stop` off the opt-in toggle).
protocol CursorMonitor: AnyObject {
    var onMove: ((CGPoint) -> Void)? { get set }
    /// A right-click (anywhere) reported in Cocoa global coordinates. Observed passively — used to yield
    /// the preview to the Dock's native action menu when the click lands on a tile.
    var onRightClick: ((CGPoint) -> Void)? { get set }
    func start()
    func stop()
}

/// A manually-driven `CursorMonitor` for unit tests: call `emit(_:)` / `emitRightClick(_:)` to simulate.
final class ManualCursorMonitor: CursorMonitor {
    var onMove: ((CGPoint) -> Void)?
    var onRightClick: ((CGPoint) -> Void)?
    private(set) var running = false
    func start() { running = true }
    func stop() { running = false }
    /// Simulate a cursor move (no-op while stopped, matching the real monitor).
    func emit(_ point: CGPoint) {
        guard running else { return }
        onMove?(point)
    }
    /// Simulate a right-click (no-op while stopped, matching the real monitor).
    func emitRightClick(_ point: CGPoint) {
        guard running else { return }
        onRightClick?(point)
    }
}
