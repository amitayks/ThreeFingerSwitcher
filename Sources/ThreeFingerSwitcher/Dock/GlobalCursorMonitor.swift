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

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightGlobalMonitor: Any?
    private var rightLocalMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.onMove?(NSEvent.mouseLocation)
        }
        // The local monitor must return the event so normal delivery (hover/click in the popup) continues.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.onMove?(NSEvent.mouseLocation)
            return event
        }
        // Right-click: PASSIVE only. The global monitor observes the right-click delivered to Dock.app
        // (it cannot consume it → the native Dock action menu still opens unmodified); the local one
        // covers a right-click into our own panel. Both just report the location.
        let rightMask: NSEvent.EventTypeMask = [.rightMouseDown]
        rightGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: rightMask) { [weak self] _ in
            self?.onRightClick?(NSEvent.mouseLocation)
        }
        rightLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: rightMask) { [weak self] event in
            self?.onRightClick?(NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        if let g = rightGlobalMonitor { NSEvent.removeMonitor(g); rightGlobalMonitor = nil }
        if let l = rightLocalMonitor { NSEvent.removeMonitor(l); rightLocalMonitor = nil }
    }

    deinit {
        // NSEvent.removeMonitor is safe off-main; avoids capturing self in a main-actor hop during dealloc.
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        if let g = rightGlobalMonitor { NSEvent.removeMonitor(g) }
        if let l = rightLocalMonitor { NSEvent.removeMonitor(l) }
    }
}
