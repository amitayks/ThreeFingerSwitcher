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
    /// Low-frequency health watchdog. The `tapDisabledByTimeout` self-heal in `handle` is delivered
    /// through the tap itself, so once the system disables the tap under main-thread congestion the
    /// re-enable only runs when the NEXT event limps through — the first post-stall gesture is
    /// silently dropped ("the trigger needs to wake up"). This timer re-enables independently of
    /// event delivery, bounding a dead tap to one watchdog interval.
    private var watchdog: Timer?
    private static let watchdogInterval: TimeInterval = 2.0

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
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveIfDisabled() }
        }
        watchdog?.tolerance = Self.watchdogInterval / 2   // cheap check; let the OS coalesce it
        // `.common` so a revive isn't deferred for as long as a menu or drag keeps the run loop in a
        // tracking mode (the tap source itself is already in `.commonModes`).
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning else { return }
        watchdog?.invalidate()
        watchdog = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Destroy the mach receive right deterministically — the gate refreshes cycle
            // start/stop on every toggle flip, and relying on CF dealloc leaves port teardown
            // timing to autorelease.
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        isRunning = false
    }

    private func reviveIfDisabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
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
