import Foundation
import Combine

/// The pure transport state machine the player surface binds to (`media-player` spec: the transport
/// grammar + the observable libmpv fallback). It maps the recognizer's navigation intents (seek / volume
/// / toggle / track-select / dismiss) into commands on an injected `MediaPlaybackEngine`, and owns the
/// observable surface `state`. Modeled on `AICommandExecutor` / `FileOpenService`: `@MainActor` +
/// `ObservableObject`, holding the `@Published state` the view reflects, so a failure is **observable,
/// never a silent false success** — a load that can't decode becomes `.unsupported` (offering libmpv), a
/// real failure becomes `.failed`, and dismissing is never a failure.
///
/// It drives the engine ONLY through the `MediaPlaybackEngine` seam and swaps engines via an injected
/// factory, so it verifies entirely against `StubPlaybackEngine` under `swift test` with no media
/// framework linked.
@MainActor
final class PlayerTransportModel: ObservableObject {

    /// Feel tunables (sourced from `AppSettings`, injected so the model stays pure/testable).
    struct Config: Equatable {
        /// Seconds per seek step (one out-and-back; auto-repeat issues more while held).
        var seekStep: TimeInterval
        /// Volume delta per step, in 0…1 units.
        var volumeStep: Double
        /// Resume only when the saved position is at least this many seconds in.
        var resumeThreshold: TimeInterval
        /// Treat a saved position within this many seconds of the end as "finished" → start fresh.
        var nearEndMargin: TimeInterval
        static let `default` = Config(seekStep: 10, volumeStep: 0.05, resumeThreshold: 5, nearEndMargin: 10)
    }

    /// The observable surface state. `.unsupported` carries the fallback offer so the surface can render
    /// the "open in libmpv" affordance; `.failed` carries a clean headline + opt-in copyable details.
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case unsupported(offer: FallbackOffer, headline: String, details: String?)
        case failed(headline: String, details: String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status: PlaybackStatus = .zero

    /// The engine currently driving playback (swapped on a fallback / "open in libmpv").
    private(set) var currentEngine: MediaPlaybackEngine?
    /// Which backend `currentEngine` is.
    private(set) var currentEngineKind: PlaybackEngineKind

    /// The selected track ids, tracked so the controller can persist them for resume.
    private(set) var currentAudioTrackID: String?
    private(set) var currentSubtitleTrackID: String?

    private let config: Config
    /// Builds an engine for a backend, or nil if that backend is unavailable on this machine.
    private let makeEngine: (PlaybackEngineKind) -> MediaPlaybackEngine?
    /// Which backends exist and are usable (for the fallback decision + action menu).
    let availableEngines: Set<PlaybackEngineKind>

    // The current media, retained so an engine swap can reload the same file at the same spot.
    private var currentURL: URL?
    private var currentName: String = ""
    private var currentKind: MediaKind = .video

    init(config: Config = .default,
         defaultEngine: PlaybackEngineKind = .avFoundation,
         availableEngines: Set<PlaybackEngineKind>,
         makeEngine: @escaping (PlaybackEngineKind) -> MediaPlaybackEngine?) {
        self.config = config
        self.currentEngineKind = defaultEngine
        self.availableEngines = availableEngines
        self.makeEngine = makeEngine
    }

    // MARK: - Lifecycle

    /// Start playing `url`, resuming at `resumeAt` if given. On a decode failure transitions to
    /// `.unsupported` (offering libmpv); on any other failure transitions to `.failed`.
    func start(url: URL, name: String, kind: MediaKind, resumeAt: TimeInterval = 0) async {
        currentURL = url
        currentName = name
        currentKind = kind
        await load(on: currentEngineKind, resumeAt: resumeAt)
    }

    /// Commit the libmpv fallback offer: reload the current file in the offered engine.
    func commitFallback() async {
        guard case let .unsupported(offer, _, _) = state, case let .offerEngine(engine) = offer else { return }
        await load(on: engine, resumeAt: status.position)
    }

    /// Switch engines on demand (the action menu's "open in <engine>"): reload at the current position.
    func switchEngine(to engine: PlaybackEngineKind) async {
        guard engine != currentEngineKind else { return }
        await load(on: engine, resumeAt: status.position)
    }

    /// The shared load path: build/attach the engine, load, and resolve into a state.
    private func load(on engineKind: PlaybackEngineKind, resumeAt: TimeInterval) async {
        guard let url = currentURL else { return }
        guard let engine = makeEngine(engineKind), engine.isAvailable else {
            state = .failed(headline: MediaPlayerError.engineUnavailable(engine: engineKind).errorDescription ?? "",
                            details: nil)
            return
        }
        attach(engine, kind: engineKind)
        state = .loading
        do {
            try await engine.load(url)
            if resumeAt > 0 { engine.seek(to: resumeAt) }
            // Images have no playback; video/audio begin playing.
            if currentKind == .image {
                state = .paused
            } else {
                engine.play()
                state = .playing
            }
            status = engine.status
        } catch {
            resolveLoadError(error)
        }
    }

    /// Map a load failure into observable state. A decode/unsupported failure offers the fallback; a hard
    /// failure (missing file, engine unavailable) is `.failed`. Errors arrive already mapped into
    /// `MediaPlayerError` at the engine boundary, so Core never inspects a framework error type.
    private func resolveLoadError(_ error: Error) {
        guard let mediaError = error as? MediaPlayerError else {
            state = .failed(headline: MediaPlayerError.loadFailed(name: currentName, details: nil).errorDescription ?? "",
                            details: nil)
            return
        }
        switch mediaError {
        case .unsupportedByDefaultEngine, .decodeFailed:
            let offer = MediaPlayerFallback.offer(decodeFailed: true,
                                                  failedEngine: currentEngineKind,
                                                  availableEngines: availableEngines)
            if case .noFallback = offer {
                state = .failed(headline: mediaError.errorDescription ?? "", details: mediaError.copyableDetails)
            } else {
                state = .unsupported(offer: offer,
                                     headline: mediaError.errorDescription ?? "",
                                     details: mediaError.copyableDetails)
            }
        case .loadFailed, .engineUnavailable:
            state = .failed(headline: mediaError.errorDescription ?? "", details: mediaError.copyableDetails)
        }
    }

    /// Attach an engine: stop any prior one, wire status republish, reset tracked selections.
    private func attach(_ engine: MediaPlaybackEngine, kind: PlaybackEngineKind) {
        currentEngine?.onStatusChange = nil
        currentEngine?.stop()
        currentEngine = engine
        currentEngineKind = kind
        currentAudioTrackID = nil
        currentSubtitleTrackID = nil
        engine.onStatusChange = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.status = engine.status
        }
    }

    // MARK: - Transport intents (from the recognizer)

    /// Seek one step in `dir` (−1 / +1). The recognizer's held-in-zone signal drives repeated calls.
    func seek(_ dir: Int) {
        guard isPlayable else { return }
        currentEngine?.seek(by: TimeInterval(dir) * config.seekStep)
    }

    /// Adjust volume one step in `dir` (−1 / +1), clamped to 0…1.
    func adjustVolume(_ dir: Int) {
        guard let engine = currentEngine, isPlayable else { return }
        let next = min(1.0, max(0.0, status.volume + Double(dir) * config.volumeStep))
        engine.setVolume(next)
    }

    /// Toggle play/pause (the two-finger tap). No-op outside a playing/paused state.
    func togglePlayPause() {
        guard let engine = currentEngine else { return }
        switch state {
        case .playing:
            engine.pause()
            state = .paused
        case .paused:
            engine.play()
            state = .playing
        default:
            break
        }
    }

    func setRate(_ rate: Double) {
        guard isPlayable else { return }
        currentEngine?.setRate(rate)
    }

    /// Apply an action-menu row.
    func apply(_ action: PlayerActionMenuItem.Action) {
        switch action {
        case let .selectAudioTrack(track):
            currentEngine?.selectTrack(track); currentAudioTrackID = track.id
        case let .selectSubtitleTrack(track):
            currentEngine?.selectTrack(track); currentSubtitleTrackID = track.id
        case .subtitlesOff:
            currentSubtitleTrackID = nil
        case let .setRate(rate):
            setRate(rate)
        case let .openInEngine(engine):
            Task { await switchEngine(to: engine) }
        case .toggleLoop, .selectChapter:
            break   // loop/chapters applied by the controller against the engine where supported
        }
    }

    // MARK: - Dismiss

    /// Tear down playback (a four-finger dismiss). Stops the engine and rests at `.idle`. NOT a failure —
    /// no `.failed` state is recorded (`media-player` spec: "Dismiss is not a failure").
    func dismiss() {
        currentEngine?.onStatusChange = nil
        currentEngine?.stop()
        currentEngine = nil
        state = .idle
    }

    /// Whether transport intents should act (we have a playing/paused engine).
    private var isPlayable: Bool {
        switch state {
        case .playing, .paused: return true
        default: return false
        }
    }
}
