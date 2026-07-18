import Foundation

/// The two voice seams (`add-voice-computer-use-agent`, design D2): Core declares the protocols and
/// ships scripted stubs so the ENTIRE voice lifecycle verifies under `swift test`; the real conformers
/// (`SpeechAnalyzerTranscriber` @available(macOS 26), `SystemSpeechSynthesizer` over
/// `AVSpeechSynthesizer`) are injected at composition via `VoiceRuntimeInjection`. Mirrors the
/// `LLMRuntime`/`StubLLMRuntime` and `MemoryPressureObserving`/fake idiom.

/// One transcription update: partials stream while the user speaks; exactly one `isFinal` chunk
/// arrives after `stop()` (the finalized utterance the turn is built from).
public struct TranscriptChunk: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    public init(_ text: String, isFinal: Bool = false) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Speech-to-text over a push-to-talk window: `start()` opens capture and streams chunks; `stop()`
/// closes capture and finalizes (the stream emits its final chunk, then finishes). `cancel()` tears
/// down without a final (barge-in of one's own dictation / error paths). Failures throw/finish with
/// vendor errors mapped to `VoiceError` AT THE CONFORMER BOUNDARY — Core sees only the taxonomy.
@MainActor
public protocol SpeechTranscribing: AnyObject {
    func start() throws -> AsyncThrowingStream<TranscriptChunk, Error>
    func stop()
    func cancel()
}

/// Text-to-speech with utterance queueing: `speak` enqueues a chunk (sentence-chunked upstream);
/// `stop()` halts and clears the queue immediately (barge-in). `onAllUtterancesFinished` fires on the
/// main actor when the queue drains (the voice turn returns to idle only after BOTH the generation
/// settles and the speech drains).
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String)
    func stop()
    var isSpeaking: Bool { get }
    var onAllUtterancesFinished: (@MainActor () -> Void)? { get set }
}

// MARK: - Stubs (Core tests + the MLX-free dev build)

/// Scripted transcriber: `start()` streams the scripted partials, `stop()` emits the scripted final.
/// Cancellation-aware so barge-in paths are testable.
@MainActor
public final class StubTranscriber: SpeechTranscribing {
    public private(set) var isCapturing = false
    /// The partial chunks streamed while "listening".
    public var scriptedPartials: [String]
    /// The final transcript emitted on `stop()`.
    public var scriptedFinal: String
    /// When set, `start()` throws it (permission/engine failure paths).
    public var startError: VoiceError?

    private var continuation: AsyncThrowingStream<TranscriptChunk, Error>.Continuation?

    public init(partials: [String] = [], final: String = "") {
        self.scriptedPartials = partials
        self.scriptedFinal = final
    }

    public func start() throws -> AsyncThrowingStream<TranscriptChunk, Error> {
        if let startError { throw startError }
        isCapturing = true
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            for partial in self.scriptedPartials {
                continuation.yield(TranscriptChunk(partial))
            }
        }
    }

    public func stop() {
        guard isCapturing else { return }
        isCapturing = false
        continuation?.yield(TranscriptChunk(scriptedFinal, isFinal: true))
        continuation?.finish()
        continuation = nil
    }

    public func cancel() {
        isCapturing = false
        continuation?.finish()
        continuation = nil
    }
}

/// Recording synthesizer: captures every spoken chunk in order; tests drive completion explicitly
/// via `finishAll()` so drain timing is deterministic.
@MainActor
public final class StubSynthesizer: SpeechSynthesizing {
    public private(set) var spoken: [String] = []
    public private(set) var stopCount = 0
    public private(set) var isSpeaking = false
    public var onAllUtterancesFinished: (@MainActor () -> Void)?

    public init() {}

    public func speak(_ text: String) {
        spoken.append(text)
        isSpeaking = true
    }

    public func stop() {
        stopCount += 1
        isSpeaking = false
    }

    /// Simulate the queue draining (all enqueued utterances finished playing).
    public func finishAll() {
        guard isSpeaking else { return }
        isSpeaking = false
        onAllUtterancesFinished?()
    }
}
