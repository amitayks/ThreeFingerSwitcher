import Foundation

/// Executes the pure `VoiceTurnModel`'s effects through the seams (`add-voice-computer-use-agent`,
/// design D1/D2): mic authorization → transcriber lifecycle → the agent turn (a token stream) →
/// `SentenceChunker` → synthesizer, with barge-in and human-touch abort. `@MainActor` like every
/// observable controller in the app. The turn itself is a closure seam (`turnStarter`) so the
/// coordinator binds it to the real engine and tests bind a scripted stream — the controller knows
/// nothing about engines or runtimes.
@MainActor
public final class VoiceSessionController: ObservableObject {

    /// The UI-visible lifecycle phase (mic pill, thinking shimmer, speaking indicator).
    @Published public private(set) var phase: VoiceTurnModel.Phase = .idle
    /// The last voice failure, translated — a bounded, non-blocking card; nil when dismissed.
    @Published public private(set) var lastFailure: AIPresentedError?

    /// Resolves the transcriber, nil when unavailable on this OS (`VoiceError.osTooOld` path).
    private let transcriberFactory: @MainActor () -> SpeechTranscribing?
    private let synthesizer: SpeechSynthesizing
    /// Requests (or returns cached) mic authorization. Injected: real = AVCaptureDevice, tests = pure.
    private let micAuthorizer: @MainActor () async -> Bool
    /// Starts the agent turn for a finalized transcript and streams its tokens.
    private let turnStarter: @MainActor (String) -> AsyncThrowingStream<Token, Error>
    /// Injected clock (the model takes time as an input).
    private let now: @MainActor () -> Date

    private var model = VoiceTurnModel()
    private var transcriber: SpeechTranscribing?
    private var captureTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var chunker = SentenceChunker()

    /// Whether a voice conversation is live RIGHT NOW — the voice feature's contribution to
    /// `QuiescenceSnapshot.foregroundSessionActive` (spec: "A voice session is a foreground
    /// conversational surface").
    public var isConversationActive: Bool { phase != .idle }

    public init(transcriberFactory: @escaping @MainActor () -> SpeechTranscribing?,
                synthesizer: SpeechSynthesizing,
                micAuthorizer: @escaping @MainActor () async -> Bool,
                turnStarter: @escaping @MainActor (String) -> AsyncThrowingStream<Token, Error>,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.transcriberFactory = transcriberFactory
        self.synthesizer = synthesizer
        self.micAuthorizer = micAuthorizer
        self.turnStarter = turnStarter
        self.now = now
        synthesizer.onAllUtterancesFinished = { [weak self] in
            self?.feed(.speechDrained)
        }
    }

    // MARK: - Inputs (the PTT trigger + the abort signal)

    public func pttDown() { feed(.pttDown) }
    public func pttUp() { feed(.pttUp) }
    /// A HUMAN trackpad touch while the agent is thinking/speaking — the kill switch.
    public func humanTouch() { feed(.humanTouch) }
    public func dismissFailure() { lastFailure = nil }

    // MARK: - The model loop

    private func feed(_ event: VoiceTurnModel.Event) {
        let effects = model.handle(event, at: now())
        phase = model.phase
        for effect in effects { execute(effect) }
    }

    private func execute(_ effect: VoiceTurnModel.Effect) {
        switch effect {
        case .startCapture:
            startCapture()
        case .stopCapture:
            transcriber?.stop()
        case .cancelCapture:
            captureTask?.cancel()
            captureTask = nil
            transcriber?.cancel()
            transcriber = nil
        case let .sendTurn(text, epoch):
            startTurn(text, epoch: epoch)
        case let .speak(chunk):
            synthesizer.speak(chunk)
        case .stopSpeaking:
            synthesizer.stop()
        case .cancelTurn:
            turnTask?.cancel()
            turnTask = nil
        case let .presentFailure(error):
            lastFailure = AIError.message(for: error)
        }
    }

    // MARK: - Capture

    private func startCapture() {
        guard let transcriber = transcriberFactory() else {
            feed(.voiceFailed(.osTooOld))
            return
        }
        self.transcriber = transcriber
        captureTask?.cancel()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Lazy mic authorization on the FIRST actual press (spec: never at enable time).
            guard await self.micAuthorizer() else {
                self.feed(.voiceFailed(.micDenied))
                return
            }
            do {
                let stream = try transcriber.start()
                var finalText = ""
                for try await chunk in stream {
                    if chunk.isFinal { finalText = chunk.text }
                    // Partials could drive a live caption; v1 keeps only the final.
                }
                guard !Task.isCancelled else { return }
                self.feed(.transcriptFinal(finalText))
            } catch let error as VoiceError {
                guard !Task.isCancelled else { return }
                self.feed(.voiceFailed(error))
            } catch is CancellationError {
                // Aborted capture: the model already left listening; nothing to report.
            } catch {
                guard !Task.isCancelled else { return }
                // Boundary rule: an unmapped vendor error crosses as a taxonomy case with raw text
                // only in details.
                self.feed(.voiceFailed(.captureFailed(detail: String(describing: error))))
            }
        }
    }

    // MARK: - The turn

    private func startTurn(_ text: String, epoch: Int) {
        chunker = SentenceChunker()
        turnTask?.cancel()
        turnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let stream = self.turnStarter(text)
                for try await token in stream {
                    try Task.checkCancellation()
                    // Thinking is NEVER spoken (spec); only the response channel feeds the chunker.
                    guard token.channel == .response else { continue }
                    for chunk in self.chunker.consume(token.text) {
                        self.feed(.chunkReady(chunk, epoch: epoch))
                    }
                }
                try Task.checkCancellation()
                if let rest = self.chunker.flush() {
                    self.feed(.chunkReady(rest, epoch: epoch))
                }
                self.feed(.turnSettled(epoch: epoch))
            } catch is CancellationError {
                // Barge-in / abort: a discard — the model already transitioned; late chunks from this
                // epoch are dropped by the epoch guard even if any were in flight.
            } catch {
                guard !Task.isCancelled else { return }
                // The canvas surface owns showing the translated failure; voice returns to idle
                // without speaking an error at the user.
                self.feed(.turnFailed(epoch: epoch))
            }
        }
    }
}
