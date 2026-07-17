import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the Full Potential persistence + settings→gate adapter on `AppSettings`
/// (`ai-full-potential-toggle`, addendum §D1). Isolated `UserDefaults` suite per test.
@MainActor
final class FullPotentialSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.FullPotential.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeSettings() -> AppSettings { AppSettings(defaults: defaults) }

    /// The six keys, paired with a read accessor, so a table-driven test stays exhaustive.
    private func allSix(_ s: AppSettings) -> [(String, Bool)] {
        [("fullPotentialEnabled", s.fullPotentialEnabled),
         ("cpuLaneEnabled", s.cpuLaneEnabled),
         ("batchedRuntimeEnabled", s.batchedRuntimeEnabled),
         ("mediaGenEnabled", s.mediaGenEnabled),
         ("backgroundAutonomyEnabled", s.backgroundAutonomyEnabled),
         ("fleetCloudEscalationEnabled", s.fleetCloudEscalationEnabled)]
    }

    // MARK: - 2.1 Defaults (all six false on a fresh store)

    func testAllSixDefaultFalse() {
        let s = makeSettings()
        for (key, value) in allSix(s) {
            XCTAssertFalse(value, "\(key) must default OFF (calm-by-default)")
        }
        XCTAssertFalse(AppSettings.Defaults.fullPotentialEnabled)
        XCTAssertFalse(AppSettings.Defaults.cpuLaneEnabled)
        XCTAssertFalse(AppSettings.Defaults.batchedRuntimeEnabled)
        XCTAssertFalse(AppSettings.Defaults.mediaGenEnabled)
        XCTAssertFalse(AppSettings.Defaults.backgroundAutonomyEnabled)
        XCTAssertFalse(AppSettings.Defaults.fleetCloudEscalationEnabled)
    }

    // MARK: - Persistence (writes documented keys; round-trips)

    func testAllSixPersistAcrossInstancesAndWriteDocumentedKeys() {
        let writer = makeSettings()
        writer.fullPotentialEnabled = true
        writer.cpuLaneEnabled = true
        writer.batchedRuntimeEnabled = true
        writer.mediaGenEnabled = true
        writer.backgroundAutonomyEnabled = true
        writer.fleetCloudEscalationEnabled = true

        // Raw documented key names (a rename breaks this).
        XCTAssertEqual(defaults.object(forKey: "fullPotentialEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "cpuLaneEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "batchedRuntimeEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "mediaGenEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "backgroundAutonomyEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "fleetCloudEscalationEnabled") as? Bool, true)

        let reader = AppSettings(defaults: defaults)
        for (key, value) in allSix(reader) {
            XCTAssertTrue(value, "\(key) persists across instances")
        }
    }

    // MARK: - 2.2 Legacy-load (keys absent ⇒ false; existing settings untouched)

    func testLegacySettingsDecodeWithAllSixOffAndUntouched() {
        // A pre-feature store: unrelated keys present, but NONE of the six Full Potential keys.
        defaults.set(0.0777, forKey: "stepDistance")
        defaults.set(true, forKey: "aiCommandsEnabled")
        for key in ["fullPotentialEnabled", "cpuLaneEnabled", "batchedRuntimeEnabled",
                    "mediaGenEnabled", "backgroundAutonomyEnabled", "fleetCloudEscalationEnabled"] {
            XCTAssertNil(defaults.object(forKey: key), "precondition: \(key) not on disk")
        }

        let s = AppSettings(defaults: defaults)
        for (key, value) in allSix(s) {
            XCTAssertFalse(value, "\(key) absent ⇒ false (legacy-load)")
        }
        // Pre-existing settings are untouched (purely additive).
        XCTAssertEqual(s.stepDistance, 0.0777, accuracy: 1e-9)
        XCTAssertTrue(s.aiCommandsEnabled)
    }

    // MARK: - 2.3 Reset preserve-set (the six are retained, a normal tunable still resets)

    func testResetToDefaultsPreservesAllSixButResetsNormalTunable() {
        let s = makeSettings()
        s.fullPotentialEnabled = true
        s.cpuLaneEnabled = true
        s.batchedRuntimeEnabled = true
        s.mediaGenEnabled = true
        s.backgroundAutonomyEnabled = true
        s.fleetCloudEscalationEnabled = true
        // A normal tunable that SHOULD reset.
        s.stepDistance = 0.5

        s.resetToDefaults()

        for (key, value) in allSix(s) {
            XCTAssertTrue(value, "\(key) is an AI opt-in — preserved by reset, not zeroed")
        }
        XCTAssertEqual(s.stepDistance, AppSettings.Defaults.stepDistance, accuracy: 1e-9,
                       "a normal tunable still resets")
    }

    // MARK: - 3.1 Settings → gate adapter

    func testAdapterMapsSettingsToFlagsVerbatim() {
        let s = makeSettings()
        s.aiCommandsEnabled = true        // consumed verbatim into aiCommandsEnabled
        s.fullPotentialEnabled = true
        s.mediaGenEnabled = true
        // others stay off

        let flags = s.fullPotentialFlags
        XCTAssertTrue(flags.aiCommandsEnabled, "enableAICommands flows into aiCommandsEnabled")
        XCTAssertTrue(flags.fullPotentialEnabled)
        XCTAssertTrue(flags.mediaGen)
        XCTAssertFalse(flags.cpuLane)
        XCTAssertFalse(flags.batchedRuntime)
        XCTAssertFalse(flags.backgroundAutonomy)
        XCTAssertFalse(flags.fleetCloud)

        // The convenience gate resolves from the same flags.
        let gate = s.fullPotentialGate
        XCTAssertTrue(gate.isUnlocked(.mediaGen), "media unlocked per the fixture")
        XCTAssertFalse(gate.isUnlocked(.cpuLane), "cpu lane stays locked")
    }

    /// The adapter honors the AI-commands gate: master + sub-flag on, but AI-commands off ⇒ locked.
    func testAdapterGateLocksWhenAICommandsOff() {
        let s = makeSettings()
        s.aiCommandsEnabled = false
        s.fullPotentialEnabled = true
        s.mediaGenEnabled = true

        XCTAssertFalse(s.fullPotentialGate.isUnlocked(.mediaGen),
                       "AI-commands off ⇒ every capability locked (fleet is a subset of the AI feature)")
    }
}
