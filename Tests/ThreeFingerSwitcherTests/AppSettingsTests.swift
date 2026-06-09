import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `AppSettings` (Settings/AppSettings.swift).
///
/// All tests use an isolated `UserDefaults` suite (never `UserDefaults.standard`)
/// so they cannot read or mutate the real app preferences. Each test creates a
/// uniquely-named suite and removes it in `tearDown`, keeping tests deterministic
/// and free of cross-test contamination.
@MainActor
final class AppSettingsTests: XCTestCase {
    /// Accuracy for Double comparisons of normalized trackpad tunables.
    private let eps = 1e-9

    /// The current suite name in use by the running test, removed during teardown.
    private var suiteName: String!
    /// The isolated defaults instance backing the settings under test.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.AppSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Sanity: a brand-new suite should be empty for the keys we exercise.
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
    }

    override func tearDown() {
        // Wipe every persisted key and forget the suite so nothing leaks to disk.
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Convenience factory bound to the per-test isolated suite.
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults)
    }

    // MARK: - First-run defaults

    /// On first run (empty suite) every tunable must equal its `AppSettings.Defaults` value,
    /// and `enabled` must default to `true` (its default is hardcoded in the initializer).
    func testFirstRunDefaultsMatchDefaultsEnum() {
        // Arrange / Act
        let settings = makeSettings()

        // Assert
        XCTAssertEqual(settings.activationThreshold, AppSettings.Defaults.activationThreshold, accuracy: eps)
        XCTAssertEqual(settings.axisLockRatio, AppSettings.Defaults.axisLockRatio, accuracy: eps)
        XCTAssertEqual(settings.stepDistance, AppSettings.Defaults.stepDistance, accuracy: eps)
        XCTAssertEqual(settings.wrapAtEnds, AppSettings.Defaults.wrapAtEnds)
        XCTAssertEqual(settings.reverseDirection, AppSettings.Defaults.reverseDirection)
        XCTAssertEqual(settings.velocitySmoothing, AppSettings.Defaults.velocitySmoothing, accuracy: eps)
        XCTAssertEqual(settings.requireExactlyThree, AppSettings.Defaults.requireExactlyThree)
        XCTAssertEqual(settings.rowStepDistance, AppSettings.Defaults.rowStepDistance, accuracy: eps)
        XCTAssertEqual(settings.reverseVerticalDirection, AppSettings.Defaults.reverseVerticalDirection)

        // `enabled` has no entry in Defaults; its first-run value is hardcoded to true.
        XCTAssertTrue(settings.enabled)

        // Space-row switching is opt-in: off by default (it relocates Mission Control).
        XCTAssertEqual(settings.manageVerticalGesture, AppSettings.Defaults.manageVerticalGesture)
        XCTAssertFalse(settings.manageVerticalGesture)
    }

    /// `manageVerticalGesture` is opt-in (default false) and persists across instances both ways.
    func testManageVerticalGestureDefaultsFalseAndPersists() {
        let writer = makeSettings()
        XCTAssertFalse(writer.manageVerticalGesture, "default must be off (opt-in)")

        writer.manageVerticalGesture = true
        XCTAssertEqual(defaults.object(forKey: "manageVerticalGesture") as? Bool, true, "writes the documented key")

        let reader = AppSettings(defaults: defaults)
        XCTAssertTrue(reader.manageVerticalGesture, "persists across instances")
    }

    /// Spot-check the literal default values so a silent change to `Defaults` is caught.
    func testDefaultsEnumHasExpectedLiteralValues() {
        XCTAssertEqual(AppSettings.Defaults.activationThreshold, 0.045, accuracy: eps)
        XCTAssertEqual(AppSettings.Defaults.axisLockRatio, 1.4, accuracy: eps)
        XCTAssertEqual(AppSettings.Defaults.stepDistance, 0.05, accuracy: eps)
        XCTAssertFalse(AppSettings.Defaults.wrapAtEnds)
        XCTAssertFalse(AppSettings.Defaults.reverseDirection)
        XCTAssertEqual(AppSettings.Defaults.velocitySmoothing, 0.35, accuracy: eps)
        XCTAssertTrue(AppSettings.Defaults.requireExactlyThree)
        XCTAssertEqual(AppSettings.Defaults.rowStepDistance, 0.12, accuracy: eps)
        XCTAssertFalse(AppSettings.Defaults.reverseVerticalDirection)
    }

    /// The vertical row step must be strictly larger than the horizontal step so that
    /// horizontal scrubbing jitter cannot accidentally flip Space-rows.
    func testRowStepDistanceDefaultGreaterThanStepDistanceDefault() {
        XCTAssertGreaterThan(
            AppSettings.Defaults.rowStepDistance,
            AppSettings.Defaults.stepDistance,
            "rowStepDistance default must exceed stepDistance default to avoid accidental row flips"
        )
    }

    /// Same invariant, observed through a live instance's properties (not just the enum).
    func testRowStepDistanceInstanceGreaterThanStepDistanceInstance() {
        let settings = makeSettings()
        XCTAssertGreaterThan(settings.rowStepDistance, settings.stepDistance)
    }

    // MARK: - Persistence

    /// A Double tunable set on one instance must be readable from a fresh instance on the
    /// same suite, proving the value was persisted to UserDefaults (not just held in memory).
    func testSettingDoubleValuePersistsAcrossInstances() {
        // Arrange
        let writer = makeSettings()

        // Act
        writer.stepDistance = 0.1234

        // Assert (new instance, same backing suite)
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.stepDistance, 0.1234, accuracy: eps)
    }

    /// Every Double tunable persists independently across instances.
    func testAllDoubleTunablesPersistAcrossInstances() {
        // Arrange
        let writer = makeSettings()

        // Act: choose values distinct from the defaults.
        writer.activationThreshold = 0.2
        writer.axisLockRatio = 2.5
        writer.stepDistance = 0.07
        writer.velocitySmoothing = 0.9
        writer.rowStepDistance = 0.33

        // Assert
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.activationThreshold, 0.2, accuracy: eps)
        XCTAssertEqual(reader.axisLockRatio, 2.5, accuracy: eps)
        XCTAssertEqual(reader.stepDistance, 0.07, accuracy: eps)
        XCTAssertEqual(reader.velocitySmoothing, 0.9, accuracy: eps)
        XCTAssertEqual(reader.rowStepDistance, 0.33, accuracy: eps)
    }

    /// Every Bool tunable persists across instances, including flipping defaults both ways.
    func testAllBoolTunablesPersistAcrossInstances() {
        // Arrange
        let writer = makeSettings()

        // Act: flip each Bool to the opposite of its first-run value.
        writer.enabled = false                  // default true -> false
        writer.wrapAtEnds = true                // default false -> true
        writer.reverseDirection = true          // default false -> true
        writer.requireExactlyThree = false      // default true -> false
        writer.reverseVerticalDirection = true  // default false -> true
        writer.showDiagnostics = true           // default false -> true

        // Assert
        let reader = AppSettings(defaults: defaults)
        XCTAssertFalse(reader.enabled)
        XCTAssertTrue(reader.wrapAtEnds)
        XCTAssertTrue(reader.reverseDirection)
        XCTAssertFalse(reader.requireExactlyThree)
        XCTAssertTrue(reader.reverseVerticalDirection)
        XCTAssertTrue(reader.showDiagnostics)
    }

    /// Persistence writes through to the raw UserDefaults keys (verifies the actual key names),
    /// so a renamed key would break this even if the in-memory property still worked.
    func testPersistenceWritesRawUserDefaultsKeys() {
        // Arrange
        let settings = makeSettings()

        // Act
        settings.activationThreshold = 0.11
        settings.enabled = false

        // Assert: read straight from the backing store using the documented key strings.
        XCTAssertEqual(defaults.object(forKey: "activationThreshold") as? Double, 0.11)
        XCTAssertEqual(defaults.object(forKey: "enabled") as? Bool, false)
    }

    /// The last write wins: overwriting a value updates the persisted store.
    func testOverwritingValuePersistsLatest() {
        // Arrange
        let writer = makeSettings()

        // Act
        writer.stepDistance = 0.02
        writer.stepDistance = 0.08

        // Assert
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.stepDistance, 0.08, accuracy: eps)
    }

    // MARK: - resetToDefaults

    /// `resetToDefaults()` restores every tunable it manages back to its `Defaults` value,
    /// even after all of them were changed away from the defaults.
    func testResetToDefaultsRestoresManagedTunables() {
        // Arrange: mutate every tunable resetToDefaults() is responsible for.
        let settings = makeSettings()
        settings.activationThreshold = 0.5
        settings.axisLockRatio = 3.0
        settings.stepDistance = 0.5
        settings.wrapAtEnds = true
        settings.reverseDirection = true
        settings.velocitySmoothing = 0.99
        settings.requireExactlyThree = false
        settings.rowStepDistance = 0.5
        settings.reverseVerticalDirection = true
        settings.showDiagnostics = true

        // Act
        settings.resetToDefaults()

        // Assert
        XCTAssertEqual(settings.activationThreshold, AppSettings.Defaults.activationThreshold, accuracy: eps)
        XCTAssertEqual(settings.axisLockRatio, AppSettings.Defaults.axisLockRatio, accuracy: eps)
        XCTAssertEqual(settings.stepDistance, AppSettings.Defaults.stepDistance, accuracy: eps)
        XCTAssertEqual(settings.wrapAtEnds, AppSettings.Defaults.wrapAtEnds)
        XCTAssertEqual(settings.reverseDirection, AppSettings.Defaults.reverseDirection)
        XCTAssertEqual(settings.velocitySmoothing, AppSettings.Defaults.velocitySmoothing, accuracy: eps)
        XCTAssertEqual(settings.requireExactlyThree, AppSettings.Defaults.requireExactlyThree)
        XCTAssertEqual(settings.rowStepDistance, AppSettings.Defaults.rowStepDistance, accuracy: eps)
        XCTAssertEqual(settings.reverseVerticalDirection, AppSettings.Defaults.reverseVerticalDirection)
        XCTAssertEqual(settings.showDiagnostics, AppSettings.Defaults.showDiagnostics)
        XCTAssertFalse(settings.showDiagnostics, "diagnostics visibility resets to off")
    }

    /// `resetToDefaults()` also persists the restored values, so a fresh instance reads defaults.
    func testResetToDefaultsPersistsRestoredValues() {
        // Arrange
        let settings = makeSettings()
        settings.stepDistance = 0.5
        settings.requireExactlyThree = false
        settings.rowStepDistance = 0.5

        // Act
        settings.resetToDefaults()

        // Assert: a new instance on the same suite sees the defaults again.
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.stepDistance, AppSettings.Defaults.stepDistance, accuracy: eps)
        XCTAssertEqual(reader.requireExactlyThree, AppSettings.Defaults.requireExactlyThree)
        XCTAssertEqual(reader.rowStepDistance, AppSettings.Defaults.rowStepDistance, accuracy: eps)
    }

    /// Documented behavior: `enabled` is NOT part of `resetToDefaults()`, so a disabled
    /// switcher stays disabled across a reset. This asserts the source's actual contract;
    /// if `enabled` should be reset too, this test pins the current (intentional) behavior.
    func testResetToDefaultsDoesNotTouchEnabled() {
        // Arrange
        let settings = makeSettings()
        settings.enabled = false

        // Act
        settings.resetToDefaults()

        // Assert: enabled is left untouched by reset.
        XCTAssertFalse(settings.enabled)
    }

    /// `resetToDefaults()` must NOT touch `manageVerticalGesture`: like `manageSpacesRearrange`, it
    /// is a consent-gated opt-in with a system side effect (it relocates Mission Control), so a
    /// tunables reset must never silently flip it and leave the trackpad change dangling.
    func testResetToDefaultsDoesNotTouchManageVerticalGesture() {
        // Arrange
        let settings = makeSettings()
        settings.manageVerticalGesture = true

        // Act
        settings.resetToDefaults()

        // Assert: still on (reset doesn't manage system-side-effect opt-ins).
        XCTAssertTrue(settings.manageVerticalGesture)
    }

    // MARK: - Stored-value loading

    /// A pre-existing value in the backing store (simulating a prior launch) is loaded by a
    /// new instance instead of falling back to the default.
    func testInitLoadsPreExistingStoredValues() {
        // Arrange: seed the suite directly, as if a previous run had persisted these.
        defaults.set(0.321, forKey: "stepDistance")
        defaults.set(false, forKey: "requireExactlyThree")
        defaults.set(0.222, forKey: "rowStepDistance")

        // Act
        let settings = AppSettings(defaults: defaults)

        // Assert: stored values take precedence over the Defaults fallbacks.
        XCTAssertEqual(settings.stepDistance, 0.321, accuracy: eps)
        XCTAssertFalse(settings.requireExactlyThree)
        XCTAssertEqual(settings.rowStepDistance, 0.222, accuracy: eps)
        // A key that was NOT seeded still falls back to its default.
        XCTAssertEqual(settings.axisLockRatio, AppSettings.Defaults.axisLockRatio, accuracy: eps)
    }

    // MARK: - AI commands opt-in

    /// The AI-commands opt-in is off on first run (it gates a multi-gigabyte model download), and the
    /// selected-model pin starts nil ("registry default").
    func testAICommandsDefaultsOffAndNoSelectedModel() {
        let settings = makeSettings()
        XCTAssertFalse(settings.aiCommandsEnabled, "AI commands must default OFF (opt-in)")
        XCTAssertEqual(settings.aiCommandsEnabled, AppSettings.Defaults.aiCommandsEnabled)
        XCTAssertNil(settings.aiSelectedModelID, "no model pinned by default")
        XCTAssertNil(AppSettings.Defaults.aiSelectedModelID)
    }

    /// The opt-in persists across a "relaunch" (a fresh instance on the same suite) and writes through
    /// to the documented raw key, both directions.
    func testAICommandsEnabledPersistsAcrossInstances() {
        let writer = makeSettings()
        XCTAssertFalse(writer.aiCommandsEnabled)

        writer.aiCommandsEnabled = true
        XCTAssertEqual(defaults.object(forKey: "aiCommandsEnabled") as? Bool, true, "writes the documented key")

        let reader = AppSettings(defaults: defaults)
        XCTAssertTrue(reader.aiCommandsEnabled, "persists across instances")

        reader.aiCommandsEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).aiCommandsEnabled, "the off state persists too")
    }

    /// The selected-model pin persists across instances and writes through to its key.
    func testAISelectedModelIDPersistsAcrossInstances() {
        let writer = makeSettings()
        writer.aiSelectedModelID = "gemma-4-26b-a4b"
        XCTAssertEqual(defaults.object(forKey: "aiSelectedModelID") as? String, "gemma-4-26b-a4b")

        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.aiSelectedModelID, "gemma-4-26b-a4b", "persists across instances")
    }

    /// Older settings (no AI keys present) decode with the opt-in OFF and no pinned model, while every
    /// pre-existing setting is left untouched — proving the addition is purely additive.
    func testOlderSettingsDecodeWithAICommandsOffAndUntouched() {
        // Arrange: simulate a pre-feature store — populate unrelated keys, but NO AI keys.
        defaults.set(0.0777, forKey: "stepDistance")
        defaults.set(true, forKey: "wrapAtEnds")
        defaults.set(true, forKey: "keepClipboardHistory")
        XCTAssertNil(defaults.object(forKey: "aiCommandsEnabled"), "precondition: no AI key on disk")
        XCTAssertNil(defaults.object(forKey: "aiSelectedModelID"), "precondition: no AI model key on disk")

        // Act
        let settings = AppSettings(defaults: defaults)

        // Assert: the new opt-in defaults off / nil without a stored value...
        XCTAssertFalse(settings.aiCommandsEnabled)
        XCTAssertNil(settings.aiSelectedModelID)
        // ...and the pre-existing settings are loaded exactly as stored (not reset).
        XCTAssertEqual(settings.stepDistance, 0.0777, accuracy: eps)
        XCTAssertTrue(settings.wrapAtEnds)
        XCTAssertTrue(settings.keepClipboardHistory)
    }

    /// `resetToDefaults()` must NOT touch the AI opt-in (it's a consent-gated choice that allows a
    /// multi-gigabyte download) nor the pinned model — mirrors the launcher / clipboard opt-in handling.
    func testResetToDefaultsDoesNotTouchAICommands() {
        let settings = makeSettings()
        settings.aiCommandsEnabled = true
        settings.aiSelectedModelID = "gemma-4-12b"

        settings.resetToDefaults()

        XCTAssertTrue(settings.aiCommandsEnabled, "reset must not flip the AI opt-in")
        XCTAssertEqual(settings.aiSelectedModelID, "gemma-4-12b", "reset must not clear the pinned model")
    }

    // MARK: - Isolation

    /// Two instances on different suites must not share state, proving suite isolation.
    func testDistinctSuitesAreIsolated() {
        // Arrange
        let settingsA = makeSettings()
        let otherName = "ThreeFingerSwitcherTests.AppSettings.\(UUID().uuidString)"
        let otherDefaults = UserDefaults(suiteName: otherName)!
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let settingsB = AppSettings(defaults: otherDefaults)

        // Act
        settingsA.stepDistance = 0.01

        // Assert: B is unaffected and still holds the default.
        XCTAssertEqual(settingsB.stepDistance, AppSettings.Defaults.stepDistance, accuracy: eps)
        XCTAssertEqual(settingsA.stepDistance, 0.01, accuracy: eps)
    }
}
