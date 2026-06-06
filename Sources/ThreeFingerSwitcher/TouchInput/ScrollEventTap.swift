import CoreGraphics
import Foundation

/// A session-level `CGEventTap` that consumes scroll-wheel events. While the three-finger vertical
/// gesture is freed at the OS level (`VerticalGestureConfig`) it becomes a plain scroll, which would
/// otherwise leak to the window under the cursor — scrolling the background while the switcher uses
/// the same fingers for Space-row switching, or while we synthesize Mission Control. This tap
/// swallows that scroll, gated by a caller-supplied predicate (the coordinator consumes whenever
/// three or more fingers are down, so two-finger scrolling is untouched).
///
/// Requires only Accessibility — the permission the app already holds for window raising (verified:
/// an active consuming session tap creates with Accessibility alone; Input Monitoring is not
/// needed). The callback runs on the main run loop, so it can read `@MainActor` state directly. The
/// system disables a tap whose callback stalls or whose input is interrupted; we re-enable on
/// `tapDisabledByTimeout` / `tapDisabledByUserInput`.
@MainActor
final class ScrollEventTap {
    /// Return true to CONSUME (swallow) the current scroll event. Called on the main thread per event.
    var consumePredicate: (() -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private(set) var isRunning = false

    /// Start the tap. Returns false if it couldn't be created (e.g. Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ScrollEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,           // active tap: can consume
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: selfPtr) else {
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap if our callback stalls or input is interrupted; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        return (consumePredicate?() ?? false) ? nil : Unmanaged.passUnretained(event)
    }
}
