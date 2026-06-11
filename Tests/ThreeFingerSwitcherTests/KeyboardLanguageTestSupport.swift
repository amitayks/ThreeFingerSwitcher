import Foundation
@testable import ThreeFingerSwitcherCore

/// A test double for the `InputSourceController` Carbon seam (task 3.2). It stands in for the real
/// `CarbonInputSourceController` so `KeyboardLanguageService` can be driven entirely in-memory: no TIS
/// reads and no `TISSelectInputSource`. It models just enough of the OS to exercise the coordination
/// logic — a current source the fake mutates on a successful `select`, a recorded log of every `select`
/// we asked for, and a togglable failure mode.
@MainActor
final class FakeInputSourceController: InputSourceController {

    /// The OS's "currently selected source". `currentSourceID()` returns this; a successful `select`
    /// updates it (the way the real TIS would). Settable directly so a test can pose the source a user
    /// landed on in-place before the next app switch (which is when the service reads/learns it).
    var current: InputSourceID?

    /// Every id passed to `select`, in call order — the spine of the "no redundant select" / "this app
    /// got applied" assertions. A redundant-skip test asserts this stays empty.
    private(set) var selectedIDs: [InputSourceID] = []

    /// When false, `select` records the attempt, leaves `current` untouched, and returns false — the
    /// "since-disabled source" path (design D5) the service must treat as a silent best-effort no-op.
    var selectShouldSucceed = true

    init(current: InputSourceID? = nil) {
        self.current = current
    }

    // MARK: - InputSourceController

    func currentSourceID() -> InputSourceID? { current }

    @discardableResult
    func select(_ id: InputSourceID) -> Bool {
        selectedIDs.append(id)
        guard selectShouldSucceed else { return false }
        current = id   // a successful select changes what the OS reports as current
        return true
    }

    func enabledSources() -> [(id: InputSourceID, name: String)] {
        // The service never reads this (only the Hub picker does); return an empty list.
        []
    }
}

/// A test double for the `HostProvider` seam (task 2.4). It stands in for the real `AXHostProvider` /
/// `AppleEventsHostProvider` so `ContextResolver` — and through it the generalized
/// `KeyboardLanguageService` — can be driven entirely in-memory, with no Accessibility / Apple Events
/// read. A test scripts what host the frontmost browser is "showing" per bundle id; a nil entry models
/// the expected unreadable cases (the address bar being typed in, a private/incognito window, or no
/// Automation grant — design D4), so the resolver must degrade to the app-level (bundle-only) context.
@MainActor
final class FakeHostProvider: HostProvider {

    /// The host this fake reports for each browser bundle id. The value is itself an `Optional<String>`
    /// so a test can distinguish "this bundle resolves to `keep.google.com`" from "this bundle resolves
    /// to nil (typing / private / unresolved)". A bundle id absent from the map also yields nil.
    var hostsByBundle: [String: String?]

    init(hostsByBundle: [String: String?] = [:]) {
        self.hostsByBundle = hostsByBundle
    }

    /// Convenience setter so a test can re-point a single browser between calls (the per-site regression
    /// scenario navigates Chrome from `keep.` to `mail.google.com` and back by reassigning one host).
    func setHost(_ host: String?, forBrowser bundleID: String) {
        hostsByBundle[bundleID] = host
    }

    // MARK: - HostProvider

    /// Returns the scripted host for `bundleID` (the inner optional), or nil when the bundle has no
    /// scripted entry — the resolver treats nil as "skip → app-level context".
    func host(forBrowser bundleID: String) -> String? {
        hostsByBundle[bundleID] ?? nil
    }
}
