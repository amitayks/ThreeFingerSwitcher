import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the launcher-specific settings added to `AppSettings`: the consent-gated opt-in,
/// the launcher tunables and their defaults/persistence, and that a tunables reset restores the
/// tunables but leaves the system-side-effect opt-in untouched (mirroring `manageVerticalGesture`).
@MainActor
final class AppSettingsLauncherTests: XCTestCase {
    private let eps = 1e-9
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.AppSettingsLauncher.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    private func make() -> AppSettings { AppSettings(defaults: defaults) }

    func testEnableLauncherDefaultsFalseAndPersists() {
        let writer = make()
        XCTAssertFalse(writer.enableLauncher, "opt-in, off by default")

        writer.enableLauncher = true
        XCTAssertEqual(defaults.object(forKey: "enableLauncher") as? Bool, true)

        let reader = AppSettings(defaults: defaults)
        XCTAssertTrue(reader.enableLauncher, "persists across instances")
    }

    func testLauncherTunableDefaults() {
        let s = make()
        XCTAssertEqual(s.launcherActivationThreshold, AppSettings.Defaults.launcherActivationThreshold, accuracy: eps)
        XCTAssertEqual(s.launcherStepDistance, AppSettings.Defaults.launcherStepDistance, accuracy: eps)
        XCTAssertEqual(s.launcherContextStepDistance, AppSettings.Defaults.launcherContextStepDistance, accuracy: eps)
        XCTAssertEqual(s.dwellToArmDuration, AppSettings.Defaults.dwellToArmDuration, accuracy: eps)
    }

    func testDwellDefaultIsBriefNotAFullSecond() {
        XCTAssertEqual(AppSettings.Defaults.dwellToArmDuration, 0.5, accuracy: eps)
        XCTAssertLessThan(AppSettings.Defaults.dwellToArmDuration, 1.0, "dwell must be brief but deliberate")
    }

    func testContextStepLargerThanItemStep() {
        XCTAssertGreaterThan(AppSettings.Defaults.launcherContextStepDistance,
                             AppSettings.Defaults.launcherStepDistance,
                             "band switching must be harder to trigger than item stepping")
    }

    func testLauncherTunablesPersistAcrossInstances() {
        let writer = make()
        writer.launcherActivationThreshold = 0.077
        writer.launcherStepDistance = 0.066
        writer.launcherContextStepDistance = 0.155
        writer.dwellToArmDuration = 0.42

        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.launcherActivationThreshold, 0.077, accuracy: eps)
        XCTAssertEqual(reader.launcherStepDistance, 0.066, accuracy: eps)
        XCTAssertEqual(reader.launcherContextStepDistance, 0.155, accuracy: eps)
        XCTAssertEqual(reader.dwellToArmDuration, 0.42, accuracy: eps)
    }

    func testResetRestoresLauncherTunablesButNotOptIn() {
        let s = make()
        s.enableLauncher = true
        s.launcherStepDistance = 0.5
        s.dwellToArmDuration = 0.99

        s.resetToDefaults()

        XCTAssertEqual(s.launcherStepDistance, AppSettings.Defaults.launcherStepDistance, accuracy: eps)
        XCTAssertEqual(s.dwellToArmDuration, AppSettings.Defaults.dwellToArmDuration, accuracy: eps)
        XCTAssertTrue(s.enableLauncher, "reset must NOT flip the consent-gated opt-in")
    }
}
