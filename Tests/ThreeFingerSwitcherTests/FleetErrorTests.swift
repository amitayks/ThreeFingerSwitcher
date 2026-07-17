import XCTest
@testable import ThreeFingerSwitcherCore

/// `FleetError` taxonomy + the single translator routing (tasks 4.1, 4.2, design D7).
final class FleetErrorTests: XCTestCase {

    func testEachCaseHasCleanNonEmptyDescription() {
        let cannot = FleetError.cannotAdmit(modelName: "Video model", evictedDetails: "chat")
        let cloud = FleetError.cloudDisabled(modelName: "GLM-5.2")
        XCTAssertFalse((cannot.errorDescription ?? "").isEmpty)
        XCTAssertFalse((cloud.errorDescription ?? "").isEmpty)
    }

    /// 4.2 — routes through `AIError.message(for:)`; eviction list rides in details, NOT the headline.
    func testCannotAdmitRoutesThroughTranslatorEvictionInDetails() {
        let err = FleetError.cannotAdmit(modelName: "Video model",
                                         evictedDetails: "Tried to evict: chat")
        let presented = AIError.message(for: err)
        XCTAssertEqual(presented.headline, err.errorDescription)
        // The eviction list must NOT leak into the headline (raw-interpolation ban).
        XCTAssertFalse(presented.headline.contains("Tried to evict"))
        XCTAssertEqual(presented.details, "Tried to evict: chat")
    }

    func testCloudDisabledRoutesThroughTranslator() {
        let err = FleetError.cloudDisabled(modelName: "GLM-5.2")
        let presented = AIError.message(for: err)
        XCTAssertEqual(presented.headline, err.errorDescription)
        XCTAssertNil(presented.details)
        // The headline names the model (a clean known string), not a raw error dump.
        XCTAssertTrue(presented.headline.contains("GLM-5.2"))
    }
}
