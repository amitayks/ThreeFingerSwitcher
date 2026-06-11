import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the per-app keyboard-language feature's MLX-free Core (design D1–D9): the two pure policy
/// rules (`activate`/`learn`), the `KeyboardLanguageStore`'s persistence + forward-only schema stamping
/// against an isolated `UserDefaults` suite, and `KeyboardLanguageService`'s **learn-on-deactivation /
/// apply-on-activation** engine driven against the in-memory `FakeInputSourceController` — covering the
/// deterministic capture of the outgoing app's source, the redundant-select skip, the unseen→default
/// apply, the nil-bundle-id handling, the same-app re-activation no-op, and the silent best-effort
/// handling of a failed (since-disabled) select.
@MainActor
final class KeyboardLanguageTests: XCTestCase {

    // MARK: - Fixtures

    private let hebrew = "com.apple.keylayout.Hebrew"
    private let abc = "com.apple.keylayout.ABC"
    private let pinyin = "com.apple.inputmethod.SCIM.ITABC"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.KeyboardLanguage.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // MARK: - 4.1 Policy.activate

    /// A remembered source for the bundle wins over the global default (design D3 > D7).
    func testActivateRememberedWinsOverDefault() {
        let source = KeyboardLanguagePolicy.activate(
            bundleID: "com.example.editor",
            map: ["com.example.editor": hebrew],
            globalDefault: abc)
        XCTAssertEqual(source, hebrew, "the bundle's remembered source beats the global default")
    }

    /// An unseen app (no map entry) falls back to the user's global default.
    func testActivateUnseenFallsBackToDefault() {
        let source = KeyboardLanguagePolicy.activate(
            bundleID: "com.example.unseen",
            map: ["com.other.app": hebrew],
            globalDefault: abc)
        XCTAssertEqual(source, abc, "an unseen app with a global default uses the default")
    }

    /// An unseen app with no global default returns nil — leave the source as-is and learn next time.
    func testActivateUnseenWithNilDefaultReturnsNil() {
        let source = KeyboardLanguagePolicy.activate(
            bundleID: "com.example.unseen",
            map: [:],
            globalDefault: nil)
        XCTAssertNil(source, "no memory and no default ⇒ nothing to select")
    }

    // MARK: - 4.2 Policy.learn

    /// `learn` sets the bundle's source and leaves every other entry untouched.
    func testLearnSetsBundleSourceAndLeavesOthersUntouched() {
        let map = ["com.other.app": abc]
        let result = KeyboardLanguagePolicy.learn(
            bundleID: "com.example.editor",
            source: hebrew,
            into: map)
        XCTAssertEqual(result["com.example.editor"], hebrew, "the target bundle learns the new source")
        XCTAssertEqual(result["com.other.app"], abc, "other bundles are independent and untouched")
        XCTAssertEqual(map["com.example.editor"], nil, "the input map is not mutated (value semantics)")
    }

    /// Last write wins: re-learning a bundle overwrites its prior source.
    func testLearnLastWriteWins() {
        var map: [String: InputSourceID] = [:]
        map = KeyboardLanguagePolicy.learn(bundleID: "com.example.editor", source: abc, into: map)
        map = KeyboardLanguagePolicy.learn(bundleID: "com.example.editor", source: hebrew, into: map)
        XCTAssertEqual(map["com.example.editor"], hebrew, "the most recent learn wins")
        XCTAssertEqual(map.count, 1, "re-learning the same bundle does not create a second entry")
    }

    // MARK: - 4.3 Store persistence / migration

    /// A write via `setSource` survives a reload of a fresh store on the same defaults (round-trip).
    func testStoreWriteSurvivesReload() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.example.editor")
        store.setSource(pinyin, forBundleID: "com.example.cjk")

        let reloaded = KeyboardLanguageStore(defaults: defaults)
        XCTAssertEqual(reloaded.map, ["com.example.editor": hebrew, "com.example.cjk": pinyin],
                       "the bundle→source map round-trips through UserDefaults")
        XCTAssertEqual(reloaded.source(forBundleID: "com.example.editor"), hebrew)
        XCTAssertNil(reloaded.source(forBundleID: "com.unknown"), "an unseen bundle reads nil")
    }

    /// A first-run store (empty defaults) starts with an empty map at the current schema.
    func testStoreFirstRunIsEmptyMap() {
        let store = KeyboardLanguageStore(defaults: defaults)
        XCTAssertTrue(store.map.isEmpty, "first run seeds an empty map — the feature learns as you go")
        XCTAssertEqual(store.record.schemaVersion, KeyboardLanguageRecord.currentSchemaVersion)
    }

    /// A record written at an older schema is stamped forward to the current version on load.
    func testStoreStampsSchemaForwardOnLoad() throws {
        // Hand-encode a v0 record under the store's key to simulate an older on-disk shape.
        let legacy = KeyboardLanguageRecord(schemaVersion: 0, map: ["com.example.editor": hebrew])
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: "keyboardLanguageMap")

        let store = KeyboardLanguageStore(defaults: defaults)
        XCTAssertEqual(store.record.schemaVersion, KeyboardLanguageRecord.currentSchemaVersion,
                       "an older record is migrated forward to the current schema version")
        XCTAssertEqual(store.map["com.example.editor"], hebrew, "the data survives the forward stamp")
    }

    /// A future-schema record is NOT down-stamped (forward-only): the version is preserved as-is.
    func testStoreDoesNotDownStampFutureRecord() throws {
        let future = KeyboardLanguageRecord(schemaVersion: KeyboardLanguageRecord.currentSchemaVersion + 5,
                                            map: ["com.example.editor": hebrew])
        let data = try JSONEncoder().encode(future)
        defaults.set(data, forKey: "keyboardLanguageMap")

        let store = KeyboardLanguageStore(defaults: defaults)
        XCTAssertEqual(store.record.schemaVersion, KeyboardLanguageRecord.currentSchemaVersion + 5,
                       "a newer-schema record is never clobbered down to the current version")
    }

    // MARK: - 4.4 Service engine (learn on deactivation / apply on activation)

    /// Build a service wired to the fake controller. `currentContextID` is only used by `start()`'s
    /// seeding; these tests drive `handleContextChange` directly (no live NSWorkspace observer), so the
    /// service begins with no prior context — exactly as it would right after a fresh seed. For a plain
    /// app the context id is just its bundle id, so these per-app assertions are unchanged by the
    /// generalization to context keys.
    private func makeService(store: KeyboardLanguageStore,
                             controller: FakeInputSourceController,
                             globalDefault: @escaping () -> InputSourceID?) -> KeyboardLanguageService {
        KeyboardLanguageService(store: store,
                                controller: controller,
                                globalDefault: globalDefault,
                                currentContextID: { nil })
    }

    /// THE REGRESSION TEST for the reported bug: set Hebrew in app A, visit app B (which gets the
    /// default) and toggle its language, then return to A — A must restore Hebrew. The fix (learn the
    /// outgoing app's source on the *next* activation) makes A's memory immune to what happens in B.
    func testRoundTripRemembersPerAppAcrossAVisitToAnotherApp() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)   // start on English/ABC
        let service = makeService(store: store, controller: fake, globalDefault: { self.abc })

        // Arrive in app A (first activation: nothing prior to learn; unseen → default ABC == current).
        service.handleContextChange(contextID: "com.telegram")
        XCTAssertEqual(fake.selectedIDs, [], "A starts on the default already — no redundant select")

        // User sets Hebrew in A (an in-place change; learned only when focus later leaves A).
        fake.current = hebrew

        // Switch to app B: A's Hebrew is captured now, and B (unseen) gets the default.
        service.handleContextChange(contextID: "com.terminal")
        XCTAssertEqual(store.source(forBundleID: "com.telegram"), hebrew,
                       "leaving A captures the source A ended on")
        XCTAssertEqual(fake.current, abc, "B (unseen) was switched to the global default")

        // User toggles in B and ends on English.
        fake.current = abc

        // Return to app A: B's English is captured, and A is restored to Hebrew.
        service.handleContextChange(contextID: "com.telegram")
        XCTAssertEqual(store.source(forBundleID: "com.terminal"), abc, "leaving B captures B's source")
        XCTAssertEqual(fake.current, hebrew, "returning to A restores its remembered Hebrew")
    }

    /// Activating an app with a remembered source selects exactly that id (apply on activation).
    func testActivationAppliesRememberedSource() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.example.editor")
        let fake = FakeInputSourceController(current: abc)   // currently on ABC
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.editor")

        XCTAssertEqual(fake.selectedIDs, [hebrew], "the remembered source is selected on activation")
        XCTAssertEqual(fake.current, hebrew, "the fake OS now reports the selected source")
    }

    /// When the current source already equals the desired one, NO select is performed (redundant skip).
    func testApplyIsRedundantSkipWhenAlreadyOnDesired() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.example.editor")
        let fake = FakeInputSourceController(current: hebrew)   // already on Hebrew
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.editor")

        XCTAssertEqual(fake.selectedIDs, [], "no select is issued when already on the desired source")
    }

    /// The first activation has no prior app, so nothing is learned — only the incoming app is applied.
    func testFirstActivationLearnsNothing() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: hebrew)
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.editor")

        XCTAssertTrue(store.map.isEmpty, "no prior app ⇒ no learn on the very first activation")
    }

    /// Re-activating the SAME app is a no-op: it neither re-applies nor overwrites an in-place change.
    func testSameAppReactivationIsNoOp() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.example.editor")
        let fake = FakeInputSourceController(current: abc)
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.editor")   // applies Hebrew, current → Hebrew
        XCTAssertEqual(fake.selectedIDs, [hebrew])
        // The user changes the source in-place; re-activating the same app must NOT fight it.
        fake.current = abc
        service.handleContextChange(contextID: "com.example.editor")

        XCTAssertEqual(fake.selectedIDs, [hebrew], "a same-app re-activation issues no further select")
        XCTAssertEqual(fake.current, abc, "the user's in-place change is left intact")
    }

    /// Switching to an app with no bundle id applies nothing, but still learns the outgoing app.
    func testNilIncomingBundleLearnsOutgoingButAppliesNothing() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)
        let service = makeService(store: store, controller: fake, globalDefault: { self.hebrew })

        service.handleContextChange(contextID: "com.example.editor")   // seed prior app; unseen → default Hebrew
        fake.current = abc                                          // user lands on ABC in the editor
        service.handleContextChange(contextID: nil)                    // focus a bundle-less surface

        XCTAssertEqual(store.source(forBundleID: "com.example.editor"), abc,
                       "the outgoing app's source is still learned when the new app has no bundle id")
        // No select for the nil app (selectedIDs only holds the editor's initial default apply).
        XCTAssertEqual(fake.selectedIDs, [hebrew], "an app with no bundle id triggers no select")
    }

    /// An unseen incoming app with no global default selects nothing (leaves the source as-is).
    func testUnseenWithNoDefaultDoesNotSelect() {
        let store = KeyboardLanguageStore(defaults: defaults)
        let fake = FakeInputSourceController(current: abc)
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.unseen")

        XCTAssertEqual(fake.selectedIDs, [], "no memory and no default ⇒ nothing is selected")
        XCTAssertEqual(fake.current, abc, "the current source is left untouched")
    }

    /// A failed select (since-disabled source) leaves the current source unchanged and does not crash —
    /// the silent best-effort no-op path (design D5).
    func testFailedSelectIsSilentAndLeavesSourceUnchanged() {
        let store = KeyboardLanguageStore(defaults: defaults)
        store.setSource(hebrew, forBundleID: "com.example.editor")
        let fake = FakeInputSourceController(current: abc)
        fake.selectShouldSucceed = false   // the remembered source is since-disabled
        let service = makeService(store: store, controller: fake, globalDefault: { nil })

        service.handleContextChange(contextID: "com.example.editor")   // must not crash

        XCTAssertEqual(fake.selectedIDs, [hebrew], "the select was attempted")
        XCTAssertEqual(fake.current, abc, "a failed select leaves the current source unchanged")
    }
}
