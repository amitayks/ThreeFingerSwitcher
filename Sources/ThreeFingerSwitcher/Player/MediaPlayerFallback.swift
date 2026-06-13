import Foundation

/// What the player should offer when the default engine cannot decode a file (`media-player` spec:
/// "Observable fallback to libmpv when the default engine cannot decode"). Surfaced as a bounded,
/// non-blocking state — the player NEVER silently fails or transparently swaps engines.
enum FallbackOffer: Equatable {
    /// Offer the user to re-open the file in `engine` (the alternative engine is available).
    case offerEngine(PlaybackEngineKind)
    /// The alternative engine exists in principle but is unavailable on this machine (e.g. libmpv's
    /// library is missing) — so the player reports that rather than offering an action that can't run.
    case engineUnavailable(PlaybackEngineKind)
    /// No alternative engine to offer (nothing the user can do but dismiss).
    case noFallback
}

/// The pure, testable fallback decision: given a decode-failure signal, the engine that just failed, and
/// which engines are available, decide what to offer. Side-effect-free — it picks the *alternative* engine
/// (libmpv when AVFoundation failed, AVFoundation when libmpv failed) and reports whether that alternative
/// is usable. The transport model owns acting on the result.
enum MediaPlayerFallback {
    static func offer(decodeFailed: Bool,
                      failedEngine: PlaybackEngineKind,
                      availableEngines: Set<PlaybackEngineKind>) -> FallbackOffer {
        guard decodeFailed else { return .noFallback }
        let alternative: PlaybackEngineKind = (failedEngine == .avFoundation) ? .libmpv : .avFoundation
        // Don't offer to re-open in the very engine that just failed.
        guard alternative != failedEngine else { return .noFallback }
        return availableEngines.contains(alternative)
            ? .offerEngine(alternative)
            : .engineUnavailable(alternative)
    }
}
