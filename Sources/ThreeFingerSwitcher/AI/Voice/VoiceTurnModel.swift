import Foundation

/// The PURE voice-turn state machine (`add-voice-computer-use-agent`, design D1): owns the
/// push-to-talk conversation lifecycle — who may speak, when the mic is open, what happens on
/// barge-in — with time as an input and effects as outputs (the `DockHoverModel` idiom). It never
/// touches AVFoundation/Speech/the runtime; `VoiceSessionController` executes its effects through
/// the seams. Every transition below is unit-tested with fake timestamps.
///
/// Lifecycle: `idle → listening (PTT held) → transcribing (released, STT finalizing) → thinking
/// (turn streaming) → speaking (TTS draining) → idle`. Barge-in: a NEW PTT press during
/// thinking/speaking stops speech, cancels the turn (a DISCARD), and opens the mic — a fluent
/// correction. A human trackpad touch during thinking/speaking ABORTS to idle (the trackpad is the
/// kill switch, never a talk trigger). Chunks arriving after a barge-in/abort are dropped on the
/// floor (`turnEpoch` guards staleness).
public struct VoiceTurnModel {

    public enum Phase: Equatable, Sendable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
    }

    /// Inputs. Every event carries `at:` (unused by v1 rules beyond ordering, kept so cadence rules
    /// can land without an API break — the time-as-input idiom).
    public enum Event: Equatable, Sendable {
        /// The push-to-talk trigger went down / up.
        case pttDown
        case pttUp
        /// The transcriber finalized the utterance (after `stopCapture`).
        case transcriptFinal(String)
        /// The transcriber/capture failed.
        case voiceFailed(VoiceError)
        /// A speakable chunk closed (the controller runs `SentenceChunker` over the `.response`
        /// stream). `epoch` stamps which turn produced it — stale chunks are dropped.
        case chunkReady(String, epoch: Int)
        /// The generation stream settled (all tokens delivered). `epoch` as above.
        case turnSettled(epoch: Int)
        /// The generation failed (already translated upstream; the canvas shows it — voice just
        /// returns to idle without speaking a raw error).
        case turnFailed(epoch: Int)
        /// The synthesizer's queue drained.
        case speechDrained
        /// A HUMAN trackpad touch (the abort signal, never a talk trigger).
        case humanTouch
    }

    /// Outputs, executed by the controller in order.
    public enum Effect: Equatable, Sendable {
        case startCapture
        case stopCapture
        /// Cancel capture WITHOUT finalizing (abort paths — no turn is sent).
        case cancelCapture
        /// Send the finalized transcript as the agent turn, tagged with the new epoch.
        case sendTurn(String, epoch: Int)
        case speak(String)
        case stopSpeaking
        /// Cancel the in-flight generation (a discard, never a failure).
        case cancelTurn
        /// Surface a voice failure (bounded, non-blocking card).
        case presentFailure(VoiceError)
    }

    public private(set) var phase: Phase = .idle
    /// The current turn's epoch. Incremented by every `sendTurn`; chunk/settle events from an older
    /// epoch are stale (their turn was barged in / aborted) and are dropped.
    public private(set) var turnEpoch = 0
    /// Whether the current turn's generation has settled (the phase leaves `speaking` only when BOTH
    /// the turn settled AND the speech queue drained).
    private var turnDone = false
    /// Whether any speech has been enqueued for the current turn (a turn with no speakable output
    /// returns to idle on settle without waiting for a drain that will never come).
    private var spokeAnything = false

    public init() {}

    /// Advance the machine. Returns the effects to execute, in order.
    public mutating func handle(_ event: Event, at _: Date) -> [Effect] {
        switch (phase, event) {

        // MARK: idle
        case (.idle, .pttDown):
            phase = .listening
            return [.startCapture]

        // MARK: listening (PTT held, mic open)
        case (.listening, .pttUp):
            phase = .transcribing
            return [.stopCapture]
        case (.listening, .voiceFailed(let error)):
            phase = .idle
            return [.cancelCapture, .presentFailure(error)]
        case (.listening, .humanTouch):
            // Touch while dictating aborts the dictation (no turn is sent).
            phase = .idle
            return [.cancelCapture]

        // MARK: transcribing (finalizing)
        case (.transcribing, .transcriptFinal(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                phase = .idle          // an empty press-and-release is a no-op, not an error
                return []
            }
            turnEpoch += 1
            turnDone = false
            spokeAnything = false
            phase = .thinking
            return [.sendTurn(trimmed, epoch: turnEpoch)]
        case (.transcribing, .voiceFailed(let error)):
            phase = .idle
            return [.presentFailure(error)]
        case (.transcribing, .pttDown):
            // Re-press while finalizing: abandon the finalize and listen again (fluent correction).
            phase = .listening
            return [.cancelCapture, .startCapture]

        // MARK: thinking (generation streaming, nothing spoken yet)
        case (.thinking, .chunkReady(let chunk, let epoch)) where epoch == turnEpoch:
            phase = .speaking
            spokeAnything = true
            return [.speak(chunk)]
        case (.thinking, .turnSettled(let epoch)) where epoch == turnEpoch:
            // Settled with no speakable output (e.g. a pure tool turn) → idle, nothing to drain.
            turnDone = true
            phase = .idle
            return []
        case (.thinking, .turnFailed(let epoch)) where epoch == turnEpoch:
            phase = .idle
            return []
        case (.thinking, .pttDown):
            return bargeIn()
        case (.thinking, .humanTouch):
            return abortTurn()

        // MARK: speaking (TTS draining while/after generation)
        case (.speaking, .chunkReady(let chunk, let epoch)) where epoch == turnEpoch:
            spokeAnything = true
            return [.speak(chunk)]
        case (.speaking, .turnSettled(let epoch)) where epoch == turnEpoch:
            turnDone = true
            return []                  // wait for the drain
        case (.speaking, .turnFailed(let epoch)) where epoch == turnEpoch:
            turnDone = true
            return []                  // whatever was already enqueued finishes speaking
        case (.speaking, .speechDrained):
            if turnDone {
                phase = .idle
            }
            return []                  // drained but the stream is still going → stay speaking
        case (.speaking, .pttDown):
            return bargeIn()
        case (.speaking, .humanTouch):
            return abortTurn()

        // MARK: stale-epoch chunks/settles (a barged-in turn's leftovers) and everything else
        case (_, .chunkReady), (_, .turnSettled), (_, .turnFailed):
            return []                  // dropped on the floor — never spoken (spec: barge-in)
        default:
            return []
        }
    }

    /// Barge-in (design D4): stop output, discard the turn, and LISTEN.
    private mutating func bargeIn() -> [Effect] {
        phase = .listening
        turnDone = false
        return [.stopSpeaking, .cancelTurn, .startCapture]
    }

    /// Human-touch abort: stop output, discard the turn, back to idle (no mic).
    private mutating func abortTurn() -> [Effect] {
        phase = .idle
        turnDone = false
        return [.stopSpeaking, .cancelTurn]
    }
}
