import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the canonical conversation types (`ai-conversation-runtime`, tasks §1.3 / §3.3) — the
/// Codable round-trip + equality that every other V2 slice relies on, and the model-agnostic
/// `ChatTemplate.flatten` assembler, including the load-bearing invariant that a turn's `thinking` is
/// NEVER emitted into the assembled prompt.
final class AgentConversationTests: XCTestCase {

    // MARK: - Canonical types: Codable round-trip + equality

    func testConversationCodableRoundTripPreservesAllFields() throws {
        let route = ToolRoute(tool: "add_to_calendar", argumentsJSON: "{\"title\":\"x\"}", rationale: "looks like a meeting")
        let result = ToolStepResult(tool: "add_to_calendar", status: .done, summary: "Added 'x'")
        let assistant = AgentMessage(id: UUID(), role: .assistant, text: "the answer",
                                     thinking: "the reasoning", image: Data([0x89, 0x50, 0x4E, 0x47]),
                                     toolCalls: [route], toolResult: result,
                                     createdAt: Date(timeIntervalSince1970: 1000))
        let user = AgentMessage(role: .user, text: "the question", createdAt: Date(timeIntervalSince1970: 999))
        let original = AgentConversation(id: AgentSessionID(),
                                         title: "A thread",
                                         messages: [user, assistant],
                                         createdAt: Date(timeIntervalSince1970: 998),
                                         updatedAt: Date(timeIntervalSince1970: 1001),
                                         compactedSummary: "earlier we discussed lunch",
                                         skillID: "create-meeting-in-gcal")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentConversation.self, from: data)
        XCTAssertEqual(decoded, original, "every field (incl. compactedSummary/skillID/image/toolCalls) round-trips")
        XCTAssertEqual(decoded.messages[1].thinking, "the reasoning", "thinking is persisted (for display)")
        XCTAssertEqual(decoded.messages[1].toolResult?.summary, "Added 'x'")
    }

    func testSessionIDIsStableHashableKey() {
        let id = AgentSessionID()
        var byID: [AgentSessionID: String] = [:]
        byID[id] = "one"
        XCTAssertEqual(byID[id], "one", "the session id is a stable dictionary key")
        XCTAssertEqual(id, AgentSessionID(raw: id.raw), "equality is by the raw UUID")
        XCTAssertNotEqual(id, AgentSessionID(), "two fresh ids differ")
    }

    func testMessageEquality() {
        let shared = UUID()
        let a = AgentMessage(id: shared, role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 1))
        let b = AgentMessage(id: shared, role: .user, text: "hi", createdAt: Date(timeIntervalSince1970: 1))
        let c = AgentMessage(id: shared, role: .user, text: "different", createdAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ChatTemplate.flatten

    func testFlattenPreservesRoleOrderAndExcludesThinking() {
        let messages = [
            AgentMessage(role: .system, text: "SYS"),
            AgentMessage(role: .user, text: "USER-ONE"),
            AgentMessage(role: .assistant, text: "ASSISTANT-ONE", thinking: "SECRET-REASONING"),
            AgentMessage(role: .user, text: "USER-TWO"),
        ]
        let prompt = ChatTemplate.flatten(messages)

        // Role order preserved.
        let sys = prompt.range(of: "System: SYS")
        let u1 = prompt.range(of: "User: USER-ONE")
        let a1 = prompt.range(of: "Assistant: ASSISTANT-ONE")
        let u2 = prompt.range(of: "User: USER-TWO")
        XCTAssertNotNil(sys); XCTAssertNotNil(u1); XCTAssertNotNil(a1); XCTAssertNotNil(u2)
        XCTAssertTrue(sys!.lowerBound < u1!.lowerBound && u1!.lowerBound < a1!.lowerBound
                      && a1!.lowerBound < u2!.lowerBound, "messages appear in order")

        // The load-bearing invariant: a turn's thinking is NEVER in the assembled prompt.
        XCTAssertFalse(prompt.contains("SECRET-REASONING"),
                       "thinking is structurally excluded from the assembled prompt")

        // Trailing cue invites the next turn.
        XCTAssertTrue(prompt.hasSuffix("Assistant:"), "a trailing Assistant: cue invites the next turn")
    }

    func testFlattenRendersToolResultSummaryNotRawText() {
        let result = ToolStepResult(tool: "memory.write", status: .done, summary: "Saved a note")
        let messages = [
            AgentMessage(role: .user, text: "remember this"),
            AgentMessage(role: .tool, text: "RAW-SHOULD-NOT-SHOW", toolResult: result),
        ]
        let prompt = ChatTemplate.flatten(messages)
        XCTAssertTrue(prompt.contains("Tool: Saved a note"), "a .tool message renders its result summary")
        XCTAssertFalse(prompt.contains("RAW-SHOULD-NOT-SHOW"), "the .tool message's raw text is not rendered")
    }

    func testFlattenEmptyListIsCueOnly() {
        XCTAssertEqual(ChatTemplate.flatten([]), "Assistant:", "an empty list yields just the cue")
    }

    // MARK: - Multi-image contract (design D2)

    func testMessageCarriesMultipleImagesAndImageIsFirst() {
        let a = Data([0x01]); let b = Data([0x02])
        let m = AgentMessage(role: .user, text: "two pics", images: [a, b])
        XCTAssertEqual(m.images, [a, b], "a single turn carries multiple images")
        XCTAssertEqual(m.image, a, "the single-image convenience is the first image")
        let none = AgentMessage(role: .user, text: "no pics")
        XCTAssertEqual(none.images, [])
        XCTAssertNil(none.image)
    }

    func testSingleImageConvenienceInitFoldsIntoImagesArray() {
        let png = Data([0xAB])
        let m = AgentMessage(role: .user, text: "one pic", image: png)
        XCTAssertEqual(m.images, [png], "the image: convenience init folds one image into the array")
        let nilImage = AgentMessage(role: .user, text: "none", image: nil)
        XCTAssertEqual(nilImage.images, [], "a nil image yields an empty array")
    }

    func testMessageCodableRoundTripsMultipleImagesAndDecodesLegacySingularKey() throws {
        let a = Data([0x10]); let b = Data([0x20])
        let m = AgentMessage(id: UUID(), role: .user, text: "t", images: [a, b],
                             createdAt: Date(timeIntervalSince1970: 1))
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(AgentMessage.self, from: data).images, [a, b],
                       "multiple images round-trip through Codable")

        // A LEGACY blob with a singular `image` key (the pre-D2 shape) decodes into a one-element array.
        let legacy = """
        {"id":"\(UUID().uuidString)","role":"user","text":"t","image":"\(a.base64EncodedString())","createdAt":1}
        """
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.images, [a], "a legacy singular image key decodes into the images array")
    }

    func testChatRequestForwardsAllImagesViaEffectiveImages() {
        let a = Data([0x01]); let b = Data([0x02])
        let msgs = [AgentMessage(role: .user, text: "q", images: [a, b])]
        // Request-level images take precedence when set.
        let explicit = LLMChatRequest(messages: msgs, images: [Data([0x09])])
        XCTAssertEqual(explicit.effectiveImages, [Data([0x09])])
        // Otherwise the latest image-bearing message's FULL array is forwarded.
        let fromMessages = LLMChatRequest(messages: msgs)
        XCTAssertEqual(fromMessages.effectiveImages, [a, b], "effectiveImages forwards ALL of the turn's images")
        XCTAssertEqual(fromMessages.effectiveImage, a, "effectiveImage is the first effective image")
        // The single-image convenience init still works (additive default).
        let single = LLMChatRequest(messages: [], image: a)
        XCTAssertEqual(single.images, [a])
    }

    // MARK: - The display timeline + born-with tuning (`notch-timeline-and-tuning`)

    func testSegmentsAndBornWithTuningRoundTripThroughCodable() throws {
        let segments = [TurnSegment(kind: .thinking, text: "T1"),
                        TurnSegment(kind: .answer, text: "R1"),
                        TurnSegment(kind: .thinking, text: "T2")]
        let message = AgentMessage(role: .assistant, text: "R1", thinking: "T1T2", segments: segments,
                                   createdAt: Date(timeIntervalSince1970: 1))
        let convo = AgentConversation(title: "t", messages: [message],
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      updatedAt: Date(timeIntervalSince1970: 2),
                                      reasoningOverride: false, contextTokens: 32_768)
        let decoded = try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(convo))
        XCTAssertEqual(decoded, convo, "the segment timeline + born-with tuning round-trip")
        XCTAssertEqual(decoded.messages[0].segments, segments,
                       "segments keep their cross-channel arrival order")
        XCTAssertEqual(decoded.reasoningOverride, false)
        XCTAssertEqual(decoded.contextTokens, 32_768)
    }

    func testPreChangeJSONDecodesWithNilSegmentsAndTuning() throws {
        // A row persisted BEFORE this change carries none of the new keys — everything decodes nil
        // (the decode-safe optional contract; nothing throws, nothing is dropped).
        let legacy = """
        {"id":"\(UUID().uuidString)","role":"assistant","text":"answer","thinking":"old","createdAt":1}
        """
        let message = try JSONDecoder().decode(AgentMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(message.segments, "a pre-change message has no stored timeline")
        let convo = AgentConversation(title: "t", messages: [message])
        let decoded = try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(convo))
        XCTAssertNil(decoded.reasoningOverride)
        XCTAssertNil(decoded.contextTokens)
    }

    func testDisplaySegmentsFallsBackForPreChangeMessages() {
        // Legacy flat thinking → ONE leading thinking block, then the answer (the spec's fallback).
        let legacy = AgentMessage(role: .assistant, text: "answer", thinking: "old reasoning")
        XCTAssertEqual(legacy.displaySegments,
                       [TurnSegment(kind: .thinking, text: "old reasoning"),
                        TurnSegment(kind: .answer, text: "answer")])
        // No thinking at all → just the answer block.
        let bare = AgentMessage(role: .assistant, text: "answer")
        XCTAssertEqual(bare.displaySegments, [TurnSegment(kind: .answer, text: "answer")])
        // A stored timeline wins over the flat fields.
        let timeline = [TurnSegment(kind: .answer, text: "a"), TurnSegment(kind: .thinking, text: "t")]
        let modern = AgentMessage(role: .assistant, text: "a", thinking: "t", segments: timeline)
        XCTAssertEqual(modern.displaySegments, timeline)
    }
}
