import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `SpaceService.model(fromDisplays:apiCurrentSpace:)` builder — the selection
/// rules over the `CGSCopyManagedDisplaySpaces` dictionary array, exercised without the private API.
///
/// Behavior under test (from Sources/.../Windows/Spaces.swift):
///   - Space ids are ordered display-by-display (Mission Control order) and indexed; repeats keep their
///     first index.
///   - `currentSpaceIDs` holds every display's current Space (dict value, plus the API refinement for
///     real display UUIDs — never for the "Main" sentinel).
///   - `primaryCurrentSpaceID` is the FIRST display's current Space — deterministic, unlike `.first` on
///     the Set — with the API as that display's fallback and the next display as the last resort.
///   - No Spaces at all → no model.
final class SpaceModelTests: XCTestCase {

    // MARK: - Helpers

    private func display(_ identifier: String, spaces: [UInt64], current: UInt64?) -> [String: Any] {
        var d: [String: Any] = [
            "Display Identifier": identifier,
            "Spaces": spaces.map { ["id64": NSNumber(value: $0)] as [String: Any] },
        ]
        if let current {
            d["Current Space"] = ["id64": NSNumber(value: current)] as [String: Any]
        }
        return d
    }

    private var twoDisplays: [[String: Any]] {
        [
            display("Main", spaces: [1, 2, 3], current: 2),
            display("UUID-B", spaces: [10, 11], current: 11),
        ]
    }

    // MARK: - Ordering

    func testOrdersSpacesAcrossDisplaysAndIndexesThem() {
        let model = SpaceService.model(fromDisplays: twoDisplays)
        XCTAssertEqual(model?.orderedSpaceIDs, [1, 2, 3, 10, 11])
        XCTAssertEqual(model?.indexBySpace[1], 0)
        XCTAssertEqual(model?.indexBySpace[3], 2)
        XCTAssertEqual(model?.indexBySpace[11], 4)
    }

    func testRepeatedSpaceIDsKeepTheirFirstIndex() {
        let model = SpaceService.model(fromDisplays: [
            display("Main", spaces: [1, 2], current: 1),
            display("UUID-B", spaces: [2, 3], current: 3),
        ])
        XCTAssertEqual(model?.orderedSpaceIDs, [1, 2, 3])
        XCTAssertEqual(model?.indexBySpace[2], 1)
    }

    func testNoSpacesYieldsNoModel() {
        XCTAssertNil(SpaceService.model(fromDisplays: []))
        XCTAssertNil(SpaceService.model(fromDisplays: [display("Main", spaces: [], current: nil)]))
    }

    // MARK: - Current Spaces (membership)

    func testCurrentSpaceIDsHoldOnePerDisplay() {
        let model = SpaceService.model(fromDisplays: twoDisplays)
        XCTAssertEqual(model?.currentSpaceIDs, Set<CGSSpaceID>([2, 11]))
    }

    func testAPIRefinesRealDisplaysButIsNeverAskedAboutMain() {
        var asked: [String] = []
        let model = SpaceService.model(fromDisplays: [
            display("Main", spaces: [1, 2], current: 2),
            display("UUID-B", spaces: [10, 11], current: 10),
        ]) { identifier in
            asked.append(identifier)
            return 11
        }
        XCTAssertEqual(asked, ["UUID-B"], "the Main sentinel is not a valid UUID for the API")
        XCTAssertEqual(model?.currentSpaceIDs, Set<CGSSpaceID>([2, 10, 11]), "dict value and API value both count")
        XCTAssertEqual(model?.primaryCurrentSpaceID, 2, "the first display's dict value stays primary")
    }

    // MARK: - Primary current Space (determinism)

    func testPrimaryIsTheFirstDisplaysCurrentSpace() {
        XCTAssertEqual(SpaceService.model(fromDisplays: twoDisplays)?.primaryCurrentSpaceID, 2)
        // Reversing the display order flips it: display order, not hash order, decides.
        let flipped = SpaceService.model(fromDisplays: Array(twoDisplays.reversed()))
        XCTAssertEqual(flipped?.primaryCurrentSpaceID, 11)
    }

    func testPrimaryIsStableAcrossRebuilds() {
        // The regression this guards: `currentSpaceIDs.first` is Set hash order — arbitrary per build.
        let primaries = Set((0..<64).compactMap { _ in SpaceService.model(fromDisplays: twoDisplays)?.primaryCurrentSpaceID })
        XCTAssertEqual(primaries, [2])
    }

    func testPrimaryFallsBackToAPIWhenFirstDisplayDictHasNoCurrent() {
        let model = SpaceService.model(fromDisplays: [
            display("UUID-A", spaces: [1, 2], current: nil),
            display("UUID-B", spaces: [10], current: 10),
        ]) { $0 == "UUID-A" ? 2 : nil }
        XCTAssertEqual(model?.primaryCurrentSpaceID, 2)
        XCTAssertEqual(model?.currentSpaceIDs, Set<CGSSpaceID>([2, 10]))
    }

    func testPrimaryFallsThroughToNextDisplayWhenFirstReportsNone() {
        let model = SpaceService.model(fromDisplays: [
            display("Main", spaces: [1, 2], current: nil),
            display("UUID-B", spaces: [10], current: 10),
        ])
        XCTAssertEqual(model?.primaryCurrentSpaceID, 10)
        XCTAssertEqual(model?.currentSpaceIDs, Set<CGSSpaceID>([10]))
    }

    func testPrimaryIsNilOnlyWhenNoDisplayReportsACurrentSpace() {
        let model = SpaceService.model(fromDisplays: [display("Main", spaces: [1, 2], current: nil)])
        XCTAssertNotNil(model)
        XCTAssertNil(model?.primaryCurrentSpaceID)
        XCTAssertEqual(model?.currentSpaceIDs, [])
    }
}
