import Foundation
import QuartzCore

/// A deterministic, scriptable `MediaPlaybackEngine` for tests and `swift build`/`swift test` — the real
/// AVFoundation and libmpv conformers are deferred to the `xcodebuild`-only app target (mirroring how
/// `StubLLMRuntime` stands in for `GemmaMLXRuntime`). It records every command and lets a test script the
/// load outcome (success / unsupported-by-this-engine / damaged / unavailable) and drive status, so the
/// transport state machine — including the libmpv fallback — is exercised without any media framework.
@MainActor
final class StubPlaybackEngine: MediaPlaybackEngine {

    /// How the next `load(_:)` should resolve.
    enum LoadOutcome: Equatable {
        /// Load succeeds; playback can begin.
        case success
        /// This engine cannot decode the container/codec → throws `.unsupportedByDefaultEngine` (the
        /// libmpv fallback trigger).
        case unsupported
        /// Load fails outright (e.g. file removed) → throws `.loadFailed`.
        case loadFailed
        /// Playback failed mid-decode → throws `.decodeFailed`.
        case decodeFailed
    }

    let kind: PlaybackEngineKind
    var isAvailable: Bool
    var status: PlaybackStatus
    var renderLayer: CALayer? { nil }
    var onStatusChange: (() -> Void)?
    var audioTracks: [MediaTrack]
    var subtitleTracks: [MediaTrack]

    /// The outcome the next `load(_:)` produces.
    var nextLoadOutcome: LoadOutcome

    // MARK: Recorded calls (assertion points)
    private(set) var loadedURLs: [URL] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var stopCount = 0
    private(set) var seekDeltas: [TimeInterval] = []
    private(set) var seekPositions: [TimeInterval] = []
    private(set) var setRates: [Double] = []
    private(set) var setVolumes: [Double] = []
    private(set) var selectedTracks: [MediaTrack] = []

    init(kind: PlaybackEngineKind = .avFoundation,
         isAvailable: Bool = true,
         status: PlaybackStatus = .zero,
         audioTracks: [MediaTrack] = [],
         subtitleTracks: [MediaTrack] = [],
         nextLoadOutcome: LoadOutcome = .success) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.status = status
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.nextLoadOutcome = nextLoadOutcome
    }

    func load(_ url: URL) async throws {
        loadedURLs.append(url)
        let name = url.lastPathComponent
        switch nextLoadOutcome {
        case .success:
            status.duration = status.duration > 0 ? status.duration : 100
            status.isPlaying = false
            onStatusChange?()
        case .unsupported:
            throw MediaPlayerError.unsupportedByDefaultEngine(name: name, details: "stub: unsupported")
        case .loadFailed:
            throw MediaPlayerError.loadFailed(name: name, details: "stub: load failed")
        case .decodeFailed:
            throw MediaPlayerError.decodeFailed(name: name, details: "stub: decode failed")
        }
    }

    func play() { playCount += 1; status.isPlaying = true; onStatusChange?() }
    func pause() { pauseCount += 1; status.isPlaying = false; onStatusChange?() }
    func stop() { stopCount += 1; status.isPlaying = false; onStatusChange?() }

    func seek(by delta: TimeInterval) {
        seekDeltas.append(delta)
        status.position = max(0, min(status.duration, status.position + delta))
        onStatusChange?()
    }

    func seek(to position: TimeInterval) {
        seekPositions.append(position)
        status.position = max(0, min(status.duration, position))
        onStatusChange?()
    }

    func setRate(_ rate: Double) { setRates.append(rate); status.rate = rate; onStatusChange?() }
    func setVolume(_ volume: Double) { setVolumes.append(volume); status.volume = volume; onStatusChange?() }
    func selectTrack(_ track: MediaTrack) { selectedTracks.append(track) }
}
