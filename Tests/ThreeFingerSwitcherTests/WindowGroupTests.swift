import XCTest
@testable import ThreeFingerSwitcherCore

/// SnapAdjacency: pure edge-adjacency math for snap-to-bind.
final class SnapAdjacencyTests: XCTestCase {
    // Two 400×300 windows side by side, perfectly flush.
    func testFlushVerticalEdgesAreAdjacent() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 400, y: 0, width: 400, height: 300)
        XCTAssertTrue(SnapAdjacency.adjacent(a, b))
        XCTAssertTrue(SnapAdjacency.adjacent(b, a))   // symmetric
    }

    func testTiledMarginGapStillBinds() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 410, y: 0, width: 400, height: 300)   // 10pt margin gap ≤ ε (12)
        XCTAssertTrue(SnapAdjacency.adjacent(a, b))
    }

    func testGapBeyondEpsilonDoesNotBind() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 420, y: 0, width: 400, height: 300)   // 20pt > ε
        XCTAssertFalse(SnapAdjacency.adjacent(a, b))
    }

    func testCornerTouchDoesNotBind() {
        // Diagonal corner contact: edges meet but share almost no extent.
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 400, y: 290, width: 400, height: 300)   // 10pt vertical overlap < minShared
        XCTAssertFalse(SnapAdjacency.adjacent(a, b))
    }

    func testSharedExtentBelowMinimumDoesNotBind() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 400, y: 250, width: 400, height: 300)   // 50pt overlap < 60
        XCTAssertFalse(SnapAdjacency.adjacent(a, b))
    }

    func testTopBottomEdgesAreAdjacent() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 50, y: 300, width: 400, height: 300)    // b directly below a (y-down space)
        XCTAssertTrue(SnapAdjacency.adjacent(a, b))
    }

    func testDeepOverlapIsNotAdjacency() {
        // One window on top of another (identical frames): no facing-edge pair within ε.
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertFalse(SnapAdjacency.adjacent(a, a))
    }

    // MARK: - attached (the stay-bound test: touching OR overlapping)

    func testOverlapIsAttachedButNotAdjacent() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 250, y: 0, width: 400, height: 300)     // 150pt overlap
        XCTAssertFalse(SnapAdjacency.adjacent(a, b))              // never a BIND trigger
        XCTAssertTrue(SnapAdjacency.attached(a, b))               // but the bond persists
    }

    func testContainedWindowIsAttached() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 100, y: 100, width: 200, height: 200)   // fully inside
        XCTAssertTrue(SnapAdjacency.attached(a, b))
    }

    func testHairlineCornerOverlapIsNotAttached() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        let b = CGRect(x: 395, y: 295, width: 400, height: 300)   // 5×5 corner brush ≤ ε
        XCTAssertFalse(SnapAdjacency.attached(a, b))
    }
}

/// WindowGroupStore: the physical-attachment group lifecycle.
final class WindowGroupStoreTests: XCTestCase {
    func testSnapBindsTwoWindows() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        XCTAssertEqual(store.group(for: 1), [1, 2])
        XCTAssertEqual(store.group(for: 2), [1, 2])
    }

    func testBindingMergesTransitively() {
        let store = WindowGroupStore()
        store.dragSettled(window: 2, snapped: [3])       // {2,3}
        store.dragSettled(window: 1, snapped: [2])       // A onto B while B grouped with C
        XCTAssertEqual(store.group(for: 1), [1, 2, 3])
        XCTAssertEqual(store.groups.count, 1)
    }

    func testDragApartRemovesMemberAndDissolvesPairs() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        store.dragSettled(window: 1, snapped: [])        // dragged away from every mate
        XCTAssertNil(store.group(for: 1))
        XCTAssertNil(store.group(for: 2))                 // a group below two members dissolves
    }

    func testDragApartFromTrioKeepsTheRemainingPair() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2, 3])
        store.dragSettled(window: 3, snapped: [])
        XCTAssertNil(store.group(for: 3))
        XCTAssertEqual(store.group(for: 1), [1, 2])
    }

    func testRebindOntoNewContactLeavesOldGroup() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])       // {1,2}
        store.dragSettled(window: 1, snapped: [5])       // dragged from 2 onto 5
        XCTAssertEqual(store.group(for: 1), [1, 5])
        XCTAssertNil(store.group(for: 2))
    }

    func testStayingAdjacentToAMateWhileTouchingANewWindowMergesAll() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])       // {1,2}
        store.dragSettled(window: 1, snapped: [2, 5])    // still on 2, now also flush against 5
        XCTAssertEqual(store.group(for: 1), [1, 2, 5])
    }

    func testValidationDropsClosedMinimizedAndOffSpaceMembers() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2, 3])
        store.dragSettled(window: 5, snapped: [6])
        // 3 is gone (closed), 6 is minimized, everyone else lives on Space 10.
        let live: [WindowGroupStore.Candidate] = [
            .init(id: 1, spaceID: 10), .init(id: 2, spaceID: 10),
            .init(id: 5, spaceID: 10), .init(id: 6, isMinimized: true, spaceID: 10),
        ]
        let validated = store.validatedGroups(against: live)
        XCTAssertEqual(validated, [[1, 2]])               // {5,6} dissolved (below two live members)
        XCTAssertNil(store.group(for: 5))                 // validation mutates the store
    }

    func testValidationKeepsTheLargestSameSpaceSubset() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2, 3])
        let live: [WindowGroupStore.Candidate] = [
            .init(id: 1, spaceID: 10), .init(id: 2, spaceID: 10),
            .init(id: 3, spaceID: 20),                    // moved to another Space: detached
        ]
        XCTAssertEqual(store.validatedGroups(against: live), [[1, 2]])
    }

    func testClearDropsEverything() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        store.clear()
        XCTAssertNil(store.group(for: 1))
        XCTAssertTrue(store.groups.isEmpty)
    }

    // MARK: - Geometric re-validation (pruneDetached + frame-aware validatedGroups)

    func testPruneDetachedDissolvesAResizedApartPair() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        // Window 1's border was resized inward: a 100pt gap now separates the pair.
        let changed = store.pruneDetached(frames: [
            1: CGRect(x: 0, y: 0, width: 300, height: 900),
            2: CGRect(x: 400, y: 0, width: 400, height: 900),
        ])
        XCTAssertTrue(changed)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testPruneDetachedKeepsATouchingPairAndSplitsAChain() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2, 3])       // chain {1,2,3}
        // 3 moved away; 1 and 2 still flush -> {1,2} survives, 3 drops.
        store.pruneDetached(frames: [
            1: CGRect(x: 0, y: 0, width: 400, height: 900),
            2: CGRect(x: 400, y: 0, width: 400, height: 900),
            3: CGRect(x: 1200, y: 0, width: 400, height: 900),
        ])
        XCTAssertEqual(store.groups, [[1, 2]])
    }

    func testPruneDetachedLeavesGroupsWithUnknownFramesAlone() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        let changed = store.pruneDetached(frames: [1: CGRect(x: 0, y: 0, width: 400, height: 900)])
        XCTAssertFalse(changed)                              // member 2 un-enumerable: conservative keep
        XCTAssertEqual(store.group(for: 1), [1, 2])
    }

    func testValidationDropsGeometricallyDetachedMembers() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        // Both alive, same Space — but a keyboard resize opened a gap the monitor never saw.
        let live: [WindowGroupStore.Candidate] = [
            .init(id: 1, spaceID: 10, frame: CGRect(x: 0, y: 0, width: 300, height: 900)),
            .init(id: 2, spaceID: 10, frame: CGRect(x: 400, y: 0, width: 400, height: 900)),
        ]
        XCTAssertEqual(store.validatedGroups(against: live), [])
    }

    func testValidationKeepsTouchingMembersWithFrames() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        let live: [WindowGroupStore.Candidate] = [
            .init(id: 1, spaceID: 10, frame: CGRect(x: 0, y: 0, width: 400, height: 900)),
            .init(id: 2, spaceID: 10, frame: CGRect(x: 400, y: 0, width: 400, height: 900)),
        ]
        XCTAssertEqual(store.validatedGroups(against: live), [[1, 2]])
    }

    // MARK: - Overlap keeps the bond (only a gap detaches)

    func testPruneKeepsAnOverlappingPair() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        // 2 was pushed INTO 1: heavy overlap, no flush edge — still physically attached.
        let changed = store.pruneDetached(frames: [
            1: CGRect(x: 0, y: 0, width: 400, height: 900),
            2: CGRect(x: 250, y: 0, width: 400, height: 900),
        ])
        XCTAssertFalse(changed)
        XCTAssertEqual(store.group(for: 1), [1, 2])
    }

    func testDragIntoOverlapStaysBound() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        // The next drag ends OVERLAPPING the mate: no fresh snap, but attachment persists.
        store.dragSettled(window: 1, snapped: [], attached: [2])
        XCTAssertEqual(store.group(for: 1), [1, 2])
    }

    func testValidationKeepsOverlappingMembersWithFrames() {
        let store = WindowGroupStore()
        store.dragSettled(window: 1, snapped: [2])
        let live: [WindowGroupStore.Candidate] = [
            .init(id: 1, spaceID: 10, frame: CGRect(x: 0, y: 0, width: 400, height: 900)),
            .init(id: 2, spaceID: 10, frame: CGRect(x: 250, y: 0, width: 400, height: 900)),
        ]
        XCTAssertEqual(store.validatedGroups(against: live), [[1, 2]])
    }
}

/// Fused-cluster layout: grouped windows solve as ONE flow unit whose members keep their real
/// relative arrangement at the shared uniform scale.
@MainActor
final class WindowGroupLayoutTests: XCTestCase {
    private func makeWindow(id: CGWindowID, realFrame: CGRect) -> WindowInfo {
        WindowInfo(
            id: id, pid: 100, appName: "App\(id)", title: "W\(id)", appIcon: nil,
            frame: realFrame, realFrame: realFrame, axElement: nil,
            isOnCurrentSpace: true, spaceID: 1, spaceIndex: 0
        )
    }

    func testSideBySideGroupSolvesAsOneFusedUnit() {
        // Two 400×300 windows snapped flush → one 800×300 union unit at kMax = 0.24 on a wide canvas.
        let units = [SwitcherLayoutUnit.cluster(members: [
            (index: 0, natural: CGRect(x: 0, y: 0, width: 400, height: 300)),
            (index: 1, natural: CGRect(x: 400, y: 0, width: 400, height: 300)),
        ])]
        let layout = SwitcherLayout.solveGrid(units: units, canvas: CGSize(width: 2000, height: 600))

        XCTAssertEqual(layout.scale, SwitcherLayout.kMax, accuracy: 0.001)
        XCTAssertEqual(layout.units.count, 1)
        let unit = layout.units[0]
        XCTAssertTrue(unit.isCluster)
        XCTAssertEqual(unit.size.width, 192, accuracy: 0.5)     // 800 × 0.24
        XCTAssertEqual(unit.size.height, 72, accuracy: 0.5)     // 300 × 0.24 — NO min-height floor
        // Members sit flush at their scaled real offsets (fused: zero gap, unlike gridCardSpacing).
        XCTAssertEqual(unit.frames[0], CGRect(x: 0, y: 0, width: 96, height: 72))
        XCTAssertEqual(unit.frames[1], CGRect(x: 96, y: 0, width: 96, height: 72))
        // Expanded per-window views stay index-aligned.
        XCTAssertEqual(layout.rows, [[0, 1]])
        XCTAssertEqual(layout.sizes[0], CGSize(width: 96, height: 72))
    }

    func testClusterDeoverlapsOverlappingMembersToFlushContact() {
        // B overlaps A by 100pt: the preview pushes B right to flush contact (no covered cards),
        // growing the union accordingly.
        let unit = SwitcherLayoutUnit.cluster(members: [
            (index: 0, natural: CGRect(x: 0, y: 0, width: 400, height: 300)),
            (index: 1, natural: CGRect(x: 300, y: 0, width: 400, height: 300)),
        ])
        XCTAssertEqual(unit.memberFrames[0], CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(unit.memberFrames[1], CGRect(x: 400, y: 0, width: 400, height: 300))
        XCTAssertEqual(unit.naturalSize, CGSize(width: 800, height: 300))
    }

    func testClusterDeoverlapPushesAContainedWindowOut() {
        // A small window laid ON TOP of a big one (bound via overlap) must still render beside/below
        // it, never covering it. The push axis is whichever clears with less travel.
        let unit = SwitcherLayoutUnit.cluster(members: [
            (index: 0, natural: CGRect(x: 0, y: 0, width: 800, height: 600)),
            (index: 1, natural: CGRect(x: 550, y: 100, width: 200, height: 200)),
        ])
        let big = unit.memberFrames[0]
        let small = unit.memberFrames[1]
        XCTAssertTrue(big.intersection(small).isEmpty || big.intersection(small).width <= 0.5
                        || big.intersection(small).height <= 0.5, "cards must not cover each other")
        // pushRight = 800−550 = 250, pushDown = 600−100 = 500 → pushed RIGHT to flush at x = 800.
        XCTAssertEqual(small.minX, 800, accuracy: 0.5)
    }

    func testClusterFlushArrangementPassesThroughUntouched() {
        // The common case — a real flush snap — must still mirror reality exactly.
        let unit = SwitcherLayoutUnit.cluster(members: [
            (index: 0, natural: CGRect(x: 0, y: 0, width: 400, height: 300)),
            (index: 1, natural: CGRect(x: 400, y: 0, width: 400, height: 300)),
        ])
        XCTAssertEqual(unit.memberFrames[1].minX, 400)
        XCTAssertEqual(unit.naturalSize, CGSize(width: 800, height: 300))
    }

    func testClusterMembersOrderVisuallyAndMirrorTheMarginGap() {
        // Passed right-window-first: the cluster orders members left-to-right; a 10pt real margin gap
        // scales into the member frames (the fused look mirrors reality, tighter than card spacing).
        let unit = SwitcherLayoutUnit.cluster(members: [
            (index: 5, natural: CGRect(x: 410, y: 0, width: 400, height: 300)),
            (index: 2, natural: CGRect(x: 0, y: 0, width: 400, height: 300)),
        ])
        XCTAssertEqual(unit.members, [2, 5])                     // visual order, not input order
        XCTAssertEqual(unit.naturalSize, CGSize(width: 810, height: 300))
        XCTAssertEqual(unit.memberFrames[1].minX, 410)           // the real gap is preserved
    }

    func testGroupedModelPlacesClusterAndNavigatesMembersIndividually() {
        // Space: two lone 300×300 squares + a side-by-side snapped pair (windows 2+3). Canvas 250pt
        // wide → flow rows [s0,s1] then [cluster], stacked bottom-to-top: cluster on TOP.
        let model = SwitcherModel()
        model.setCanvas(CGSize(width: 250, height: 400))
        let square = CGRect(x: 0, y: 0, width: 300, height: 300)
        let windows = [
            makeWindow(id: 100, realFrame: square),
            makeWindow(id: 101, realFrame: square),
            makeWindow(id: 102, realFrame: CGRect(x: 0, y: 0, width: 300, height: 300)),
            makeWindow(id: 103, realFrame: CGRect(x: 300, y: 0, width: 300, height: 300)),
        ]
        model.setRows([windows], labels: ["1"], startRow: 0, column: 0, groups: [[102, 103]])

        // Grid: top row = the fused pair (expanded [2, 3]), bottom row = the singles.
        XCTAssertEqual(model.gridLayout.rows, [[2, 3], [0, 1]])
        XCTAssertEqual(model.gridLayout.units.count, 3)
        XCTAssertEqual(model.gridLayout.sizes[2], CGSize(width: 72, height: 72))   // unfloored member
        XCTAssertEqual(model.gridLayout.sizes[0], CGSize(width: 84, height: 84))   // floored single

        // Individual selection: scrub to the bottom-right single, step up → lands on the cluster
        // member whose span overlaps the anchor (the RIGHT member), not a hardcoded first card.
        model.moveHorizontal(1, wrap: false)          // bottom row col 1 (center +50)
        XCTAssertEqual(model.moveVertical(1), .moved)
        XCTAssertEqual(model.selectedIndex, 3)        // right member of the pair
        model.moveHorizontal(-1, wrap: false)         // walk WITHIN the cluster like any neighbors
        XCTAssertEqual(model.selectedIndex, 2)
    }

    func testNoGroupsMatchesTheNaturalsSolveExactly() {
        let naturals = [CGSize(width: 300, height: 300), CGSize(width: 480, height: 300),
                        CGSize(width: 300, height: 520)]
        let canvas = CGSize(width: 500, height: 420)
        let old = SwitcherLayout.solveGrid(naturals: naturals, canvas: canvas)
        let units = naturals.enumerated().map { SwitcherLayoutUnit.single($0.offset, natural: $0.element) }
        let new = SwitcherLayout.solveGrid(units: units, canvas: canvas)
        XCTAssertEqual(old.scale, new.scale)
        XCTAssertEqual(old.rows, new.rows)
        XCTAssertEqual(old.sizes, new.sizes)
        XCTAssertEqual(old.contentSize, new.contentSize)
    }

    func testWindowSpansOverAClusterRowHaveNoIntraClusterSpacing() {
        let cluster = SwitcherGridUnit(
            members: [0, 1],
            frames: [CGRect(x: 0, y: 0, width: 96, height: 72), CGRect(x: 96, y: 0, width: 96, height: 72)],
            size: CGSize(width: 192, height: 72)
        )
        let single = SwitcherGridUnit(
            members: [2],
            frames: [CGRect(x: 0, y: 0, width: 84, height: 84)],
            size: CGSize(width: 84, height: 84)
        )
        let spans = SwitcherLayout.windowSpans(unitRow: [0, 1], units: [cluster, single])
        // Row width = 192 + 16 + 84 = 292 → starts at −146.
        XCTAssertEqual(spans.map(\.index), [0, 1, 2])
        XCTAssertEqual(spans[0].span.lowerBound, -146, accuracy: 0.01)
        XCTAssertEqual(spans[0].span.upperBound, -50, accuracy: 0.01)
        XCTAssertEqual(spans[1].span.lowerBound, -50, accuracy: 0.01)    // flush with member 0
        XCTAssertEqual(spans[2].span.lowerBound, 62, accuracy: 0.01)     // 46 + 16 spacing
    }
}
