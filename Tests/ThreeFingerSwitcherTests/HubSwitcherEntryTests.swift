import XCTest
import AppKit
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for `HubSwitcherEntry` — the pure builder + commit-decision helper that injects the
/// app's own configuration Hub window into the switcher snapshot as a synthetic, icon-only card.
///
/// Behavior under test (from Sources/.../Windows/HubSwitcherEntry.swift):
///   - The entry is produced ONLY when the Hub is visible (`isVisible == true`); otherwise `nil`.
///   - The entry's `id` is the Hub's `windowNumber` (a usable CGWindowID + the commit-recognition key).
///   - The entry carries no AX element and no thumbnail (icon-only card via `appIcon`).
///   - The title is "<appName> Hub".
///   - Space placement: copy a co-resident snapshot window's spaceID/spaceIndex/isOnCurrentSpace when
///     one shares the Hub's Space; else use the captured Hub Space (current iff it == active Space) at
///     its OWN index (`hubSpaceIndex`, falling back to the current index only when unknown); else fall
///     back to the current Space.
///   - `isHub(selectedID:hubWindowNumber:)` recognizes the Hub's id, and never matches a nil number.
final class HubSwitcherEntryTests: XCTestCase {

    // MARK: - Helpers

    private func makeWindow(
        id: CGWindowID,
        isOnCurrentSpace: Bool,
        spaceID: CGSSpaceID?,
        spaceIndex: Int
    ) -> WindowInfo {
        WindowInfo(
            id: id,
            pid: pid_t(id),
            appName: "App",
            title: "",
            appIcon: nil,
            frame: .zero,
            axElement: nil,
            isOnCurrentSpace: isOnCurrentSpace,
            spaceID: spaceID,
            spaceIndex: spaceIndex
        )
    }

    // MARK: - Inclusion gate

    func testNotVisibleProducesNoEntry() {
        let entry = HubSwitcherEntry.make(
            isVisible: false,
            windowNumber: 42,
            appName: "ThreeFingerSwitcher",
            icon: nil,
            hubSpaceID: 7,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 7,
            currentSpaceIndex: 0
        )
        XCTAssertNil(entry, "A hidden Hub must not appear in the switcher")
    }

    func testVisibleProducesAnEntry() {
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 42,
            appName: "ThreeFingerSwitcher",
            icon: nil,
            hubSpaceID: 7,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 7,
            currentSpaceIndex: 0
        )
        XCTAssertNotNil(entry, "A visible Hub must appear in the switcher")
    }

    // MARK: - Identity, title, icon-only

    func testEntryFieldsAreSynthetic() {
        let icon = NSImage(size: NSSize(width: 1, height: 1))
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1234,
            appName: "ThreeFingerSwitcher",
            icon: icon,
            hubSpaceID: 7,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 7,
            currentSpaceIndex: 0
        )
        let hub = try? XCTUnwrap(entry)
        XCTAssertEqual(hub?.id, CGWindowID(1234), "id is the window number")
        XCTAssertEqual(hub?.pid, getpid(), "the Hub belongs to our own process")
        XCTAssertEqual(hub?.title, "ThreeFingerSwitcher Hub", "title is '<appName> Hub'")
        XCTAssertEqual(hub?.displayTitle, "ThreeFingerSwitcher Hub")
        XCTAssertNil(hub?.axElement, "synthetic entry carries no AX element")
        XCTAssertNotNil(hub?.appIcon, "icon-only card uses the app icon")
        XCTAssertEqual(hub?.realFrame, .zero, "no real frame → thumbnail checks no-op")
    }

    func testTitleUsesProvidedAppName() {
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 5,
            appName: "MyApp",
            icon: nil,
            hubSpaceID: nil,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 1,
            currentSpaceIndex: 0
        )
        XCTAssertEqual(entry?.title, "MyApp Hub")
    }

    // MARK: - Space placement

    func testCopiesCoResidentSnapshotWindowSpaceRow() {
        // A snapshot window on the Hub's Space (id 9, index 2, NOT current) → the Hub copies its row.
        let sibling = makeWindow(id: 100, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 2)
        let other = makeWindow(id: 200, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 0)
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 9,
            hubSpaceIndex: nil,
            snapshot: [other, sibling],
            currentSpaceID: 3,
            currentSpaceIndex: 0
        )
        XCTAssertEqual(entry?.spaceID, 9, "copies the co-resident window's spaceID")
        XCTAssertEqual(entry?.spaceIndex, 2, "copies the co-resident window's spaceIndex (the row)")
        XCTAssertEqual(entry?.isOnCurrentSpace, false, "copies the co-resident window's current flag")
    }

    func testFallsBackToHubSpaceWhenNoCoResidentWindow() {
        // No snapshot window on the Hub's Space (8). The Hub's Space IS the current Space → current.
        let other = makeWindow(id: 200, isOnCurrentSpace: false, spaceID: 3, spaceIndex: 1)
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 8,
            hubSpaceIndex: 0,
            snapshot: [other],
            currentSpaceID: 8,
            currentSpaceIndex: 0
        )
        XCTAssertEqual(entry?.spaceID, 8, "uses the captured Hub Space")
        XCTAssertEqual(entry?.spaceIndex, 0, "the Hub Space's own index (== the current index here)")
        XCTAssertEqual(entry?.isOnCurrentSpace, true, "Hub Space == active Space → current")
    }

    func testHubSpaceDifferentFromCurrentIsNotCurrent() {
        // Hub opened on Space 8 (index 3, not current), no co-resident window, active Space is 3 (index 1).
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 8,
            hubSpaceIndex: 3,
            snapshot: [],
            currentSpaceID: 3,
            currentSpaceIndex: 1
        )
        XCTAssertEqual(entry?.spaceID, 8)
        XCTAssertEqual(entry?.isOnCurrentSpace, false, "Hub Space != active Space → not current")
        XCTAssertEqual(entry?.spaceIndex, 3, "an off-current Hub Space keeps its OWN row index, not the current one")
    }

    func testOffCurrentHubSpaceWithUnknownIndexFallsBackToCurrentRow() {
        // Same placement, but the Hub Space's index is unknown → the only valid row we know is the current.
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 8,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 3,
            currentSpaceIndex: 1
        )
        XCTAssertEqual(entry?.spaceID, 8)
        XCTAssertEqual(entry?.isOnCurrentSpace, false)
        XCTAssertEqual(entry?.spaceIndex, 1, "unknown Hub Space index → current index as the fallback row")
    }

    func testFallsBackToCurrentSpaceWhenNoHubSpaceCaptured() {
        // No captured Hub Space (legacy / off-Space unavailable) → land on the current Space.
        let entry = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 1,
            appName: "TFS",
            icon: nil,
            hubSpaceID: nil,
            hubSpaceIndex: nil,
            snapshot: [],
            currentSpaceID: 5,
            currentSpaceIndex: 2
        )
        XCTAssertEqual(entry?.spaceID, 5, "falls back to the current Space id")
        XCTAssertEqual(entry?.spaceIndex, 2, "falls back to the current Space index")
        XCTAssertEqual(entry?.isOnCurrentSpace, true, "current-Space fallback is current")
    }

    // MARK: - Commit decision

    func testIsHubMatchesTheWindowNumber() {
        XCTAssertTrue(HubSwitcherEntry.isHub(selectedID: CGWindowID(77), hubWindowNumber: 77))
    }

    func testIsHubRejectsOtherIDs() {
        XCTAssertFalse(HubSwitcherEntry.isHub(selectedID: CGWindowID(78), hubWindowNumber: 77))
    }

    func testIsHubNeverMatchesNilWindowNumber() {
        XCTAssertFalse(HubSwitcherEntry.isHub(selectedID: CGWindowID(0), hubWindowNumber: nil),
                       "with no Hub window, no selection is the Hub")
    }

    // MARK: - End-to-end with SpaceGrouping (the card lands in the right row)

    func testInjectedHubGroupsIntoItsSpaceRow() {
        // Snapshot: two windows on the current Space (index 0) and one off-Space (index 1). The Hub was
        // opened on the off-Space (index 1) — its card must land in that second row.
        let cur1 = makeWindow(id: 10, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 0)
        let cur2 = makeWindow(id: 11, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 0)
        let off = makeWindow(id: 20, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 1)
        var snapshot = [cur1, cur2, off]

        let hub = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 999,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 9,            // Hub opened on the off-Space
            hubSpaceIndex: 1,
            snapshot: snapshot,
            currentSpaceID: 3,
            currentSpaceIndex: 0
        )
        snapshot.append(try! XCTUnwrap(hub))

        let grid = SpaceGrouping.group(snapshot)
        XCTAssertEqual(grid.rows.count, 2, "two Space-rows (current + off-Space)")
        XCTAssertEqual(grid.rows[0].map(\.id), [10, 11], "current Space row unchanged")
        XCTAssertEqual(grid.rows[1].map(\.id), [20, 999], "Hub card lands in the off-Space row")
        XCTAssertEqual(grid.startRow, 0, "current Space still highlighted at its own position")
        XCTAssertEqual(grid.labels, ["1", "2"])
    }

    func testInjectedHubOnCurrentSpaceJoinsCurrentRow() {
        // Hub opened on the current Space → its card joins the current row.
        let cur1 = makeWindow(id: 10, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 0)
        let off = makeWindow(id: 20, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 1)
        var snapshot = [cur1, off]

        let hub = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 999,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 3,            // Hub on the current Space
            hubSpaceIndex: 0,
            snapshot: snapshot,
            currentSpaceID: 3,
            currentSpaceIndex: 0
        )
        snapshot.append(try! XCTUnwrap(hub))

        let grid = SpaceGrouping.group(snapshot)
        XCTAssertEqual(grid.rows.count, 2)
        XCTAssertEqual(grid.rows[0].map(\.id), [10, 999], "Hub joins the current Space row")
        XCTAssertEqual(grid.rows[1].map(\.id), [20])
        XCTAssertEqual(grid.startRow, 0)
    }

    func testInjectedHubAloneOnEmptyOffSpaceGetsItsOwnRow() {
        // Snapshot: current Space (index 0) and one off-Space (index 1). The Hub was opened on a THIRD Space
        // (id 12, index 2) that has no other window. Before the fix its card took the CURRENT index (0) and
        // was bucketed under a duplicate "1" label; now it lands in its own third row labeled "3".
        let cur = makeWindow(id: 10, isOnCurrentSpace: true, spaceID: 3, spaceIndex: 0)
        let off = makeWindow(id: 20, isOnCurrentSpace: false, spaceID: 9, spaceIndex: 1)
        var snapshot = [cur, off]

        let hub = HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: 999,
            appName: "TFS",
            icon: nil,
            hubSpaceID: 12,           // empty Space, no co-resident window
            hubSpaceIndex: 2,
            snapshot: snapshot,
            currentSpaceID: 3,
            currentSpaceIndex: 0
        )
        snapshot.append(try! XCTUnwrap(hub))

        let grid = SpaceGrouping.group(snapshot)
        XCTAssertEqual(grid.rows.count, 3, "the Hub's empty Space becomes its own row")
        XCTAssertEqual(grid.rows[0].map(\.id), [10])
        XCTAssertEqual(grid.rows[1].map(\.id), [20])
        XCTAssertEqual(grid.rows[2].map(\.id), [999], "Hub card lands alone in the third row")
        XCTAssertEqual(grid.labels, ["1", "2", "3"], "no duplicate row label")
        XCTAssertEqual(grid.startRow, 0)
    }
}
