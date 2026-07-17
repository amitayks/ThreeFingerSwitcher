import Foundation

/// The media-specific error taxonomy (design D10, addendum §1 "new error enums") — a clean
/// `LocalizedError` for ONLY the cases the shared `RuntimeError`/`TaskError`/`FleetError` cannot carry.
/// Vendor/OS errors (mflux/LTXV/ComfyUI, `Process`, `NSURLError`, `FileManager`) are mapped INTO this
/// taxonomy at the layer boundary (the sink / backend conformer, §8.2) BEFORE they reach a UI surface, so
/// feature/UI code never sees a raw vendor type. Every surface routes through `AIError.message(for:)` →
/// `AIPresentedError` (THE single translator), bounded + non-blocking — never an `NSAlert`, never raw
/// error text in a headline.
///
/// Per-case `errorDescription`s are clean, user-facing sentences. Raw vendor/OS detail rides ONLY in the
/// opt-in `copyableDetails` (and logs), never the headline. **Cancellation is NOT a `MediaError`** — a
/// discarded/parked-then-discarded gen ends `.cancelled` (mapped to `RuntimeError.cancelled` /
/// `CancellationError`), never a `.failed` badge. MLX-free Core.
public enum MediaError: Error, Equatable {
    /// No runtime advertises the requested kind (e.g. a video gen with no video provider configured).
    case noCapableBackend(kind: MediaKind)
    /// A tool authored as img2img / img2video ran with no resolvable seed image — never a fabricated
    /// blank first frame (design D5).
    case seedRequired
    /// The supplied seed image could not be decoded to PNG (an undecodable capture).
    case seedInvalid
    /// The backend reported a generation failure. Carries a CLEAN headline already (the boundary mapped
    /// the vendor error → a clean string); raw text rode into `copyableDetails`/logs at the boundary.
    case generationFailed(headline: String)
    /// The finished asset could not be written to the gallery (`FileManager` failure). The raw OS reason
    /// rides in `detail` (copyable), never the headline.
    case outputWriteFailed(detail: String? = nil)
    /// The cloud-video per-day budget is exhausted — refused BEFORE any network call / spend (design D3).
    case cloudBudgetExhausted
    /// A cloud video provider is unreachable / not configured (distinct from budget-exhausted).
    case cloudUnavailable
    /// The selected video provider is DISABLED by a gate (e.g. local LTXV selected with the master toggle
    /// off, or no provider configured) — a clean decline, NO compute, NO spend
    /// (`ai-video-animation-generation`, task 8.1). Distinct from `.cloudUnavailable` (reachable-but-down)
    /// and `.noCapableBackend` (no runtime advertises the kind).
    case videoProviderDisabled
}

extension MediaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .noCapableBackend(kind):
            switch kind {
            case .image: return "No image generator is available."
            case .video: return "No video generator is available."
            }
        case .seedRequired:
            return "This needs a source image. Capture a screen region or copy an image first."
        case .seedInvalid:
            return "That image couldn't be read as a source frame."
        case let .generationFailed(headline):
            // The headline is already clean (mapped at the boundary); surface it as-is.
            return headline
        case .outputWriteFailed:
            return "The generated file couldn't be saved."
        case .cloudBudgetExhausted:
            return "Today's video budget is used up. It resets tomorrow."
        case .cloudUnavailable:
            return "The video service isn't reachable right now."
        case .videoProviderDisabled:
            return "Video generation isn't turned on."
        }
    }

    /// The opt-in copyable detail (the raw OS reason), for a "Show details / Copy" disclosure and logs
    /// only — never the headline. `nil` when the headline already says everything.
    public var copyableDetails: String? {
        switch self {
        case let .outputWriteFailed(detail):
            return detail
        case .noCapableBackend, .seedRequired, .seedInvalid, .generationFailed,
             .cloudBudgetExhausted, .cloudUnavailable, .videoProviderDisabled:
            return nil
        }
    }
}
