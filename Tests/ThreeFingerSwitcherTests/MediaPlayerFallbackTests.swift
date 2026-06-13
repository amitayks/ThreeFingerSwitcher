import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure fallback decision (spec media-player: "Observable fallback to libmpv when the
/// default engine cannot decode"): no decode failure → no fallback; AVFoundation failure with libmpv
/// available → offer libmpv; with libmpv absent → report engine-unavailable; the symmetric libmpv→AV case.
final class MediaPlayerFallbackTests: XCTestCase {

    func testNoDecodeFailureMeansNoFallback() {
        let offer = MediaPlayerFallback.offer(decodeFailed: false,
                                              failedEngine: .avFoundation,
                                              availableEngines: [.avFoundation, .libmpv])
        XCTAssertEqual(offer, .noFallback)
    }

    func testAVFoundationFailureOffersLibmpvWhenAvailable() {
        let offer = MediaPlayerFallback.offer(decodeFailed: true,
                                              failedEngine: .avFoundation,
                                              availableEngines: [.avFoundation, .libmpv])
        XCTAssertEqual(offer, .offerEngine(.libmpv))
    }

    func testAVFoundationFailureReportsUnavailableWhenLibmpvMissing() {
        let offer = MediaPlayerFallback.offer(decodeFailed: true,
                                              failedEngine: .avFoundation,
                                              availableEngines: [.avFoundation])
        XCTAssertEqual(offer, .engineUnavailable(.libmpv))
    }

    func testLibmpvFailureOffersAVFoundation() {
        let offer = MediaPlayerFallback.offer(decodeFailed: true,
                                              failedEngine: .libmpv,
                                              availableEngines: [.avFoundation, .libmpv])
        XCTAssertEqual(offer, .offerEngine(.avFoundation))
    }
}
