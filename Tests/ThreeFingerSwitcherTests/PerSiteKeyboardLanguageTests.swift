import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the per-site (browser host-level) generalization of the keyboard-language feature
/// (design D1–D8): the pure `BrowserRegistry` table, the `ContextKey`/`HostNormalizer` key shape, the
/// `ContextResolver`'s gate against a `FakeHostProvider`, and — the heart of it — the generalized
/// `KeyboardLanguageService` driven end-to-end through a real resolver so a within-browser host change
/// learns/applies per host exactly like an app switch does per app. The non-browser per-app path is
/// covered by `KeyboardLanguageTests`; these add only the browser-context behavior on top.
@MainActor
final class PerSiteKeyboardLanguageTests: XCTestCase {

    // MARK: - Fixtures

    private let hebrew = "com.apple.keylayout.Hebrew"
    private let abc = "com.apple.keylayout.ABC"

    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.PerSiteKeyboardLanguage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // MARK: - 8.1 BrowserRegistry

    /// Safari and every Chromium fork are supported with the right family; Firefox / unknown are not.
    func testBrowserRegistrySupportedSetAndFamilies() {
        // Safari is its own family (registrable-domain only under AX, D7).
        XCTAssertTrue(BrowserRegistry.isSupported(safari))
        XCTAssertEqual(BrowserRegistry.family(for: safari), .safari)

        // The Chromium forks all map to .chromium (full host in the omnibox under AX).
        for bundle in ["com.google.Chrome",
                       "com.brave.Browser",
                       "com.microsoft.edgemac",
                       "company.thebrowser.Browser",   // Arc
                       "com.vivaldi.Vivaldi"] {
            XCTAssertTrue(BrowserRegistry.isSupported(bundle), "\(bundle) should be a supported browser")
            XCTAssertEqual(BrowserRegistry.family(for: bundle), .chromium, "\(bundle) is a Chromium fork")
        }
    }

    /// Firefox (no scriptable URL) and any non-browser app are unsupported — they keep per-app behavior.
    func testBrowserRegistryUnsupported() {
        XCTAssertFalse(BrowserRegistry.isSupported("org.mozilla.firefox"), "Firefox is deliberately omitted")
        XCTAssertNil(BrowserRegistry.family(for: "org.mozilla.firefox"))
        XCTAssertFalse(BrowserRegistry.isSupported("com.telegram"), "a normal app is not a supported browser")
        XCTAssertNil(BrowserRegistry.family(for: "com.telegram"))
    }

    // MARK: - 8.2 ContextKey + HostNormalizer

    /// A nil / empty host yields the bare bundle id (per-app shape); a present host yields `bundle|host`.
    func testContextKeyShape() {
        XCTAssertEqual(ContextKey.make(bundleID: chrome, host: nil), chrome,
                       "no host ⇒ the bare bundle id (byte-for-byte per-app behavior)")
        XCTAssertEqual(ContextKey.make(bundleID: chrome, host: ""), chrome,
                       "an empty host is treated as no host (never a trailing-separator key)")
        XCTAssertEqual(ContextKey.make(bundleID: chrome, host: "keep.google.com"),
                       "com.google.Chrome|keep.google.com",
                       "a present host ⇒ bundle|host")
    }

    /// `HostNormalizer` lowercases, strips a leading `www.`, drops a trailing dot, rejects empty/non-host,
    /// and passes a registrable-domain-only string (Safari AX) through unchanged.
    func testHostNormalizer() {
        XCTAssertEqual(HostNormalizer.normalize("KEEP.Google.COM"), "keep.google.com", "lowercased")
        XCTAssertEqual(HostNormalizer.normalize("www.google.com"), "google.com", "leading www. stripped")
        XCTAssertEqual(HostNormalizer.normalize("google.com."), "google.com", "trailing dot dropped")
        XCTAssertEqual(HostNormalizer.normalize("  mail.google.com  "), "mail.google.com", "trimmed")

        XCTAssertNil(HostNormalizer.normalize(""), "empty ⇒ nil")
        XCTAssertNil(HostNormalizer.normalize("   "), "whitespace-only ⇒ nil")
        XCTAssertNil(HostNormalizer.normalize("com.google.Chrome|keep.google.com"),
                     "a value carrying the key separator ⇒ nil (never learn under a bad key)")
        XCTAssertNil(HostNormalizer.normalize("chrome://newtab"), "an internal page (no dotted host) ⇒ nil")

        // Sub-paths and full URLs strip down to the host ROOT — the fix for sites like claude.ai/chat/...
        XCTAssertEqual(HostNormalizer.normalize("google.com/mail"), "google.com",
                       "a host with a path keys on the host root (path stripped)")
        XCTAssertEqual(HostNormalizer.normalize("claude.ai/chat/1552f48"), "claude.ai",
                       "a deep sub-path keys on the host root")
        XCTAssertEqual(HostNormalizer.normalize("https://claude.ai/chat/1552f48"), "claude.ai",
                       "a full URL keys on the host root")
        XCTAssertEqual(HostNormalizer.normalize("https://keep.google.com/u/0/"), "keep.google.com",
                       "subdomain kept, scheme + path stripped")

        // Safari's registrable-domain-only value (subdomain hidden, D7) passes through as-is.
        XCTAssertEqual(HostNormalizer.normalize("google.com"), "google.com",
                       "a registrable-domain-only string (Safari AX) is used as-is — no eTLD+1 math")
    }

    // MARK: - 8.3 ContextResolver against FakeHostProvider

    /// A supported browser with a readable host resolves to `bundle|host`.
    func testResolverSupportedBrowserWithHost() {
        let host = FakeHostProvider(hostsByBundle: [chrome: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        XCTAssertEqual(resolver.contextID(forFrontmost: chrome), "com.google.Chrome|keep.google.com")
    }

    /// A supported browser whose host reads nil (typing / private / unresolved) degrades to the bundle id.
    func testResolverSupportedBrowserNilHostDegradesToBundle() {
        let host = FakeHostProvider(hostsByBundle: [chrome: nil])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        XCTAssertEqual(resolver.contextID(forFrontmost: chrome), chrome,
                       "an unreadable host falls back to the app-level context, never a guessed key")
    }

    /// An unsupported browser / normal app resolves to the bundle id even with per-site on.
    func testResolverUnsupportedBrowserIsBundleOnly() {
        // Provider has a host scripted, but an unsupported app never consults it.
        let host = FakeHostProvider(hostsByBundle: ["org.mozilla.firefox": "example.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        XCTAssertEqual(resolver.contextID(forFrontmost: "org.mozilla.firefox"), "org.mozilla.firefox")
        XCTAssertEqual(resolver.contextID(forFrontmost: "com.telegram"), "com.telegram")
    }

    /// Per-site off ⇒ even a supported browser with a readable host resolves to the bundle id only.
    func testResolverPerSiteOffIsBundleOnly() {
        let host = FakeHostProvider(hostsByBundle: [chrome: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { false })
        XCTAssertEqual(resolver.contextID(forFrontmost: chrome), chrome,
                       "per-site off ⇒ a browser behaves exactly like any other app")
    }

    /// No frontmost bundle id ⇒ no context.
    func testResolverNilBundleIsNilContext() {
        let host = FakeHostProvider()
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        XCTAssertNil(resolver.contextID(forFrontmost: nil))
    }

    // MARK: - 8.4 Service per-site coordination (THE REGRESSION for the user scenario)

    /// On Chrome, `keep.google.com` learns Hebrew; navigating to `mail.google.com` applies/learns English;
    /// returning to `keep.google.com` restores Hebrew — driven through a *real* `ContextResolver` + the
    /// `FakeHostProvider` + `FakeInputSourceController`, with `currentContextID` wired to the resolver and
    /// the host flipped between `reevaluate()` calls (exactly how `BrowserContextMonitor` drives it).
    func testPerSiteRoundTripRemembersPerHostWithinOneBrowser() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)   // start on English/ABC

        let host = FakeHostProvider(hostsByBundle: [chrome: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })

        let service = KeyboardLanguageService(
            store: store,
            controller: fake,
            globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.chrome) })

        // Arrive on keep.google.com (first activation: nothing prior to learn; unseen → default ABC == current).
        service.reevaluate()
        XCTAssertEqual(fake.selectedIDs, [], "keep starts on the default already — no redundant select")

        // User sets Hebrew on keep (an in-place change; learned only when the host later changes).
        fake.current = hebrew

        // Navigate to mail.google.com: keep's Hebrew is captured now, and mail (unseen) gets the default.
        host.setHost("mail.google.com", forBrowser: chrome)
        service.reevaluate()
        XCTAssertEqual(store.source(forBundleID: "com.google.Chrome|keep.google.com"), hebrew,
                       "leaving keep captures the source keep ended on")
        XCTAssertEqual(fake.current, abc, "mail (unseen) was switched to the global default")

        // User does NOT change the language on mail — it stays on the applied default (ABC). Because it
        // was never actively changed, mail must NOT be saved ("only sites you actively changed").

        // Navigate back to keep.google.com: mail (unchanged) is not recorded; keep is restored to Hebrew.
        host.setHost("keep.google.com", forBrowser: chrome)
        service.reevaluate()
        XCTAssertNil(store.source(forBundleID: "com.google.Chrome|mail.google.com"),
                     "mail was only passed through at the default, never changed ⇒ not saved")
        XCTAssertEqual(fake.current, hebrew, "returning to keep restores its remembered Hebrew")

        // Only keep — the site we actually changed — is an entry in the shared map (design D1).
        XCTAssertEqual(store.source(forBundleID: "com.google.Chrome|keep.google.com"), hebrew)
        XCTAssertNil(store.source(forBundleID: "com.google.Chrome|mail.google.com"))
    }

    // MARK: - Only actively-changed sites are remembered

    /// A site visited at the applied default and left without a change is NOT saved (it never clutters the
    /// saved-sites list with sites you merely browsed).
    func testVisitedButUnchangedSiteIsNotSaved() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)
        let host = FakeHostProvider(hostsByBundle: [chrome: "github.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        let service = KeyboardLanguageService(
            store: store, controller: fake, globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.chrome) })

        service.reevaluate()                 // arrive github at default ABC (no change)
        service.handleContextChange(contextID: "com.telegram")   // leave the browser entirely

        XCTAssertNil(store.source(forBundleID: "com.google.Chrome|github.com"),
                     "a site you only passed through at its applied language is not saved")
        XCTAssertTrue(store.siteEntries().isEmpty, "no site entries for unchanged visits")
    }

    /// A site whose language you actively change IS saved (and surfaces in `siteEntries`).
    func testActivelyChangedSiteIsSaved() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)
        let host = FakeHostProvider(hostsByBundle: [chrome: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        let service = KeyboardLanguageService(
            store: store, controller: fake, globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.chrome) })

        service.reevaluate()                 // arrive keep at default ABC
        fake.current = hebrew                 // user actively changes keep to Hebrew
        service.handleContextChange(contextID: "com.telegram")   // leave

        XCTAssertEqual(store.source(forBundleID: "com.google.Chrome|keep.google.com"), hebrew,
                       "a site you actively changed is remembered")
        XCTAssertEqual(store.siteEntries().map(\.host), ["keep.google.com"])
    }

    /// Changing a saved site back to the global default REMOVES it — it is no longer a deliberate choice.
    func testSiteRevertedToDefaultIsRemoved() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.google.Chrome|keep.google.com")   // already saved as Hebrew
        let fake = FakeInputSourceController(current: abc)
        let host = FakeHostProvider(hostsByBundle: [chrome: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })
        let service = KeyboardLanguageService(
            store: store, controller: fake, globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.chrome) })

        service.reevaluate()                 // arrive keep → applies remembered Hebrew
        XCTAssertEqual(fake.current, hebrew)
        fake.current = abc                    // user changes keep back to the global default (ABC)
        service.handleContextChange(contextID: "com.telegram")   // leave

        XCTAssertNil(store.source(forBundleID: "com.google.Chrome|keep.google.com"),
                     "reverting a site to the global default forgets it (no longer a saved site)")
    }

    // MARK: - 8.5 Safari degradation (D7 at the seam level)

    /// Under the AX reader Safari yields only the registrable domain, so `keep.` and `mail.google.com`
    /// collapse to ONE entry (`...|google.com`) — defined behavior, not a bug. A fake returning the
    /// registrable domain for both pages models the AX reader on Safari.
    func testSafariRegistrableDomainCollapsesSubdomainsToOneEntry() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)

        // AX-on-Safari: both Keep and Gmail are reported as the bare registrable domain.
        let host = FakeHostProvider(hostsByBundle: [safari: "google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })

        let service = KeyboardLanguageService(
            store: store,
            controller: fake,
            globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.safari) })

        // Arrive (domain == google.com), set Hebrew, then "navigate" — but the host reads the same domain.
        service.reevaluate()
        fake.current = hebrew
        // Re-resolving yields the SAME context id, so this is a same-context no-op (nothing learned yet).
        service.reevaluate()
        XCTAssertNil(store.source(forBundleID: "com.apple.Safari|google.com"),
                     "a same-domain re-resolve is a no-op — Hebrew is still an in-place change")

        // Switch away from Safari entirely to force the learn of the (single) collapsed entry.
        let other = ContextResolver(hostProvider: FakeHostProvider(), perSiteEnabled: { true })
        let switched = other.contextID(forFrontmost: "com.telegram")
        service.handleContextChange(contextID: switched)
        XCTAssertEqual(store.source(forBundleID: "com.apple.Safari|google.com"), hebrew,
                       "both Safari subdomains collapse to one entry under the AX registrable-domain read")

        // Exactly one Safari entry exists — the collapse is observable in the store.
        let safariEntries = store.map.keys.filter { $0.hasPrefix("com.apple.Safari|") }
        XCTAssertEqual(safariEntries, ["com.apple.Safari|google.com"],
                       "no per-subdomain entries exist under AX on Safari (D7)")
    }

    /// With a provider returning the EXACT host for each page (the Apple Events reader on Safari), the
    /// two subdomains are distinguished into independent entries — the documented fix for the collapse.
    func testSafariExactHostsDistinguishSubdomains() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)

        let host = FakeHostProvider(hostsByBundle: [safari: "keep.google.com"])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })

        let service = KeyboardLanguageService(
            store: store,
            controller: fake,
            globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.safari) })

        service.reevaluate()                  // on keep.google.com (default ABC)
        fake.current = hebrew                  // user sets Hebrew on keep
        host.setHost("mail.google.com", forBrowser: safari)
        service.reevaluate()                   // navigate to mail → keep's Hebrew captured

        XCTAssertEqual(store.source(forBundleID: "com.apple.Safari|keep.google.com"), hebrew)
        XCTAssertNil(store.source(forBundleID: "com.apple.Safari|mail.google.com"),
                     "mail hasn't been learned yet, but it is a distinct, independent key under exact hosts")
    }

    // MARK: - 8.6 Guards (typing / private → no per-site write)

    /// When the host reads nil (address bar being typed in, or a private/incognito window), the resolver
    /// yields the bundle-only context, so no per-site (`bundle|host`) entry is ever written.
    func testNilHostWritesNoPerSiteEntry() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)

        // The browser is frontmost the whole time, but the host never resolves (typing / private).
        let host = FakeHostProvider(hostsByBundle: [chrome: nil])
        let resolver = ContextResolver(hostProvider: host, perSiteEnabled: { true })

        let service = KeyboardLanguageService(
            store: store,
            controller: fake,
            globalDefault: { self.abc },
            currentContextID: { resolver.contextID(forFrontmost: self.chrome) })

        service.reevaluate()        // resolves to the bundle-only context com.google.Chrome
        fake.current = hebrew        // user changes source in-place
        // Switch away to force a learn of the *outgoing* context.
        service.handleContextChange(contextID: "com.telegram")

        // The learn landed under the bundle-only key, NOT a per-site key.
        XCTAssertEqual(store.source(forBundleID: chrome), hebrew,
                       "an unreadable host learns under the app-level (bundle) key")
        let perSiteEntries = store.map.keys.filter { $0.contains(ContextKey.separator) }
        XCTAssertTrue(perSiteEntries.isEmpty,
                      "no per-site (bundle|host) entry is written while the host is unresolved")
    }

    // MARK: - ContextKey site helpers + store saved-sites surface

    /// `isSiteKey` / `host(from:)` / `bundleID(from:)` parse the shared key shape both ways.
    func testContextKeySiteHelpers() {
        let siteKey = "com.google.Chrome|keep.google.com"
        XCTAssertTrue(ContextKey.isSiteKey(siteKey))
        XCTAssertEqual(ContextKey.host(from: siteKey), "keep.google.com")
        XCTAssertEqual(ContextKey.bundleID(from: siteKey), "com.google.Chrome")

        XCTAssertFalse(ContextKey.isSiteKey("com.telegram"), "a bare bundle id is not a site key")
        XCTAssertNil(ContextKey.host(from: "com.telegram"), "a per-app key has no host")
        XCTAssertEqual(ContextKey.bundleID(from: "com.telegram"), "com.telegram")
    }

    /// `siteEntries()` lists only the per-site keys (per-app entries excluded), parsed + sorted by host,
    /// with a friendly browser name; `removeSource` drops one.
    func testStoreSiteEntriesAndRemoval() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.google.Chrome|keep.google.com")
        store.setSource(abc, forBundleID: "com.apple.Safari|google.com")
        store.setSource(hebrew, forBundleID: "com.telegram")   // a per-app entry — must be excluded

        let entries = store.siteEntries()
        XCTAssertEqual(entries.map(\.host), ["google.com", "keep.google.com"], "sorted by host; per-app excluded")
        XCTAssertEqual(entries.first?.browserName, "Safari")
        XCTAssertEqual(entries.first { $0.host == "keep.google.com" }?.browserName, "Chrome")
        XCTAssertEqual(entries.first { $0.host == "keep.google.com" }?.source, hebrew)

        store.removeSource(forBundleID: "com.google.Chrome|keep.google.com")
        XCTAssertEqual(store.siteEntries().map(\.host), ["google.com"], "removal drops exactly one site")
        XCTAssertEqual(store.source(forBundleID: "com.telegram"), hebrew, "per-app entry untouched by site removal")
    }
}
