import AppKit
import CoreGraphics

/// The production `CursorMonitor`: a **passive** global + local `.mouseMoved` monitor. The global monitor
/// observes moves delivered to other apps (the cursor traveling over the Dock / desktop); the local
/// monitor covers moves over our own overlay panel. Both report `NSEvent.mouseLocation` (Cocoa global).
///
/// Observing mouse-moved needs **no new permission** (it is not keystroke logging — Input Monitoring is
/// not required), matching the feature's "no new permission" contract. The monitor is installed only while
/// the feature is enabled (`start`/`stop` off the opt-in). It does no work beyond forwarding the point —
/// the controller decides when to actually read the Dock (edge-gated), so idle cost stays negligible.
@MainActor
final class GlobalCursorMonitor: CursorMonitor {
    var onMove: ((CGPoint) -> Void)?
    var onRightClick: ((CGPoint) -> Void)?
    /// Passive left-button observation: report-only, never consumed — the click/drag reaches its app
    /// unmodified, exactly like the right-click pair. Consumers: window-groups snap (drag-end detection,
    /// down+up) and the Dock preview (commit-on-icon-click, down only).
    var onLeftDown: ((CGPoint) -> Void)?
    var onLeftUp: ((CGPoint) -> Void)?

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        // Right-click: PASSIVE only. The global monitor observes the right-click delivered to Dock.app
        // (it cannot consume it → the native Dock action menu still opens unmodified); the local one
        // covers a right-click into our own panel. Both just report the location. Left down/up follow
        // the same report-only contract (drag-end detection for snap-to-bind).
        //
        // The move-monitor pair (the only high-frequency one — it fires per cursor sample) is
        // installed only when a consumer actually wired `onMove`: the window-groups snap monitor
        // uses just down/up, and 4 per-move monitors firing into a nil closure is pure overhead.
        if onMove != nil {
            install([.mouseMoved, .leftMouseDragged]) { [weak self] in self?.onMove?($0) }
        }
        install([.rightMouseDown]) { [weak self] in self?.onRightClick?($0) }
        install([.leftMouseDown]) { [weak self] in self?.onLeftDown?($0) }
        install([.leftMouseUp]) { [weak self] in self?.onLeftUp?($0) }
    }

    /// Install the passive global + local monitor pair for one mask. The local monitor must return the
    /// event so normal delivery (hover/click in our own panels) continues.
    private func install(_ mask: NSEvent.EventTypeMask, report: @escaping (CGPoint) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            report(NSEvent.mouseLocation)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            report(NSEvent.mouseLocation)
            return event
        }) { monitors.append(l) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    deinit {
        // NSEvent.removeMonitor is safe off-main; avoids capturing self in a main-actor hop during dealloc.
        monitors.forEach { NSEvent.removeMonitor($0) }
    }
}
