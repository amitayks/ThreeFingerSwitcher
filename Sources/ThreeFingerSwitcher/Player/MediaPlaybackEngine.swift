import Foundation
import QuartzCore

/// Identifies which playback backend drives a file. Used by `AppSettings` (the default engine), the
/// AVFoundation→libmpv fallback decision, and the action menu's "open in <engine>" row. The two
/// conformers shipping in v1 are AVFoundation (default) and libmpv (the alternative); both live OUTSIDE
/// the MLX-free, framework-free Core (in the app target), reached only through `MediaPlaybackEngine`.
public enum PlaybackEngineKind: String, Codable, Equatable, CaseIterable, Sendable {
    case avFoundation
    case libmpv

    public var displayName: String {
        switch self {
        case .avFoundation: return "AVFoundation"
        case .libmpv: return "libmpv"
        }
    }
}

/// One selectable audio or subtitle track an engine exposes. `id` is engine-stable across re-queries
/// (so a persisted selection re-resolves); `label` is the human-facing name shown in the action menu.
public struct MediaTrack: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable { case audio, subtitle }
    public let id: String
    public let kind: Kind
    public let label: String

    public init(id: String, kind: Kind, label: String) {
        self.id = id
        self.kind = kind
        self.label = label
    }
}

/// The observable playback status the surface binds to — a pure value type so the transport model can
/// republish it and tests can assert on it without a real engine. `volume` is normalized 0…1; `rate`
/// is a multiplier (1.0 = normal speed).
public struct PlaybackStatus: Equatable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval
    public var isPlaying: Bool
    public var volume: Double
    public var rate: Double

    public static let zero = PlaybackStatus(position: 0, duration: 0, isPlaying: false, volume: 1.0, rate: 1.0)

    public init(position: TimeInterval = 0, duration: TimeInterval = 0, isPlaying: Bool = false,
                volume: Double = 1.0, rate: Double = 1.0) {
        self.position = position
        self.duration = duration
        self.isPlaying = isPlaying
        self.volume = volume
        self.rate = rate
    }
}

/// The single seam onto a concrete media framework (`media-player` spec: "Playback engine seam with
/// AVFoundation default and libmpv alternative"). The transport model, the surface, and every test
/// depend ONLY on this protocol — never on AVFoundation or libmpv directly — so the playback *logic*
/// verifies against `StubPlaybackEngine` under `swift test` with no media framework linked, exactly the
/// way the AI feature's `LLMRuntime` seam keeps Core MLX-free.
///
/// `load(_:)` is `async throws`: a conformer maps any underlying framework/OS failure into the shared
/// `MediaPlayerError` taxonomy **at this boundary** (so callers only ever see `MediaPlayerError`, never a
/// raw `AVError`/`NSError`/libmpv code), and reports an inability to decode as
/// `MediaPlayerError.unsupportedByDefaultEngine` / `.decodeFailed` — the signal the transport model turns
/// into the libmpv fallback offer. The command methods (`play`/`pause`/`seek`/…) are fire-and-forget.
@MainActor
public protocol MediaPlaybackEngine: AnyObject {
    /// Which backend this engine is (for the action menu + fallback decision).
    var kind: PlaybackEngineKind { get }

    /// Whether this engine can be used at all on this machine. The libmpv engine reports `false` when
    /// its bundled library is missing/unloadable, so the player degrades to a clean message instead of
    /// crashing (`media-player` spec: "libmpv unavailable degrades, never crashes").
    var isAvailable: Bool { get }

    /// The current playback status (position/duration/playing/volume/rate).
    var status: PlaybackStatus { get }

    /// The engine's video/image output layer (AVFoundation's `AVPlayerLayer`, libmpv's render layer), for
    /// the player surface to host. `nil` for audio-only / before load / a stub. A `CALayer` rather than an
    /// `NSView` keeps this seam UIKit/AppKit-free.
    var renderLayer: CALayer? { get }

    /// Invoked by the engine whenever `status` changes (e.g. the periodic time observer ticks), so the
    /// transport model can republish to the bound surface. Set by the transport model.
    var onStatusChange: (() -> Void)? { get set }

    /// The audio / subtitle tracks the loaded media exposes (empty before a successful load, or for an
    /// image). Re-queried after load completes.
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }

    /// Load `url` for playback. Throws a `MediaPlayerError` (mapped at this boundary) on any failure;
    /// a `.unsupportedByDefaultEngine` / `.decodeFailed` throw is the fallback trigger.
    func load(_ url: URL) async throws

    func play()
    func pause()

    /// Seek by a signed offset in seconds (clamped to media bounds by the conformer).
    func seek(by delta: TimeInterval)
    /// Seek to an absolute position in seconds (clamped by the conformer).
    func seek(to position: TimeInterval)

    /// Set the playback rate multiplier (1.0 = normal).
    func setRate(_ rate: Double)
    /// Set the volume, normalized 0…1 (clamped by the conformer).
    func setVolume(_ volume: Double)

    /// Activate the given audio or subtitle track.
    func selectTrack(_ track: MediaTrack)

    /// Stop playback and release resources (called on dismiss).
    func stop()
}
