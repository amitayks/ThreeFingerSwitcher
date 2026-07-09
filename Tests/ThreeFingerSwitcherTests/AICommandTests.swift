import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the AI command value model (spec: "AI command value model and persistence"): Codable
/// round-trip, the confirm-defaults-on-for-side-effects-but-honored invariant (design D6), and the
/// capability derivation that drives model selection.
final class AICommandTests: XCTestCase {

    // MARK: - Codable round-trip

    func testCommandRoundTripsThroughCodable() throws {
        let command = AICommand(
            name: "Fix Grammar",
            icon: .sfSymbol("text.badge.checkmark"),
            tint: ItemColor(red: 0.25, green: 0.72, blue: 0.40),
            input: .selection,
            promptTemplate: "Fix:\n{input}",
            output: .replaceSelection,
            model: .onDevice(modelID: "gemma-4-31b"),
            confirmBeforeRun: false
        )
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AICommand.self, from: data)
        XCTAssertEqual(decoded, command, "a command survives an encode/decode round-trip unchanged")
    }

    func testTaskAndDestinationOutputsRoundTrip() throws {
        let cases: [OutputTarget] = [
            .replaceSelection,
            .pasteAtCursor,
            .previewOnly,
            .runTask(.addToCalendar),
            .runTask(.saveToProject(project: "Inbox")),
            .runTask(.openToolWithPayload(tool: "com.example.tool")),
            .runTask(.sendTo(.shortcut(name: "Log It"))),
            .sendTo(.urlScheme("things:///add?title=")),
            .sendTo(.shell(command: "tee -a log.txt"))
        ]
        for output in cases {
            let command = AICommand(name: "C", icon: .emoji("✨"), input: .none,
                                    promptTemplate: "{date}", output: output)
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(AICommand.self, from: data)
            XCTAssertEqual(decoded, command, "output \(output) (as a set) round-trips")
            XCTAssertEqual(decoded.outputs, AICommand.migrate(output: output),
                           "output \(output) migrates to its capability set")
        }
    }

    // MARK: - RuntimeParameter Codable (new shape + legacy back-compat)

    func testRuntimeParameterRoundTripsBothFactories() throws {
        for param: RuntimeParameter in [.language(default: "Hebrew"), .codeLanguage(default: "Rust")] {
            let data = try JSONEncoder().encode(param)
            let decoded = try JSONDecoder().decode(RuntimeParameter.self, from: data)
            XCTAssertEqual(decoded, param, "the runtime parameter round-trips with its own option set")
        }
    }

    func testLegacyLanguageParameterPayloadStillDecodes() throws {
        // A band persisted BEFORE the case was renamed stored `{"language": {"default": …}}` (no
        // options). It must still decode — as a `.languageChoice` defaulting to the human-language list —
        // so an existing install's AI band keeps loading (no migration pass runs).
        let legacy = Data(#"{"language":{"default":"Spanish"}}"#.utf8)
        let decoded = try JSONDecoder().decode(RuntimeParameter.self, from: legacy)
        XCTAssertEqual(decoded.languageDefault, "Spanish", "the legacy default survives")
        XCTAssertEqual(decoded.options, AILanguages.all,
                       "a legacy payload (no options) defaults to the human-language list")
    }

    // MARK: - Per-command reasoning override (resolution + legacy back-compat)

    func testResolvedReasoningResolvesAgainstGlobalDefault() {
        func cmd(_ r: AIReasoning?) -> AICommand {
            AICommand(name: "R", icon: .emoji("🧠"), input: .selection,
                      promptTemplate: "{input}", output: .previewOnly, reasoning: r)
        }
        // .on / .off pin regardless of the global; nil follows the global default.
        XCTAssertTrue(cmd(.on).resolvedReasoning(globalDefault: false), ".on forces reasoning on")
        XCTAssertFalse(cmd(.off).resolvedReasoning(globalDefault: true), ".off forces reasoning off")
        XCTAssertTrue(cmd(nil).resolvedReasoning(globalDefault: true), "nil follows the global (on)")
        XCTAssertFalse(cmd(nil).resolvedReasoning(globalDefault: false), "nil follows the global (off)")
    }

    func testLegacyCommandPayloadWithoutReasoningDecodesToNil() throws {
        // A command persisted before `reasoning` existed has no key; synthesized Codable's
        // decodeIfPresent must yield nil (⇒ follow the global default), not fail to decode.
        let original = AICommand(name: "Fix", icon: .sfSymbol("checkmark"), input: .selection,
                                 promptTemplate: "{input}", output: .replaceSelection)
        var json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "reasoning")   // simulate a pre-feature payload
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(AICommand.self, from: stripped)
        XCTAssertNil(decoded.reasoning, "a legacy command without the key decodes to nil (follows global)")
    }

    // MARK: - confirmBeforeRun default + honored

    func testConfirmDefaultsOnForSideEffectingOutputs() {
        let task = AICommand(name: "Cal", icon: .emoji("📅"), input: .selection,
                             promptTemplate: "{input}", output: .runTask(.addToCalendar))
        XCTAssertTrue(task.confirmBeforeRun, "a task output defaults confirmBeforeRun ON")

        let sendTo = AICommand(name: "Send", icon: .emoji("📤"), input: .selection,
                               promptTemplate: "{input}", output: .sendTo(.shortcut(name: "X")))
        XCTAssertTrue(sendTo.confirmBeforeRun, "a send-to output defaults confirmBeforeRun ON")
    }

    func testConfirmDefaultsOffForInPlaceOutputs() {
        for output: OutputTarget in [.replaceSelection, .pasteAtCursor, .previewOnly] {
            let command = AICommand(name: "C", icon: .emoji("✨"), input: .selection,
                                    promptTemplate: "{input}", output: output)
            XCTAssertFalse(command.confirmBeforeRun,
                           "in-place output \(output) defaults confirmBeforeRun OFF")
        }
    }

    func testExplicitConfirmFalseIsHonoredNotOverriddenForSideEffectingOutput() throws {
        // A user disables confirmation on a trusted side-effecting command.
        let command = AICommand(name: "Cal", icon: .emoji("📅"), input: .selection,
                                promptTemplate: "{input}", output: .runTask(.addToCalendar),
                                confirmBeforeRun: false)
        XCTAssertFalse(command.confirmBeforeRun,
                       "an explicit false is taken verbatim at creation, not re-defaulted to true")

        // ...and the stored value survives persistence (never recomputed on decode).
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(AICommand.self, from: data)
        XCTAssertFalse(decoded.confirmBeforeRun, "the stored false is honored after a round-trip")
    }

    func testDefaultConfirmHelperMatchesSideEffectClassification() {
        XCTAssertTrue(AICommand.defaultConfirmBeforeRun(for: [.runTask(.addToCalendar)]))
        XCTAssertTrue(AICommand.defaultConfirmBeforeRun(for: [.sendTo(.shortcut(name: "X"))]))
        // A set containing ANY side-effecting member confirms; a purely in-place set does not.
        XCTAssertTrue(AICommand.defaultConfirmBeforeRun(for: [.previewOnly, .runTask(.newContact)]))
        XCTAssertFalse(AICommand.defaultConfirmBeforeRun(for: [.replaceSelection, .pasteAtCursor, .previewOnly]))
        XCTAssertFalse(AICommand.defaultConfirmBeforeRun(for: [.pasteAtCursor]))
    }

    // MARK: - Capability sets: defaults, migration, resolution (change `ai-action-context-resolution`)

    func testDefaultCapabilitySetsAreAllOn() {
        XCTAssertEqual(AICommand.defaultInputs, [.selection, .clipboard, .clipboardImage],
                       "a new command's inputs default to the ambient cascade")
        XCTAssertEqual(AICommand.defaultOutputs, [.replaceSelection, .pasteAtCursor, .previewOnly],
                       "a new command's in-place outputs default all-on")
    }

    func testLegacyScalarMigrationMapping() {
        // The pure migration table (design D5): behavior-preserving, with the selection→clipboard fallback
        // made explicit and replaceSelection gaining pasteAtCursor.
        XCTAssertEqual(AICommand.migrate(input: .selection), [.selection, .clipboard])
        XCTAssertEqual(AICommand.migrate(input: .clipboard), [.clipboard])
        XCTAssertEqual(AICommand.migrate(input: .clipboardImage), [.clipboardImage])
        XCTAssertEqual(AICommand.migrate(input: .screenRegion), [.screenRegion])
        XCTAssertEqual(AICommand.migrate(input: .none), [])
        XCTAssertEqual(AICommand.migrate(output: .replaceSelection), [.replaceSelection, .pasteAtCursor])
        XCTAssertEqual(AICommand.migrate(output: .pasteAtCursor), [.pasteAtCursor])
        XCTAssertEqual(AICommand.migrate(output: .previewOnly), [.previewOnly])
        XCTAssertEqual(AICommand.migrate(output: .runTask(.addToCalendar)), [.runTask(.addToCalendar)])
    }

    func testLegacyScalarInputOutputMigrateOnDecode() throws {
        // A command persisted with the OLD single `input`/`output` scalar keys must decode into the sets.
        // Rewrite a modern command's JSON to that legacy shape, then decode.
        let modern = AICommand(name: "Fix", icon: .sfSymbol("checkmark"),
                               inputs: [.selection], promptTemplate: "{input}", outputs: [.previewOnly])
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
        dict.removeValue(forKey: "inputs")
        dict.removeValue(forKey: "outputs")
        dict["input"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(InputSource.selection), options: [.fragmentsAllowed])
        dict["output"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(OutputTarget.replaceSelection))
        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(AICommand.self, from: data)
        XCTAssertEqual(decoded.inputs, [.selection, .clipboard], "legacy .selection → {selection, clipboard}")
        XCTAssertEqual(decoded.outputs, [.replaceSelection, .pasteAtCursor],
                       "legacy .replaceSelection → {replaceSelection, pasteAtCursor}")
    }

    func testInPlaceCommitPlanResolvesFromChannelAndOutputs() {
        let all = AICommand.defaultOutputs   // {replace, paste, preview}
        // A selection source replaces; a clipboard source pastes (the core "it knows what to do").
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: true, outputs: all), .replaceSelection)
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: false, outputs: all), .pasteAtCursor)
        // Replace disabled → a selection still pastes.
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: true,
                                                   outputs: [.pasteAtCursor, .previewOnly]), .pasteAtCursor)
        // Preview-only (read-only understanding command) writes nothing even with a selection.
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: true, outputs: [.previewOnly]), .preview)
        // Only replace enabled, no selection → still replace (SelectionService pastes when not settable).
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: false, outputs: [.replaceSelection]),
                       .replaceSelection)
        // Nothing enabled → preview (safe default).
        XCTAssertEqual(AICommand.inPlaceCommitPlan(resolvedWasSelection: true, outputs: []), .preview)
    }

    func testRequiredCapabilitiesIsUnionOverInputs() {
        let mixed = AICommand(name: "M", icon: .emoji("🖼"), inputs: [.selection, .clipboardImage],
                              promptTemplate: "{input}", outputs: [.previewOnly])
        XCTAssertEqual(mixed.requiredCapabilities, [.text, .vision],
                       "a command mixing text + image inputs unions both capabilities")
        let standalone = AICommand(name: "S", icon: .emoji("✨"), inputs: [],
                                   promptTemplate: "{date}", outputs: [.previewOnly])
        XCTAssertEqual(standalone.requiredCapabilities, [.text], "an empty input set needs only text")
    }

    func testSideEffectAccessor() {
        let task = AICommand(name: "Cal", icon: .emoji("📅"), inputs: [.selection],
                             promptTemplate: "{input}", outputs: [.runTask(.addToCalendar)])
        XCTAssertEqual(task.sideEffect, .runTask(.addToCalendar))
        XCTAssertTrue(task.isSideEffecting)
        let inPlace = AICommand(name: "Fix", icon: .emoji("✍️"), inputs: [.selection],
                                promptTemplate: "{input}", outputs: [.replaceSelection, .pasteAtCursor])
        XCTAssertNil(inPlace.sideEffect)
        XCTAssertFalse(inPlace.isSideEffecting)
    }

    // MARK: - requiredCapabilities

    func testScreenRegionRequiresVision() {
        let command = AICommand(name: "Describe", icon: .emoji("👁"), input: .screenRegion,
                                promptTemplate: "What's here?", output: .previewOnly)
        XCTAssertEqual(command.requiredCapabilities, [.vision],
                       "a screenRegion command needs a vision-capable model")
    }

    func testClipboardImageRequiresVision() {
        let command = AICommand(name: "Describe Clipboard Image", icon: .emoji("🖼"), input: .clipboardImage,
                                promptTemplate: "What's in this image?", output: .previewOnly)
        XCTAssertEqual(command.requiredCapabilities, [.vision],
                       "a clipboardImage command needs a vision-capable model, statically — like screenRegion")
    }

    func testTextInputsRequireOnlyText() {
        for input: InputSource in [.selection, .clipboard, .none] {
            let command = AICommand(name: "C", icon: .emoji("✨"), input: input,
                                    promptTemplate: "{input}", output: .previewOnly)
            XCTAssertEqual(command.requiredCapabilities, [.text],
                           "input \(input) requires only the text capability")
        }
    }
}
