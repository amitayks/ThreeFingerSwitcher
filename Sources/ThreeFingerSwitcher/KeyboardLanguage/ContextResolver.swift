import Foundation

/// Maps the frontmost app to the engine's **context id** — the single string key the generalized
/// `KeyboardLanguageService` learns/applies against (design D1). This is the one place that decides
/// whether a context is app-level (the bare bundle id) or site-level (`bundleID|host`), so the engine
/// above it stays context-agnostic: it just sees keys and never knows a browser from a plain app.
///
/// The resolution rule is a strict gate, narrowest path last (design D4):
/// 1. No frontmost bundle id → no context (nil) — there is nothing to key on.
/// 2. The per-site sub-toggle is off, OR the app isn't a `BrowserRegistry`-supported browser → the
///    context **is** the bundle id, byte-for-byte the per-app behavior (a plain app's context id always
///    equals its bundle id, which is why every per-app test still passes unchanged).
/// 3. A supported browser with per-site on → ask the `HostProvider` for the active host; if it resolves,
///    the context is `ContextKey.make(bundleID:host:)`; if it returns nil (unreadable, private/incognito,
///    address bar being typed, or no Automation grant) we fall back to the **app-level** bundle id rather
///    than guess — memory is never learned under a wrong key (design D4 / risk table).
///
/// Pure of any TIS/Carbon dependency; the one side effect (the host read) is isolated behind the
/// injected `HostProvider` seam, so the resolver is testable against a `FakeHostProvider`.
@MainActor
final class ContextResolver {
    /// The active-host reader. **Mutable** so the `AppCoordinator` can swap the AX reader for the
    /// Apple Events reader (and back) when the "allow browser control" opt-in flips, without rebuilding
    /// the resolver or the service it feeds (design D3/D8).
    var hostProvider: HostProvider

    /// Whether the per-site sub-toggle is on. Read fresh on each resolve (a closure, not a captured
    /// bool) so flipping the toggle takes effect on the very next context resolution with no re-wiring.
    private let perSiteEnabled: () -> Bool

    /// - Parameters:
    ///   - hostProvider: the active-host reader (AX by default, Apple Events when opted in); swappable
    ///     in place via the `hostProvider` property when the opt-in changes.
    ///   - perSiteEnabled: reads the per-site sub-toggle live; when false the resolver produces app-level
    ///     context ids only, so browsers behave exactly like any other app (the per-app path).
    init(hostProvider: HostProvider, perSiteEnabled: @escaping () -> Bool) {
        self.hostProvider = hostProvider
        self.perSiteEnabled = perSiteEnabled
    }

    /// The context id for the app whose bundle id is `bundleID` (the frontmost app), or nil when there
    /// is no bundle id to key on. See the type doc for the full gate; the short version: a normal app or
    /// the per-site-off case resolves to the bundle id, a supported browser with a readable host resolves
    /// to `bundleID|host`, and an unreadable browser host degrades to the app-level bundle id.
    func contextID(forFrontmost bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        // Per-site off, or not a browser we support → app-level context (unchanged per-app behavior).
        guard perSiteEnabled(), BrowserRegistry.isSupported(bundleID) else { return bundleID }
        // Supported browser, per-site on: scope to the host if we can read one, else degrade to app-level.
        guard let host = hostProvider.host(forBrowser: bundleID) else { return bundleID }
        return ContextKey.make(bundleID: bundleID, host: host)
    }
}
