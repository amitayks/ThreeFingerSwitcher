import XCTest
@testable import ThreeFingerSwitcherCore

/// Persistence + defaults + reset for the new Files action settings (`tunable-settings`): the lift action,
/// the per-type action-menu lists, and the curated-tools allow-list — mirroring the `GestureBindings`
/// persistence tests' UserDefaults-suite pattern.
@MainActor
final class FilesActionSettingsTests: XCTestCase {

    private func makeSettings() -> (AppSettings, String, UserDefaults) {
        let suite = "ThreeFingerSwitcherTests.FilesActions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), suite, defaults)
    }

    func testDefaultsMatchSpec() {
        let (settings, suite, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(settings.filesLiftAction, .deliver, "lift defaults to deliver")
        XCTAssertEqual(settings.filesActionMenu, .default, "menus default to the specified lists")
        XCTAssertEqual(settings.filesToolsDisabled, [], "all detected tools enabled by default")
    }

    func testFilesActionSettingsPersistAcrossInstances() {
        let (writer, suite, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        writer.filesLiftAction = .open
        writer.filesActionMenu.fileItems = [.addToFavorites, .copyAsPath, .openIn]
        writer.filesToolsDisabled = ["com.googlecode.iterm2"]

        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.filesLiftAction, .open, "lift action survived the reload")
        XCTAssertEqual(reader.filesActionMenu.fileItems, [.addToFavorites, .copyAsPath, .openIn],
                       "the customized file menu survived the reload")
        XCTAssertEqual(reader.filesToolsDisabled, ["com.googlecode.iterm2"], "the tool curation survived")
    }

    func testResetRestoresFilesActionDefaults() {
        let (settings, suite, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.filesLiftAction = .open
        settings.filesActionMenu.folderItems = [.openIn]
        settings.filesToolsDisabled = ["com.apple.Terminal"]

        settings.resetToDefaults()

        XCTAssertEqual(settings.filesLiftAction, .deliver, "reset restores the deliver lift")
        XCTAssertEqual(settings.filesActionMenu, .default, "reset restores the default menus")
        XCTAssertEqual(settings.filesToolsDisabled, [], "reset re-enables all tools")
    }

    func testMissingMenuBlobFallsBackToDefault() {
        let (settings, suite, defaults) = makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A garbage blob under the menu key must decode to the default, not crash.
        defaults.set(Data("not json".utf8), forKey: "filesActionMenu")
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.filesActionMenu, .default, "an unreadable menu blob falls back to the default")
        _ = settings
    }
}
