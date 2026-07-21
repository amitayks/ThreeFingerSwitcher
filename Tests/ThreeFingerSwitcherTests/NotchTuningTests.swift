import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the notch chat's tuning dial (`notch-timeline-and-tuning` D6): the four ordered stops'
/// (reasoning, context) semantics — reusing `AgentContextPreset`'s token resolution so a stop and a Hub
/// preset with the same name can never disagree — and the discrete slider ↔ stop mapping.
final class NotchTuningTests: XCTestCase {

    func testStopOrderAndReasoningSemantics() {
        XCTAssertEqual(NotchTuning.allCases, [.quick, .balanced, .deep, .max],
                       "the slider scrubs the stops in this order")
        XCTAssertFalse(NotchTuning.quick.reasoning, "Quick is the one no-thinking stop")
        XCTAssertTrue(NotchTuning.balanced.reasoning)
        XCTAssertTrue(NotchTuning.deep.reasoning)
        XCTAssertTrue(NotchTuning.max.reasoning)
    }

    func testContextTokensFollowThePresetResolutionAndClampToModelMax() {
        XCTAssertEqual(NotchTuning.quick.contextTokens(modelMax: 131_072), 8_192)
        XCTAssertEqual(NotchTuning.balanced.contextTokens(modelMax: 131_072), 8_192)
        XCTAssertEqual(NotchTuning.deep.contextTokens(modelMax: 131_072), 32_768)
        XCTAssertEqual(NotchTuning.max.contextTokens(modelMax: 131_072), 131_072,
                       "Max resolves to the model's architectural maximum")
        XCTAssertEqual(NotchTuning.deep.contextTokens(modelMax: 16_000), 16_000,
                       "every stop clamps to the model max")
    }

    func testSliderIndexRoundTripsAndClamps() {
        for (index, stop) in NotchTuning.allCases.enumerated() {
            XCTAssertEqual(stop.sliderIndex, index)
            XCTAssertEqual(NotchTuning.fromSliderIndex(index), stop)
        }
        XCTAssertEqual(NotchTuning.fromSliderIndex(-1), .quick, "below-range clamps to the first stop")
        XCTAssertEqual(NotchTuning.fromSliderIndex(99), .max, "above-range clamps to the last stop")
    }
}
