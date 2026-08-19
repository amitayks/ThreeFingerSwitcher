import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the Danger zone's reset service (Settings/AppDataReset.swift): the pure
/// filesystem-target computation per selection, the TCC service list, and the perform step against
/// a temp directory + command spy.
@MainActor
final class AppDataResetTests: XCTestCase {
    private let library = URL(fileURLWithPath: "/Users/test/Library", isDirectory: true)
    private let bid = "com.threefingerswitcher.app"

    private func targets(_ s: DangerZoneSelection) -> AppDataReset.FilesystemTargets {
        AppDataReset.filesystemTargets(for: s, library: library, bundleID: bid)
    }

    private func paths(_ urls: [URL]) -> Set<String> { Set(urls.map(\.path)) }

    // MARK: - Pure target computation

    func testEmptySelectionTouchesNothing() {
        let t = targets([])
        XCTAssertTrue(t.removeWhole.isEmpty)
        XCTAssertTrue(t.removeContentsExcept.isEmpty)
    }

    func testAppDataRemovesTheWholeRoot() {
        let t = targets(.appData)
        XCTAssertTrue(t.removeContentsExcept.isEmpty)
        XCTAssertEqual(paths(t.removeWhole),
                       ["/Users/test/Library/Application Support/ThreeFingerSwitcher",
                        "/Users/test/Library/Saved Application State/\(bid).savedState"])
    }

    func testCaches() {
        let t = targets(.caches)
        XCTAssertEqual(paths(t.removeWhole),
                       ["/Users/test/Library/Caches/\(bid)",
                        "/Users/test/Library/HTTPStorages/\(bid)"])
    }

    func testPermissionsAloneTouchesNoFiles() {
        let t = targets(.permissions)
        XCTAssertTrue(t.removeWhole.isEmpty)
        XCTAssertTrue(t.removeContentsExcept.isEmpty)
    }

    func testTCCServiceListCoversEverythingTheAppCanHold() {
        XCTAssertEqual(Set(AppDataReset.tccServices),
                       ["Accessibility", "ScreenCapture", "ListenEvent", "AppleEvents"])
    }

    // MARK: - Perform step (temp filesystem + command spy)

    /// A throwaway `~/Library` under the temp dir, so `clear()`'s real, destructive filesystem deletions
    /// never touch the user's actual home (the Application Support root is hardcoded, NOT keyed by the
    /// fake bundleID — without this seam the suite wiped the real clipboard/AI stores). Per test.
    private func tempLibrary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDataResetTests-\(UUID())/Library", isDirectory: true)
    }

    func testClearPermissionsRunsTCCUtilPerService() {
        var commands: [[String]] = []
        let reset = AppDataReset(bundleID: bid,
                                 defaults: UserDefaults(suiteName: "AppDataResetTests.\(UUID())")!,
                                 library: tempLibrary(),
                                 runCommand: { launchPath, args in
                                     XCTAssertEqual(launchPath, "/usr/bin/tccutil")
                                     commands.append(args)
                                     return true
                                 })
        let outcome = reset.clear(.permissions)
        XCTAssertEqual(commands.count, AppDataReset.tccServices.count)
        XCTAssertTrue(commands.allSatisfy { $0.first == "reset" && $0.last == bid })
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testFailedTCCResetIsCollectedNotFatal() {
        let reset = AppDataReset(bundleID: bid,
                                 defaults: UserDefaults(suiteName: "AppDataResetTests.\(UUID())")!,
                                 library: tempLibrary(),
                                 runCommand: { _, _ in false })
        let outcome = reset.clear(.permissions)
        XCTAssertEqual(outcome.failures.count, AppDataReset.tccServices.count)
    }

    func testAppDataClearWipesThePreferencesDomain() {
        let suite = "AppDataResetTests.prefs.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "anything")
        let reset = AppDataReset(bundleID: suite, defaults: defaults, library: tempLibrary(),
                                 runCommand: { _, _ in true })
        _ = reset.clear(.appData)
        XCTAssertNil(defaults.persistentDomain(forName: suite), "the domain is removed")
        defaults.removePersistentDomain(forName: suite)
    }
}
