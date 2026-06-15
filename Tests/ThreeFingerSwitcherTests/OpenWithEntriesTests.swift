import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for `OpenWithEntries.build` (spec files-band): the external apps that can open the file, wrapped
/// as `.external` rows in the system's order, with the default app flagged.
final class OpenWithEntriesTests: XCTestCase {

    private func external(_ name: String, isDefault: Bool = false) -> OpenWithCandidate {
        OpenWithCandidate(app: AppCandidate(url: URL(fileURLWithPath: "/Applications/\(name).app")),
                          isDefault: isDefault)
    }

    func testWrapsExternalsInOrderWithDefaultFlagged() {
        let externals = [external("QuickTime", isDefault: true), external("VLC")]
        let entries = OpenWithEntries.build(externalApps: externals)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], .external(externals[0]))
        XCTAssertEqual(entries[1], .external(externals[1]))
        XCTAssertTrue(entries[0].isDefault, "the default external app is flagged")
        XCTAssertFalse(entries[1].isDefault)
    }

    func testEmptyWhenNoExternalApps() {
        XCTAssertTrue(OpenWithEntries.build(externalApps: []).isEmpty)
    }
}
