import Foundation

/// Output #2 (the pure part) — the canvas media STATE model (design D7, §6.1). The native player overlay
/// (FLAGGED) renders this; the model itself is pure + `swift test`-verified. It advances on
/// `MediaProgress` and terminates on finished / failed / cancelled. The canvas shows live step-progress +
/// the intermediate preview while generating; the finished image, or a player for video, on completion.
///
/// The asset is ALREADY durable in the gallery (output #1) BEFORE the canvas resolves, so a discard never
/// loses the result — it only dismisses the preview. MLX-free Core.
public enum MediaJobState: Equatable, Sendable {
    /// Not started / no job on the canvas.
    case idle
    /// Painting: the latest diffusion step + the optional intermediate preview frame (PNG).
    case generating(index: Int, total: Int, preview: Data?)
    /// Finished: the terminal asset (image or video) ready to extract / play.
    case finished(MediaAsset)
    /// A clean, bounded failure (the headline already routed through `AIError.message(for:)`).
    case failed(headline: String)
    /// The user discarded the in-flight gen. DISTINCT from `.failed` (design D10) — no failed indicator.
    case cancelled

    /// True once the canvas has a terminal outcome (the preview can be resolved / dismissed).
    public var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled: return true
        case .idle, .generating: return false
        }
    }

    /// The finished asset if any (the extract target).
    public var asset: MediaAsset? {
        if case let .finished(asset) = self { return asset }
        return nil
    }

    /// Advance the state on one `MediaProgress`. A `.step` updates the live preview; `.finished` is
    /// terminal. (Failure/cancellation enter via the thrown-error / discard paths, not a progress value.)
    public mutating func advance(_ progress: MediaProgress) {
        switch progress {
        case let .step(index, total, preview):
            self = .generating(index: index, total: total, preview: preview)
        case let .finished(asset):
            self = .finished(asset)
        }
    }

    /// Map a thrown generation error into a clean, bounded `.failed` — UNLESS it is a cancellation, which
    /// is the distinct `.cancelled` outcome (never a failed badge, design D10).
    public mutating func fail(with error: Error) {
        if MediaOutcome.isCancellation(error) {
            self = .cancelled
        } else {
            self = .failed(headline: AIError.message(for: error).headline)
        }
    }
}

// MARK: - Cancellation classification

public enum MediaOutcome {
    /// True iff `error` represents a cancellation (a discarded gen), not a real failure. Used everywhere a
    /// terminal outcome is decided so cancellation stays DISTINCT from failure (design D10): no `.failed`
    /// badge, no failed audit, no false error card.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let runtime = error as? RuntimeError, runtime == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError
    }
}
