import XCTest
@testable import ThreeFingerSwitcherCore

/// `add-voice-computer-use-agent`: the controller executing the pure model's effects through the
/// stub seams — the spec scenario "Voice logic verifies with the stub": capture → transcript → turn
/// → spoken reply → barge-in, deterministically, no Speech framework involved.
@MainActor
final class VoiceSessionControllerTests: XCTestCase {

    private final class TurnScriptBox {
        var tokens: [Token] = []
        var started = 0
        var cancelled = false
    }

    private func makeController(transcriber: StubTranscriber,
                                synthesizer: StubSynthesizer,
                                micAuthorized: Bool = true,
                                turns: TurnScriptBox) -> VoiceSessionController {
        VoiceSessionController(
            transcriberFactory: { transcriber },
            synthesizer: synthesizer,
            micAuthorizer: { micAuthorized },
            turnStarter: { _ in
                turns.started += 1
                let scripted = turns.tokens
                return AsyncThrowingStream { continuation in
                    let task = Task {
                        for token in scripted {
                            try Task.checkCancellation()
                            continuation.yield(token)
                            await Task.yield()
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in
                        task.cancel()
                        turns.cancelled = true
                    }
                }
            })
    }

    /// Drain main-actor tasks so async effect chains settle deterministically.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testEndToEndSpokenTurn() async {
        let transcriber = StubTranscriber(partials: ["read"], final: "read the window")
        let synthesizer = StubSynthesizer()
        let turns = TurnScriptBox()
        turns.tokens = [Token("Here is the text. ", isFinal: false),
                        Token("It says hello.", isFinal: true)]
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer, turns: turns)

        controller.pttDown()
        await settle()
        XCTAssertTrue(transcriber.isCapturing, "mic opens on press")
        XCTAssertEqual(controller.phase, .listening)

        controller.pttUp()
        await settle()
        XCTAssertFalse(transcriber.isCapturing, "mic closes on release")
        XCTAssertEqual(turns.started, 1, "the finalized transcript starts the turn")

        await settle()
        XCTAssertEqual(synthesizer.spoken.first, "Here is the text.",
                       "the first sentence speaks before the stream ends")
        XCTAssertTrue(synthesizer.spoken.contains("It says hello."))

        synthesizer.finishAll()
        await settle()
        XCTAssertEqual(controller.phase, .idle, "settled + drained → idle")
    }

    func testThinkingChannelIsNeverSpoken() async {
        let transcriber = StubTranscriber(final: "think about it")
        let synthesizer = StubSynthesizer()
        let turns = TurnScriptBox()
        turns.tokens = [Token("secret reasoning", isFinal: false, channel: .thinking),
                        Token("The answer.", isFinal: true)]
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer, turns: turns)

        controller.pttDown(); await settle()
        controller.pttUp(); await settle(); await settle()
        XCTAssertEqual(synthesizer.spoken, ["The answer."],
                       "thinking never reaches the synthesizer")
    }

    func testMicDenialSurfacesCleanCard() async {
        let transcriber = StubTranscriber(final: "irrelevant")
        let synthesizer = StubSynthesizer()
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer,
                                        micAuthorized: false, turns: TurnScriptBox())
        controller.pttDown()
        await settle()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastFailure?.headline,
                       VoiceError.micDenied.errorDescription,
                       "the clean headline, never raw vendor text")
    }

    func testOSTooOldWhenFactoryReturnsNil() async {
        let synthesizer = StubSynthesizer()
        let controller = VoiceSessionController(
            transcriberFactory: { nil },
            synthesizer: synthesizer,
            micAuthorizer: { true },
            turnStarter: { _ in AsyncThrowingStream { $0.finish() } })
        controller.pttDown()
        await settle()
        XCTAssertEqual(controller.lastFailure?.headline, VoiceError.osTooOld.errorDescription)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testBargeInStopsSynthesizerAndCancelsTurn() async {
        let transcriber = StubTranscriber(final: "long story")
        let synthesizer = StubSynthesizer()
        let turns = TurnScriptBox()
        // An endless-ish stream (many sentences) so the barge-in lands mid-turn.
        turns.tokens = (0..<50).map { Token("Sentence number \($0). ", isFinal: false) }
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer, turns: turns)

        controller.pttDown(); await settle()
        controller.pttUp(); await settle()
        XCTAssertGreaterThan(synthesizer.spoken.count, 0, "speaking began")

        let spokenBeforeBarge = synthesizer.spoken.count
        controller.pttDown()   // barge-in
        await settle()
        XCTAssertGreaterThanOrEqual(synthesizer.stopCount, 1, "TTS stopped immediately")
        XCTAssertEqual(controller.phase, .listening, "barge-in listens")
        await settle()
        XCTAssertEqual(synthesizer.spoken.count, spokenBeforeBarge,
                       "no late tokens are spoken after the barge-in")
    }

    func testHumanTouchAborts() async {
        let transcriber = StubTranscriber(final: "act on it")
        let synthesizer = StubSynthesizer()
        let turns = TurnScriptBox()
        turns.tokens = (0..<50).map { Token("Working on step \($0). ", isFinal: false) }
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer, turns: turns)

        controller.pttDown(); await settle()
        controller.pttUp(); await settle()
        controller.humanTouch()
        await settle()
        XCTAssertEqual(controller.phase, .idle, "touch aborts to idle — the mic does not open")
        XCTAssertGreaterThanOrEqual(synthesizer.stopCount, 1)
    }

    func testIsConversationActiveFeedsQuiescence() async {
        let transcriber = StubTranscriber(final: "hello")
        let synthesizer = StubSynthesizer()
        let turns = TurnScriptBox()
        turns.tokens = [Token("Hi.", isFinal: true)]
        let controller = makeController(transcriber: transcriber, synthesizer: synthesizer, turns: turns)
        XCTAssertFalse(controller.isConversationActive)
        controller.pttDown(); await settle()
        XCTAssertTrue(controller.isConversationActive,
                      "a live voice phase counts as a foreground conversational surface")
    }
}
