import AppKit

/// Passive "any human input" watcher for Keep Awake's guard: global + local `NSEvent` monitors over
/// mouse moves/clicks, key-downs, and modifier presses (the `GlobalCursorMonitor` precedent — key-down
/// global monitoring rides the already-granted Accessibility permission; nothing is consumed).
///
/// Deliberate exclusions (design D2):
/// - **Trackpad contacts are not monitored here** — the raw touch stream (`KeepAwakeController.noteTouch`)
///   already stops the session on any contact, sooner and more reliably.
/// - **`scrollWheel` is excluded** so a momentum tail from the firing gesture can't self-trip the guard
///   at arm time; a stranger using a mouse fires `mouseMoved` before any scroll anyway.
/// - **Events synthesized by THIS process are filtered by source PID** — the computer-use agent acts by
///   posting CGEvents, and the guard must never lock the screen out from under an acting agent.
///   Hardware events carry source PID 0 and pass.
@MainActor
final class InputActivityMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let mask: NSEvent.EventTypeMask =
        [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]

    /// True for an event posted by this very process (agent-synthesized) — never trips the guard.
    private static func isSelfSynthesized(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return cg.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
    }

    /// `onInput` fires once per observed human input; the caller decides what to do (and typically
    /// tears this monitor down first thing).
    init(onInput: @escaping () -> Void) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { event in
            guard !Self.isSelfSynthesized(event) else { return }
            MainActor.assumeIsolated { onInput() }
        }
        // Global monitors never see events routed to our own app (e.g. the Hub is frontmost);
        // the local monitor covers that, returning the event unmodified (non-consuming).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { event in
            if !Self.isSelfSynthesized(event) {
                MainActor.assumeIsolated { onInput() }
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit {
        // Backstop (the GlobalCursorMonitor precedent): `removeMonitor` is safe off-main, and a
        // skipped `stop()` must never leave two process-wide input monitors installed forever.
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
