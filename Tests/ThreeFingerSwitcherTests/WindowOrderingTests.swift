import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `WindowOrdering` sort key (from Sources/.../Windows/WindowOrdering.swift).
///
/// Behavior under test:
///   - PRIMARY: `winRank` ascending (per-window focus recency; `Int.max` = never focused).
///   - then `onCurrent` (current-Space windows first),
///   - then `spaceIdx` ascending (Mission Control Space order),
///   - then `z` ascending (on-screen stacking order),
///   - FINAL tiebreak: `appRank` ascending (effectively unreachable — `z` is unique per window).
///
/// No AppKit/AX is involved, so these are plain value tests over `WindowOrdering.Key`.
final class WindowOrderingTests: XCTestCase {

    // MARK: - Helpers

    /// A tagged row carrying its sort fields plus an `id` for order assertions.
    private struct Row {
        let id: Int
        let winRank: Int
        let onCurrent: Bool
        let spaceIdx: Int
        let z: Int
        let appRank: Int
    }

    private func key(_ r: Row) -> WindowOrdering.Key {
        WindowOrdering.Key(winRank: r.winRank, onCurrent: r.onCurrent, spaceIdx: r.spaceIdx, z: r.z, appRank: r.appRank)
    }

    private func sortedIDs(_ rows: [Row]) -> [Int] {
        var rows = rows
        WindowOrdering.sort(&rows, key: key)
        return rows.map(\.id)
    }

    // MARK: - Primary: per-window recency, interleaved across apps

    /// Same-app windows must NOT clump: they interleave with other apps by per-window recency.
    func testSameAppWindowsInterleaveByPerWindowRecency() {
        // Arrange: two Chrome windows (app A, appRank 0) and one Terminal (app B, appRank 1),
        // all on the current Space. The user alternates Chrome#1 (rank 1) <-> Terminal (rank 0);
        // the second Chrome (#2) was never focused (rank Int.max).
        let chrome1 = Row(id: 1, winRank: 1, onCurrent: true, spaceIdx: 0, z: 0, appRank: 0)
        let chrome2 = Row(id: 2, winRank: Int.max, onCurrent: true, spaceIdx: 0, z: 1, appRank: 0)
        let terminal = Row(id: 3, winRank: 0, onCurrent: true, spaceIdx: 0, z: 2, appRank: 1)

        // Act
        let ids = sortedIDs([chrome2, chrome1, terminal])

        // Assert: Terminal (most recent) first, then the focused Chrome, then the untouched Chrome —
        // the untouched same-app window is NOT clustered ahead of the more-recent Terminal.
        XCTAssertEqual(ids, [3, 1, 2])
    }

    /// "Previous window is adjacent across apps": a single step from current reaches the previously
    /// focused window of another app, not an untouched same-app window.
    func testCurrentFirstPreviousSecondAcrossApps() {
        // Arrange: current window is the Terminal (rank 0, app B); previous is Chrome#1 (rank 1, app A);
        // an untouched Chrome#2 (never focused) shares app A.
        let terminal = Row(id: 3, winRank: 0, onCurrent: true, spaceIdx: 0, z: 5, appRank: 1)
        let chrome1 = Row(id: 1, winRank: 1, onCurrent: true, spaceIdx: 0, z: 0, appRank: 0)
        let chrome2 = Row(id: 2, winRank: Int.max, onCurrent: true, spaceIdx: 0, z: 1, appRank: 0)

        // Act
        let ids = sortedIDs([chrome1, chrome2, terminal])

        // Assert: index 0 = current (Terminal), index 1 = previous (Chrome#1).
        XCTAssertEqual(ids.first, 3, "Current/frontmost window is ordered first")
        XCTAssertEqual(ids[1], 1, "The previously focused window is ordered second, across apps")
        XCTAssertEqual(ids.last, 2, "The untouched same-app window falls to the back")
    }

    // MARK: - Fallback for never-focused windows

    /// Never-focused windows (rank Int.max) order after all focused ones, then by current-Space,
    /// then by Space index, then by z-order — byte-for-byte the legacy heuristic.
    func testNeverFocusedFallBackToCurrentSpaceThenSpaceIndexThenZ() {
        // Arrange: all four windows are never-focused (rank Int.max).
        //   - one current-Space window (should lead),
        //   - then off-Space windows by ascending spaceIdx,
        //   - z breaks ties within the same Space.
        let offSpace2 = Row(id: 1, winRank: Int.max, onCurrent: false, spaceIdx: 2, z: 0, appRank: 0)
        let current = Row(id: 2, winRank: Int.max, onCurrent: true, spaceIdx: 1, z: 9, appRank: 1)
        let offSpace1a = Row(id: 3, winRank: Int.max, onCurrent: false, spaceIdx: 1, z: 4, appRank: 0)
        let offSpace1b = Row(id: 4, winRank: Int.max, onCurrent: false, spaceIdx: 1, z: 2, appRank: 0)

        // Act
        let ids = sortedIDs([offSpace2, current, offSpace1a, offSpace1b])

        // Assert: current first; then off-Space at spaceIdx 1 (z 2 before z 4); then spaceIdx 2.
        XCTAssertEqual(ids, [2, 4, 3, 1])
    }

    /// A window WITH recency always precedes every never-focused window, regardless of Space/z.
    func testFocusedWindowPrecedesAllNeverFocusedWindows() {
        // Arrange: a focused off-Space window (rank 0) vs a never-focused current-Space window.
        let focusedOffSpace = Row(id: 1, winRank: 0, onCurrent: false, spaceIdx: 3, z: 9, appRank: 5)
        let unfocusedCurrent = Row(id: 2, winRank: Int.max, onCurrent: true, spaceIdx: 0, z: 0, appRank: 0)

        // Act
        let ids = sortedIDs([unfocusedCurrent, focusedOffSpace])

        // Assert: recency dominates even current-Space/z — the focused window leads.
        XCTAssertEqual(ids, [1, 2])
    }

    // MARK: - Tiebreak ladder

    func testCurrentSpaceBeatsOffSpaceWhenRanksTie() {
        // Arrange: equal winRank; current-Space must win.
        let off = Row(id: 1, winRank: 2, onCurrent: false, spaceIdx: 0, z: 0, appRank: 0)
        let current = Row(id: 2, winRank: 2, onCurrent: true, spaceIdx: 9, z: 9, appRank: 9)

        // Act
        let ids = sortedIDs([off, current])

        // Assert
        XCTAssertEqual(ids, [2, 1], "Current Space wins when winRank ties")
    }

    func testSpaceIndexBreaksTieBeforeZ() {
        // Arrange: equal winRank + onCurrent; lower spaceIdx wins before z is consulted.
        let higherSpaceLowerZ = Row(id: 1, winRank: 1, onCurrent: false, spaceIdx: 2, z: 0, appRank: 0)
        let lowerSpaceHigherZ = Row(id: 2, winRank: 1, onCurrent: false, spaceIdx: 1, z: 9, appRank: 0)

        // Act
        let ids = sortedIDs([higherSpaceLowerZ, lowerSpaceHigherZ])

        // Assert
        XCTAssertEqual(ids, [2, 1], "Lower spaceIdx wins even with a higher z")
    }

    func testZBreaksTieBeforeAppRank() {
        // Arrange: equal winRank/onCurrent/spaceIdx; lower z wins before appRank.
        let higherZLowerApp = Row(id: 1, winRank: 1, onCurrent: true, spaceIdx: 0, z: 5, appRank: 0)
        let lowerZHigherApp = Row(id: 2, winRank: 1, onCurrent: true, spaceIdx: 0, z: 1, appRank: 9)

        // Act
        let ids = sortedIDs([higherZLowerApp, lowerZHigherApp])

        // Assert
        XCTAssertEqual(ids, [2, 1], "Lower z wins before appRank is consulted")
    }
}
