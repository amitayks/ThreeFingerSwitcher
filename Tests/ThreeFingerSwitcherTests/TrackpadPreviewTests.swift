import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests the data feeding the Hub's live trackpad preview (change `positional-navigation`): the
/// `TouchFrame.normalizedContactPoints` accessor and the `TrackpadPreviewModel`'s live/neutral handling.
@MainActor
final class TrackpadPreviewTests: XCTestCase {

    func testNormalizedContactPointsFromTestPoints() {
        let pts = [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)]
        let f = TouchFrame(testContactPoints: pts)
        XCTAssertEqual(f.normalizedContactPoints, pts)
    }

    func testNormalizedContactPointsEmptyForCountOnlyFrame() {
        let f = TouchFrame(testFingerCount: 3, centroid: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(f.normalizedContactPoints.isEmpty)   // count-only frame → preview draws no dots
    }

    func testModelGoesLiveOnTouchAndNeutralOnLift() {
        let model = TrackpadPreviewModel()
        XCTAssertFalse(model.live)

        // Two fingers down → live, with centroid / spread / dots.
        model.ingestForTesting(TouchFrame(testContactPoints: [CGPoint(x: 0.4, y: 0.5),
                                                              CGPoint(x: 0.6, y: 0.5)]))
        XCTAssertTrue(model.live)
        XCTAssertEqual(model.centroid?.x ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.spread ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(model.points.count, 2)

        // Lift (empty frame) → neutral resting view, dots cleared, not live.
        model.ingestForTesting(TouchFrame(contacts: [], centroid: .zero, centroidVelocity: .zero, time: 0))
        XCTAssertFalse(model.live)
        XCTAssertNil(model.centroid)
        XCTAssertTrue(model.points.isEmpty)
    }
}
