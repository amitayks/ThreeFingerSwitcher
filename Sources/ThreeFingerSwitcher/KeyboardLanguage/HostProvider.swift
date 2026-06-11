import Foundation

/// The seam isolating the impure "what host is the frontmost browser showing?" read from the pure
/// Core resolution logic (design D3). Reading the active host is the one side effect the per-site
/// feature adds on top of the per-app engine, and it is inherently best-effort and backend-specific —
/// the Accessibility tree varies per browser, Apple Events needs an opt-in grant — so it lives behind
/// this protocol just like `InputSourceController` isolates Carbon. `ContextResolver` (and through it
/// the learn/apply paths) is the only thing that touches it, so the resolver is testable against a
/// `FakeHostProvider` while the real readers link Accessibility / Apple Events.
///
/// Two implementations sit behind it: `AXHostProvider` (the no-new-permission default) and the opt-in
/// `AppleEventsHostProvider`; the `AppCoordinator` injects one based on the "allow browser control"
/// setting (design D8). The chosen provider is consulted on each within-browser poll tick and on each
/// app activation into a supported browser.
@MainActor
protocol HostProvider: AnyObject {
    /// The active-tab host the supported browser `bundleID` is currently showing, already normalized
    /// (lowercased, `www.`-stripped — see `HostNormalizer`), or nil.
    ///
    /// nil means **"unknown / none / skip"** and is a first-class, expected result, not an error: the
    /// host couldn't be read cleanly, the address bar is being typed in (its value is the user's text,
    /// not a committed host), the window is private/incognito, or — for the Apple Events reader — the
    /// Automation permission isn't granted. On nil the caller resolves to the **app-level** context
    /// (the bare bundle id) rather than guess, so memory is never learned under a wrong key (design D4).
    ///
    /// `bundleID` is always a `BrowserRegistry`-supported browser when this is called (the resolver
    /// gates on `isSupported` first); a provider may still return nil for any browser it can't read.
    func host(forBrowser bundleID: String) -> String?
}
