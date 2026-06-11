import Foundation

/// The within-browser signal for the per-site keyboard-language feature (design D4). A host change
/// inside a browser (switching tabs, navigating `keep.google.com` → `mail.google.com`) emits **no**
/// `NSWorkspace.didActivateApplication` event — the frontmost app never changes — so the engine would
/// never re-evaluate it. This monitor supplies that missing signal: while a supported browser is
/// frontmost it ticks on a timer, and each tick nudges the service to re-resolve its context, so a
/// mid-tab host change is handled exactly like an app switch.
///
/// It mirrors `ClipboardMonitor`: macOS gives no host-change event any more than a clipboard-change
/// one, so both poll on a tunable interval, pause without tearing down the timer, and are fully inert
/// while stopped. The coordinator starts it as the frontmost app enters a supported browser and stops
/// it as the front app leaves one, so it never polls when no browser is front (the existing
/// `didActivateApplication` path still catches plain app switches — design D4).
///
/// Deliberately dumb: it resolves no hosts and knows nothing about context ids. It only asks the cheap
/// registry-backed `isSupportedBrowserFront` whether to act, then fires `onTick`. The real work — read
/// the host, diff against the last context, run learn/apply — lives in `KeyboardLanguageService.reevaluate()`
/// and `ContextResolver`, which the coordinator wires to `onTick`. Keeping resolution out of the monitor
/// means a host change mid-tab and a same-host re-tick both flow through the one engine path.
@MainActor
final class BrowserContextMonitor {
    /// Whether a `BrowserRegistry`-supported browser is currently frontmost. A cheap registry lookup
    /// (no AX/Apple Events read), checked every tick so the monitor does nothing while a non-browser app
    /// is front — that context is the app-activation path's job, not ours.
    private let isSupportedBrowserFront: () -> Bool
    /// Called on each tick where a supported browser is front and we are not paused. The coordinator
    /// wires this to `KeyboardLanguageService.reevaluate()`, which re-resolves the host and runs
    /// learn/apply on a host change (and is a cheap no-op when the host is unchanged).
    private let onTick: () -> Void

    /// Seconds between host re-evaluations. Tunable; restarts the timer on change, like `ClipboardMonitor`.
    var pollInterval: TimeInterval {
        didSet { if timer != nil { restartTimer() } }
    }
    /// Pause ticking without tearing down the timer (the poll early-returns).
    var isPaused = false

    private var timer: Timer?

    /// - Parameters:
    ///   - pollInterval: seconds between ticks (~0.5s, design D4); throttled to a 0.1s floor.
    ///   - isSupportedBrowserFront: a cheap registry check — true when the frontmost app is a supported
    ///     browser. When false the tick does nothing (the app-activation path handles non-browser context).
    ///   - onTick: invoked each active tick; wired to `KeyboardLanguageService.reevaluate()`.
    init(pollInterval: TimeInterval = 0.5,
         isSupportedBrowserFront: @escaping () -> Bool,
         onTick: @escaping () -> Void) {
        self.pollInterval = pollInterval
        self.isSupportedBrowserFront = isSupportedBrowserFront
        self.onTick = onTick
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: max(0.1, pollInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer = t
    }

    /// One tick: skip while paused; skip while no supported browser is front (that's the app-activation
    /// path's domain — when no browser is front there is no within-browser host to re-resolve). Otherwise
    /// fire `onTick` and let the service's `reevaluate()` + `ContextResolver` do the resolving and diffing.
    private func poll() {
        guard !isPaused else { return }
        guard isSupportedBrowserFront() else { return }
        onTick()
    }
}
