import Foundation

/// The voice feature's error taxonomy (`add-voice-computer-use-agent`, design D11 / spec "Voice errors
/// join the single error taxonomy"). Parallel to `FileActionError`/`DockPreviewError`: a Core
/// `LocalizedError` with clean per-case headlines, populated at the AVFoundation/Speech boundary —
/// raw vendor error text rides ONLY in `copyableDetails`, never a headline. Surfaced bounded +
/// non-blocking (a card, never an `NSAlert`), translated by `AIError.message(for:)`.
public enum VoiceError: Error, Equatable {
    /// Microphone authorization was denied (or restricted). The card offers a System Settings link.
    case micDenied
    /// The on-device speech engine is unavailable (asset missing, analyzer failed to start). Carries
    /// the raw underlying text for the opt-in disclosure.
    case speechUnavailable(detail: String? = nil)
    /// Voice conversation requires macOS 26 (the `SpeechAnalyzer` floor). The feature reads as
    /// unavailable on older systems — never a crash, never a degraded fallback engine.
    case osTooOld
    /// The audio capture session failed to start or died mid-press.
    case captureFailed(detail: String? = nil)
    /// Text-to-speech failed to start or errored mid-utterance.
    case synthesisFailed(detail: String? = nil)

    /// The raw technical text for the opt-in "Show details / Copy" affordance; nil when the headline
    /// already says everything.
    public var copyableDetails: String? {
        switch self {
        case .micDenied, .osTooOld:
            return nil
        case let .speechUnavailable(detail), let .captureFailed(detail), let .synthesisFailed(detail):
            return detail
        }
    }
}

extension VoiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access is off. Allow it in System Settings to talk to the assistant."
        case .speechUnavailable:
            return "Speech recognition isn't available right now."
        case .osTooOld:
            return "Voice conversation requires macOS 26."
        case .captureFailed:
            return "The microphone couldn't start."
        case .synthesisFailed:
            return "Speech playback failed."
        }
    }
}
