import XCTest
@testable import ThreeFingerSwitcherCore

/// `add-voice-computer-use-agent`: the pure voice-turn lifecycle (spec "Barge-in stops speech and
/// cancels the turn as a discard" — "The voice turn lifecycle is pure and tested"), the sentence
/// chunker, and the audio-seam refusal contract.
@MainActor
final class VoiceTurnModelTests: XCTestCase {

    private let t = Date(timeIntervalSinceReferenceDate: 500_000)
    private var model = VoiceTurnModel()

    private func feed(_ e: VoiceTurnModel.Event) -> [VoiceTurnModel.Effect] {
        model.handle(e, at: t)
    }

    // MARK: - The happy path

    func testFullHappyLifecycle() {
        XCTAssertEqual(feed(.pttDown), [.startCapture])
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(feed(.pttUp), [.stopCapture])
        XCTAssertEqual(model.phase, .transcribing)
        XCTAssertEqual(feed(.transcriptFinal("read that window")),
                       [.sendTurn("read that window", epoch: 1)])
        XCTAssertEqual(model.phase, .thinking)
        XCTAssertEqual(feed(.chunkReady("Here it is.", epoch: 1)), [.speak("Here it is.")])
        XCTAssertEqual(model.phase, .speaking)
        XCTAssertEqual(feed(.chunkReady("Second sentence.", epoch: 1)), [.speak("Second sentence.")])
        XCTAssertEqual(feed(.turnSettled(epoch: 1)), [])
        XCTAssertEqual(model.phase, .speaking, "still draining")
        XCTAssertEqual(feed(.speechDrained), [])
        XCTAssertEqual(model.phase, .idle, "settled + drained → idle")
    }

    func testEmptyTranscriptIsANoOp() {
        _ = feed(.pttDown); _ = feed(.pttUp)
        XCTAssertEqual(feed(.transcriptFinal("   ")), [])
        XCTAssertEqual(model.phase, .idle)
    }

    func testSettleWithNoSpokenOutputGoesStraightIdle() {
        _ = feed(.pttDown); _ = feed(.pttUp); _ = feed(.transcriptFinal("do it"))
        XCTAssertEqual(feed(.turnSettled(epoch: 1)), [])
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - Barge-in (spec scenario: barge-in mid-reply)

    func testBargeInWhileSpeakingStopsCancelsAndListens() {
        _ = feed(.pttDown); _ = feed(.pttUp); _ = feed(.transcriptFinal("hi"))
        _ = feed(.chunkReady("Hello there.", epoch: 1))
        XCTAssertEqual(model.phase, .speaking)
        XCTAssertEqual(feed(.pttDown), [.stopSpeaking, .cancelTurn, .startCapture])
        XCTAssertEqual(model.phase, .listening)
        // Late chunks from the barged-in turn are DROPPED, never spoken.
        XCTAssertEqual(feed(.chunkReady("late token", epoch: 1)), [])
        XCTAssertEqual(feed(.turnSettled(epoch: 1)), [])
        XCTAssertEqual(model.phase, .listening)
        // The corrected turn gets a NEW epoch.
        _ = feed(.pttUp)
        XCTAssertEqual(feed(.transcriptFinal("actually, summarize it")),
                       [.sendTurn("actually, summarize it", epoch: 2)])
    }

    func testBargeInWhileThinking() {
        _ = feed(.pttDown); _ = feed(.pttUp); _ = feed(.transcriptFinal("hi"))
        XCTAssertEqual(model.phase, .thinking)
        XCTAssertEqual(feed(.pttDown), [.stopSpeaking, .cancelTurn, .startCapture])
        XCTAssertEqual(model.phase, .listening)
    }

    // MARK: - Human touch = abort, never talk

    func testHumanTouchAbortsSpeakingToIdle() {
        _ = feed(.pttDown); _ = feed(.pttUp); _ = feed(.transcriptFinal("hi"))
        _ = feed(.chunkReady("Hello.", epoch: 1))
        XCTAssertEqual(feed(.humanTouch), [.stopSpeaking, .cancelTurn])
        XCTAssertEqual(model.phase, .idle, "touch aborts; it does not open the mic")
    }

    func testHumanTouchWhileListeningCancelsDictation() {
        _ = feed(.pttDown)
        XCTAssertEqual(feed(.humanTouch), [.cancelCapture])
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - Failures are clean

    func testCaptureFailurePresentsAndReturnsIdle() {
        _ = feed(.pttDown)
        XCTAssertEqual(feed(.voiceFailed(.micDenied)),
                       [.cancelCapture, .presentFailure(.micDenied)])
        XCTAssertEqual(model.phase, .idle)
    }

    func testTurnFailureReturnsIdleWithoutSpeaking() {
        _ = feed(.pttDown); _ = feed(.pttUp); _ = feed(.transcriptFinal("hi"))
        XCTAssertEqual(feed(.turnFailed(epoch: 1)), [])
        XCTAssertEqual(model.phase, .idle)
    }
}

// MARK: - SentenceChunker

final class SentenceChunkerTests: XCTestCase {

    func testFirstSentenceClosesEarly() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("Here is the answer. The rest"), ["Here is the answer."])
        XCTAssertEqual(chunker.consume(" continues!"), [])
        XCTAssertEqual(chunker.consume(" And more."), ["The rest continues!"])
        XCTAssertEqual(chunker.flush(), "And more.")
    }

    func testParagraphBreakCloses() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.consume("First paragraph\n\nsecond"), ["First paragraph"])
        XCTAssertEqual(chunker.flush(), "second")
    }

    func testCodeFenceIsSummarizedNeverRead() {
        var chunker = SentenceChunker()
        let chunks = chunker.consume("Look:\n```swift\nlet a = 1\nlet b = 2\n```\nDone now.")
        XCTAssertEqual(chunks, ["Look:", "Code block, 2 lines."])
        XCTAssertEqual(chunker.flush(), "Done now.")
    }

    func testUnterminatedFenceStillSummarizesOnFlush() {
        var chunker = SentenceChunker()
        _ = chunker.consume("```\ncode line\n")
        XCTAssertEqual(chunker.flush(), "Code block, 1 line.")
    }

    func testLongUnpunctuatedRunFlushesAtWhitespace() {
        var chunker = SentenceChunker(maxChunkLength: 20)
        let chunks = chunker.consume("one two three four five six seven")
        XCTAssertFalse(chunks.isEmpty, "length guard must flush")
        for chunk in chunks {
            XCTAssertFalse(chunk.hasSuffix(" "), "no dangling whitespace")
            XCTAssertLessThanOrEqual(chunk.count, 20)
        }
    }

    func testFlushEmptyIsNil() {
        var chunker = SentenceChunker()
        XCTAssertNil(chunker.flush())
    }
}

// MARK: - Audio seam refusal contract (delta: on-device-ai-runtime)

@MainActor
final class AudioSeamTests: XCTestCase {

    func testNonEmptyAudioIsRefusedNeverDropped() async {
        let stub = StubLLMRuntime(capabilities: [.text, .vision, .audio])
        let request = LLMRequest(prompt: "hear this", audio: [Data([1, 2, 3])])
        do {
            _ = try await stub.generateText(request)
            XCTFail("audio must be refused until a conformer serves it")
        } catch let error as RuntimeError {
            XCTAssertEqual(error, .unsupportedModality(.audio))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testChatCarriesAudioIntoTheRefusal() async {
        let stub = StubLLMRuntime(capabilities: [.text])
        let request = LLMChatRequest(messages: [AgentMessage(role: .user, text: "hi")],
                                     audio: [Data([9])])
        do {
            for try await _ in stub.chat(request) {}
            XCTFail("chat must thread audio into the refusal contract")
        } catch let error as RuntimeError {
            XCTAssertEqual(error, .unsupportedModality(.audio))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyAudioChangesNothing() async throws {
        let stub = StubLLMRuntime(capabilities: [.text])
        stub.scriptedTokens = ["ok"]
        let out = try await stub.generateText(LLMRequest(prompt: "hi"))
        XCTAssertEqual(out, "ok")
    }

    func testAudioSelectsForAudioCapability() throws {
        let catalog = ModelCatalog.standard
        let descriptor = try catalog.selectModel(requiring: [.audio])
        XCTAssertTrue(descriptor.capabilities.contains(.audio))
    }
}
