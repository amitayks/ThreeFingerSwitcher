import XCTest
@testable import ThreeFingerSwitcherCore

/// The pure picker brain (spec `screen-region-picker`): the drag → rectangle geometry and the
/// click-without-drag → cancel verdict, verified headless (no overlay, no ScreenCaptureKit).
final class RegionPickerModelTests: XCTestCase {

    func testDragCommitsNormalizedRegion() {
        var model = RegionPickerModel()
        model.begin(at: CGPoint(x: 100, y: 100))
        model.drag(to: CGPoint(x: 300, y: 250))
        let resolution = model.end(at: CGPoint(x: 300, y: 250))
        XCTAssertEqual(resolution, .region(CGRect(x: 100, y: 100, width: 200, height: 150)))
    }

    func testDragInAnyDirectionNormalizesToPositiveRect() {
        // Drag up-and-left: origin is the bottom-right of the resulting rect.
        var model = RegionPickerModel()
        model.begin(at: CGPoint(x: 300, y: 250))
        let resolution = model.end(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(resolution, .region(CGRect(x: 100, y: 100, width: 200, height: 150)))
    }

    func testClickWithoutDraggingCancels() {
        var model = RegionPickerModel()
        model.begin(at: CGPoint(x: 200, y: 200))
        // Release essentially where we pressed (a click) → cancel, capture nothing.
        let resolution = model.end(at: CGPoint(x: 201, y: 201))
        XCTAssertEqual(resolution, .cancel)
    }

    func testJustBelowThresholdCancelsJustAboveCaptures() {
        // Just below the click/drag threshold → cancel.
        var below = RegionPickerModel()
        below.begin(at: .zero)
        XCTAssertEqual(below.end(at: CGPoint(x: RegionPickerModel.minDragDistance - 1, y: 0)), .cancel)

        // Just above the threshold → a (tiny) region, not a cancel.
        var above = RegionPickerModel()
        above.begin(at: .zero)
        if case .region = above.end(at: CGPoint(x: RegionPickerModel.minDragDistance + 1, y: 0)) {
            // expected
        } else {
            XCTFail("a drag past the threshold captures a region")
        }
    }

    func testReleaseWithoutBeginIsCancel() {
        var model = RegionPickerModel()
        XCTAssertEqual(model.end(at: CGPoint(x: 10, y: 10)), .cancel, "a release with no drag in progress cancels")
    }

    func testLiveRectTracksDragAndClearsAfterResolve() {
        var model = RegionPickerModel()
        XCTAssertNil(model.liveRect, "no rect before a drag")
        model.begin(at: CGPoint(x: 10, y: 10))
        model.drag(to: CGPoint(x: 40, y: 60))
        XCTAssertEqual(model.liveRect, CGRect(x: 10, y: 10, width: 30, height: 50))
        _ = model.end(at: CGPoint(x: 40, y: 60))
        XCTAssertNil(model.liveRect, "the live rect clears once the pick resolves")
    }

    func testDragIsIgnoredWithoutABegin() {
        var model = RegionPickerModel()
        model.drag(to: CGPoint(x: 99, y: 99))   // no begin → ignored
        XCTAssertNil(model.liveRect)
    }
}
