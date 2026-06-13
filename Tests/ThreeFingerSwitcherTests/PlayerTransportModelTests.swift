import XCTest
import Combine
@testable import ThreeFingerSwitcherCore

/// Tests for `PlayerTransportModel` (spec media-player) against `StubPlaybackEngine`: seek/volume step +
/// clamp, play/pause toggle, rate, the decode-failure → `.unsupported` → commit-to-libmpv flow, a hard
/// failure surfacing observably as `.failed` (never silent), and dismiss not being a failure.
@MainActor
final class PlayerTransportModelTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/movies/clip.mp4")

    /// Build a model whose factory hands out the provided stubs per engine kind.
    private func makeModel(av: StubPlaybackEngine,
                           libmpv: StubPlaybackEngine? = nil,
                           config: PlayerTransportModel.Config = .default)
    -> PlayerTransportModel {
        var available: Set<PlaybackEngineKind> = [.avFoundation]
        if libmpv != nil { available.insert(.libmpv) }
        return PlayerTransportModel(
            config: config,
            defaultEngine: .avFoundation,
            availableEngines: available,
            makeEngine: { kind in
                switch kind {
                case .avFoundation: return av
                case .libmpv: return libmpv
                }
            })
    }

    func testStartPlaysSupportedVideo() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100, volume: 0.5), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        XCTAssertEqual(model.state, .playing)
        XCTAssertEqual(av.playCount, 1)
        XCTAssertEqual(av.loadedURLs, [url])
    }

    func testSeekStepsByConfiguredStepAndClamps() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        model.seek(1)                    // +10 → 10
        XCTAssertEqual(model.status.position, 10, accuracy: 0.001)
        model.seek(-1); model.seek(-1)   // 0, then clamped at 0
        XCTAssertEqual(model.status.position, 0, accuracy: 0.001)
        XCTAssertEqual(av.seekDeltas, [10, -10, -10])
    }

    func testVolumeStepsAndClampsToUnitRange() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100, volume: 0.98), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        model.adjustVolume(1)            // 0.98 + 0.05 → clamp 1.0
        XCTAssertEqual(model.status.volume, 1.0, accuracy: 0.001)
        for _ in 0..<25 { model.adjustVolume(-1) }   // drive well below 0
        XCTAssertEqual(model.status.volume, 0.0, accuracy: 0.001)
    }

    func testTogglePlayPause() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        XCTAssertEqual(model.state, .playing)
        model.togglePlayPause()
        XCTAssertEqual(model.state, .paused)
        XCTAssertEqual(av.pauseCount, 1)
        model.togglePlayPause()
        XCTAssertEqual(model.state, .playing)
    }

    func testRateChange() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        model.setRate(1.5)
        XCTAssertEqual(av.setRates, [1.5])
    }

    func testUnsupportedOffersLibmpvThenCommitReloads() async {
        let av = StubPlaybackEngine(nextLoadOutcome: .unsupported)
        let libmpv = StubPlaybackEngine(kind: .libmpv, status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av, libmpv: libmpv)

        await model.start(url: url, name: "clip.mkv", kind: .video)
        // Observable, not silent: an .unsupported state offering libmpv.
        guard case let .unsupported(offer, headline, _) = model.state else {
            return XCTFail("expected .unsupported, got \(model.state)")
        }
        XCTAssertEqual(offer, .offerEngine(.libmpv))
        XCTAssertFalse(headline.isEmpty)

        await model.commitFallback()
        XCTAssertEqual(model.state, .playing)
        XCTAssertEqual(model.currentEngineKind, .libmpv)
        XCTAssertEqual(libmpv.loadedURLs, [url])
    }

    func testHardFailureIsObservableNotSilent() async {
        let av = StubPlaybackEngine(nextLoadOutcome: .loadFailed)
        let model = makeModel(av: av)
        await model.start(url: url, name: "gone.mp4", kind: .video)
        guard case let .failed(headline, _) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertFalse(headline.isEmpty, "a failure must carry a clean headline, never a silent state")
    }

    func testDismissIsNotAFailure() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        model.dismiss()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(av.stopCount, 1)
    }

    func testSwitchEngineOnDemandReloads() async {
        let av = StubPlaybackEngine(status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let libmpv = StubPlaybackEngine(kind: .libmpv, status: PlaybackStatus(duration: 100), nextLoadOutcome: .success)
        let model = makeModel(av: av, libmpv: libmpv)
        await model.start(url: url, name: "clip.mp4", kind: .video)
        await model.switchEngine(to: .libmpv)
        XCTAssertEqual(model.currentEngineKind, .libmpv)
        XCTAssertEqual(libmpv.loadedURLs, [url])
    }
}
