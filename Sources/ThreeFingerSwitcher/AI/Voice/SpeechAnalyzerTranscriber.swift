import Foundation
import AVFoundation
import Speech

/// The real `SpeechTranscribing` conformer (`add-voice-computer-use-agent`, design D2): Apple's
/// on-device `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) fed by an `AVAudioEngine` input tap
/// with voice-processing I/O enabled (system echo cancellation — the physical precondition for
/// barge-in). Entirely `@available(macOS 26)`: on older systems `VoiceRuntimeInjection` resolves nil
/// and the controller surfaces `VoiceError.osTooOld` (the platform floor does not rise).
///
/// Push-to-talk shape: `start()` opens the engine + analyzer; `stop()` (PTT release) finalizes the
/// analysis (`finalizeAndFinishThroughEndOfInput`) and the accumulated transcript arrives as the one
/// `isFinal` chunk; `cancel()` tears down without a final. The non-progressive `.transcription`
/// preset is deliberate: v1 consumes only the final utterance (no live captions), which sidesteps
/// volatile-result bookkeeping entirely.
///
/// Boundary rule: Speech/AVFoundation errors are mapped to `VoiceError` HERE (raw text only in
/// `details`) — Core never sees vendor error types.
@available(macOS 26.0, *)
@MainActor
public final class SpeechAnalyzerTranscriber: SpeechTranscribing {

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var stopped = false
    /// Process-wide "speech assets verified present" flag (`fix-ptt-chord-collision`).
    private static var assetsEnsured = false

    public init() {}

    public func start() throws -> AsyncThrowingStream<TranscriptChunk, Error> {
        stopped = false
        let engine = AVAudioEngine()
        self.engine = engine

        // System AEC so the mic doesn't hear our own TTS. Best-effort: an engine that can't do
        // voice processing still transcribes (barge-in-by-press works regardless).
        try? engine.inputNode.setVoiceProcessingEnabled(true)

        let module = SpeechTranscriber(locale: .current, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.module = module
        self.analyzer = analyzer

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = inputBuilder

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // Language assets are system-managed: install on demand (a one-time, small,
                    // OS-owned download — NOT one of our model downloads). Checked ONCE per process
                    // (`fix-ptt-chord-collision`): a legit PTT press shouldn't pay an XPC round-trip
                    // to re-verify assets that were present seconds ago.
                    if !Self.assetsEnsured {
                        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                            try await request.downloadAndInstall()
                        }
                        Self.assetsEnsured = true
                    }
                    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [module]) else {
                        throw VoiceError.speechUnavailable(detail: "no compatible audio format")
                    }

                    // Tap the mic and convert each buffer to the analyzer's preferred format on the
                    // audio thread (the converter + continuation are the only captured state).
                    let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                    guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else {
                        throw VoiceError.captureFailed(detail: "no converter \(inputFormat)→\(analyzerFormat)")
                    }
                    let builder = inputBuilder
                    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                        let ratio = analyzerFormat.sampleRate / inputFormat.sampleRate
                        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
                        guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                                               frameCapacity: max(capacity, 1)) else { return }
                        var conversionError: NSError?
                        var served = false
                        converter.convert(to: converted, error: &conversionError) { _, status in
                            if served {
                                status.pointee = .noDataNow
                                return nil
                            }
                            served = true
                            status.pointee = .haveData
                            return buffer
                        }
                        guard conversionError == nil, converted.frameLength > 0 else { return }
                        builder.yield(AnalyzerInput(buffer: converted))
                    }

                    try engine.start()
                    try await analyzer.start(inputSequence: inputSequence)

                    // Non-progressive preset: results arrive finalized; the sequence ends after
                    // `finalizeAndFinishThroughEndOfInput()` (driven by `stop()`). Concatenate every
                    // result's text into the one final transcript.
                    var transcript = ""
                    for try await result in module.results {
                        let piece = String(result.text.characters)
                        guard !piece.isEmpty else { continue }
                        transcript = transcript.isEmpty ? piece : transcript + " " + piece
                    }
                    continuation.yield(TranscriptChunk(transcript, isFinal: true))
                    continuation.finish()
                } catch let error as VoiceError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    // The boundary map: any Speech/AVFoundation failure crosses as taxonomy + details.
                    continuation.finish(throwing: VoiceError.speechUnavailable(
                        detail: String(describing: error)))
                }
                self.teardownEngine()
            }
            self.analysisTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        teardownEngine()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        Task { @MainActor in
            // Finalize through end of input → the results sequence drains its final result and ends.
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
    }

    public func cancel() {
        stopped = true
        teardownEngine()
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel()
        analysisTask = nil
        let analyzer = self.analyzer
        Task { @MainActor in
            await analyzer?.cancelAndFinishNow()
        }
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}

/// The lazy mic authorizer the controller injects (`add-voice-computer-use-agent` D11): requested on
/// the FIRST actual push-to-talk press, never at enable time. macOS 15-safe.
@MainActor
public enum MicrophoneAuthorizer {
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
