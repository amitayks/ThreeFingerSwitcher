import AppKit
import Carbon.OpenScripting   // errAEEventNotPermitted

/// The opt-in `HostProvider`: reads the **exact** active-tab URL via in-process Apple Events and parses
/// it to a host (design D3 / D5). This is the only path to exact per-host on Safari — where the AX
/// reader sees just the registrable domain (design D7) — and it gives the full host on Chromium too.
/// It is gated behind the "allow browser control" opt-in because it requires the per-browser Automation
/// permission; the `AppCoordinator` only injects this provider when that opt-in is on.
///
/// **In-process, never `osascript`.** We compile one `NSAppleScript` *per `BrowserFamily`* up front and
/// reuse it, parameterizing only the target by bundle id — so a poll tick is one cached-script execution,
/// not a subprocess spawn. The two families speak different tab vocabulary: Chromium → `active tab of
/// front window`, Safari → `current tab of front window` (design D5).
///
/// **Permission degrades silently (design D5 / risk table).** If `executeAndReturnError` fails for any
/// reason — most importantly `errAEEventNotPermitted` (-1743), the not-yet-granted / denied Automation
/// state — we return nil. nil is the caller's signal to fall back to the AX reader, so a denied grant
/// never blocks and never shows a modal; it just quietly downgrades to the no-permission path. The first
/// real read is what surfaces the system's one-time Automation consent prompt (lazy, design D8 / 6.3).
@MainActor
final class AppleEventsHostProvider: HostProvider {

    /// One compiled script per **bundle id**, built lazily on first use and reused thereafter (the cache
    /// the "compile once, don't re-spawn" contract rests on). Keyed by bundle id, not family, because the
    /// script targets the exact browser by `application id` — so each Chromium fork (Brave/Edge/Arc/…)
    /// scripts itself, not a hardcoded Chrome.
    private var compiled: [String: NSAppleScript] = [:]

    /// Negative-result backoff for a FAILED Apple Event, keyed by bundle id: the Automation grant denied
    /// or undetermined, no front window, a browser that isn't answering (the 2 s script timeout). Each
    /// failure is a synchronous main-thread round-trip that the 0.5 s poll would otherwise repeat forever;
    /// a miss holds the read for 2 s, doubling per consecutive miss up to 30 s. A script that ANSWERS —
    /// even with a non-web URL (`chrome://newtab`, `about:blank`) — is a hit: the browser is responsive
    /// and the next navigation must be seen promptly. An app switch (`noteAppSwitch`) clears the hold.
    private var readBackoff = HostReadBackoff()

    init() {}

    /// Read `bundleID`'s exact active-tab host via Apple Events, normalized through `HostNormalizer`, or
    /// nil. nil covers every degradation — unsupported/unknown browser, the Automation permission denied
    /// or undetermined, no front window/tab, a non-URL result, or a private window — so the caller
    /// silently falls back to the AX reader. Never throws, never alerts; a stalled browser holds the main
    /// thread for at most the script's own 2 s timeout, and a failure is not retried on every tick.
    func host(forBrowser bundleID: String) -> String? {
        guard let family = BrowserRegistry.family(for: bundleID),
              let script = script(for: bundleID, family: family) else { return nil }
        guard !readBackoff.shouldSkip(bundleID, now: Date()) else { return nil }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        // Any error → nil (fall back to AX). `errAEEventNotPermitted` (-1743) is the denied/undetermined
        // Automation grant; we don't special-case it beyond logging, since every error degrades the same.
        if let error {
            logIfUnexpected(error, bundleID: bundleID)
            readBackoff.recordMiss(bundleID, now: Date())
            return nil
        }
        readBackoff.recordHit()
        guard let urlString = descriptor.stringValue else { return nil }
        return host(fromURL: urlString)
    }

    /// An app activation: forget the read backoff so the fresh visit re-tries the Apple Event once.
    func noteAppSwitch() {
        readBackoff.reset()
    }

    // MARK: - Script cache

    /// The cached compiled script for `bundleID`, compiling and storing it on first request. A script that
    /// fails to compile (it shouldn't — the source is a constant template) yields nil and the read returns nil.
    private func script(for bundleID: String, family: BrowserFamily) -> NSAppleScript? {
        if let existing = compiled[bundleID] { return existing }
        guard let script = NSAppleScript(source: Self.source(bundleID: bundleID, family: family)) else { return nil }
        compiled[bundleID] = script
        return script
    }

    /// The AppleScript text targeting `bundleID` exactly (`application id`) — so each Chromium fork scripts
    /// itself (Brave/Edge/Arc/Vivaldi, not a hardcoded Chrome) — and asking only for the active tab's URL,
    /// never history, page content, or any other property (privacy: read the host and nothing else). The
    /// tab vocabulary differs by family: Chromium says "active tab", Safari says "current tab".
    ///
    /// The `with timeout` block bounds the synchronous Apple Event: without it AppleScript waits the
    /// default ~60 s for a reply, so a browser that is hung, mid-launch, or blocked on its own modal would
    /// hold OUR main thread — the gesture → switcher path — for a minute per poll tick. A timeout is an
    /// ordinary script error here (→ nil, backed off), not a fault.
    private static func source(bundleID: String, family: BrowserFamily) -> String {
        let tab = (family == .safari) ? "current tab" : "active tab"
        return """
        set tabURL to missing value
        with timeout of \(Int(replyTimeout)) seconds
            tell application id "\(bundleID)" to set tabURL to URL of \(tab) of front window
        end timeout
        return tabURL
        """
    }

    /// How long one Apple Event may wait for the browser's reply before the read gives up (→ nil).
    static let replyTimeout: TimeInterval = 2

    // MARK: - Parsing

    /// Parse an active-tab URL string to a normalized host. `URLComponents.host` strips scheme/path/query
    /// for us; `HostNormalizer` then lowercases and `www.`-strips it. A non-`http(s)` internal page
    /// (`chrome://`, `about:blank`, a `file://` URL) yields no usable host and resolves to nil → app-level.
    private func host(fromURL urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host else { return nil }
        return HostNormalizer.normalize(host)
    }

    // MARK: - Logging

    /// Log only genuinely unexpected Apple Events errors; the permission-denied case (`errAEEventNotPermitted`,
    /// -1743) is the *expected* pre-grant state during the lazy opt-in, so it's logged at most as a one-line
    /// note rather than treated as a fault. Raw error text stays in logs only — never surfaced in UI.
    private func logIfUnexpected(_ error: NSDictionary, bundleID: String) {
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        guard code != Int(errAEEventNotPermitted) else { return }
        NSLog("[ThreeFingerSwitcher] keyboard-language: Apple Events host read for \(bundleID) failed (code \(code)); falling back to Accessibility.")
    }
}
