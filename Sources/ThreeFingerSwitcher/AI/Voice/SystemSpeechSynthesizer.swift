import Foundation
import AVFoundation

/// The real `SpeechSynthesizing` conformer over `AVSpeechSynthesizer` (`add-voice-computer-use-agent`
/// design D2 — macOS 15-safe, no availability gate). Utterances arrive pre-chunked by
/// `SentenceChunker`, are enqueued in order, and `stop()` halts + clears immediately (the barge-in
/// contract). `onAllUtterancesFinished` fires on the main actor when the queue drains. AVFoundation
/// errors never escape raw: this boundary maps them (there is little to map — AVSpeech reports via
/// delegate callbacks, not thrown errors; a dead engine simply never speaks, which the turn model
/// tolerates by design).
@MainActor
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {

    public private(set) var isSpeaking = false
    public var onAllUtterancesFinished: (@MainActor () -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    /// Outstanding utterances (enqueued, not yet finished/cancelled) — drives `isSpeaking` and the
    /// drained callback without trusting AVSpeech's own `isSpeaking` timing.
    private var outstanding = 0

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        // The system default voice; a voice picker is a named follow-up (design: Open Questions).
        outstanding += 1
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    public func stop() {
        outstanding = 0
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func utteranceSettled() {
        guard outstanding > 0 else { return }
        outstanding -= 1
        if outstanding == 0 {
            isSpeaking = false
            onAllUtterancesFinished?()
        }
    }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceSettled() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        // Cancellations arrive from `stop()`, which already zeroed the queue — but a defensive settle
        // keeps the count honest if AVSpeech cancels for its own reasons.
        Task { @MainActor in self.utteranceSettled() }
    }
}
