import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure-Core substrate of `ai-batched-runtime-and-context` (tasks §1–§3, §5.1, §6): the
/// RAM-is-the-ceiling concurrency math, the interleaved-attention KV sum, the concrete context-budget
/// provider (the C3 tie-in to conversation-runtime compaction), context settings persistence, the
/// fixed-pattern subagent, and a stub batched runtime's de-mux. The MLX conformer (§4) is xcodebuild
/// compile-verify only; its real behavior is the user's stable-signed run-verify (task 8.3).
@MainActor
final class BatchedRuntimeTests: XCTestCase {

    // MARK: - KVCacheCost (interleaved sliding/global attention)

    func testKVInterleavedSumClampsSlidingAtWindowAndDiffersFromUniformGlobal() {
        let cost = KVCacheCost(slidingLayers: 30, globalLayers: 6, slidingWindow: 1024, kvBytesPerTokenPerLayer: 1.0)
        // At a context below the window, sliding and global both scale with ctx.
        let short = cost.kvBytes(forContext: 512)   // (30*512 + 6*512) = 18432
        XCTAssertEqual(short, 18_432)
        // Beyond the window, sliding layers clamp at the window while global layers keep growing.
        let long = cost.kvBytes(forContext: 8192)   // (30*1024 + 6*8192) = 30720 + 49152 = 79872
        XCTAssertEqual(long, 79_872)
        // Treating every layer as global would massively over-estimate (36 * 8192 = 294912).
        XCTAssertLessThan(long, 294_912, "interleaved accounting is far below uniform-global")
    }

    // MARK: - ConcurrencyBudget (K is RAM-derived, clamped ≥ 1)

    private func budget() -> ConcurrencyBudget {
        ConcurrencyBudget(
            unifiedMemoryBytes: 48 * 1_000_000_000,
            weightBytes: 17 * 1_000_000_000,
            reservedBytes: 6 * 1_000_000_000,
            kv: KVCacheCost(slidingLayers: 30, globalLayers: 6, slidingWindow: 1024,
                            kvBytesPerTokenPerLayer: 20_000))   // exaggerated so K is small + visible
    }

    func testMaxStreamsDecreasesMonotonicallyAsContextGrows() {
        let b = budget()
        let kShort = b.maxStreams(contextTokens: 1_000)
        let kMid = b.maxStreams(contextTokens: 8_000)
        let kLong = b.maxStreams(contextTokens: 64_000)
        XCTAssertGreaterThanOrEqual(kShort, kMid)
        XCTAssertGreaterThanOrEqual(kMid, kLong)
        XCTAssertGreaterThan(kShort, kLong, "growing context honestly lowers the concurrent-stream count")
    }

    func testMaxStreamsClampsToAtLeastOneEvenAtModelMax() {
        let b = budget()
        XCTAssertGreaterThanOrEqual(b.maxStreams(contextTokens: 131_072), 1,
                                    "the foreground session always fits — never an OOM at model-max context")
    }

    func testEstimatedRAMTracksStreamsAndContext() {
        let b = budget()
        let one = b.estimatedRAM(streams: 1, contextTokens: 4_000)
        let three = b.estimatedRAM(streams: 3, contextTokens: 4_000)
        XCTAssertGreaterThan(three, one, "more streams ⇒ more KV RAM")
        XCTAssertGreaterThan(one, b.weightBytes, "resident RAM includes the weights read once")
    }

    // MARK: - ModelDescriptor.maxContextTokens

    func testRegistryCarriesMaxContextTokens() {
        let d = ModelRegistry.standard.descriptor(id: "gemma-4-31b")
        XCTAssertEqual(d?.maxContextTokens, 131_072)
        XCTAssertEqual(ModelRegistry.standard.descriptor(id: "gemma-4-12b")?.maxContextTokens, 32_768)
    }

    // MARK: - Context preset + concrete budget provider (C3 tie-in)

    func testPresetResolvesAndClampsToModelMax() {
        XCTAssertEqual(AgentContextPreset.balanced.tokens(modelMax: 131_072, custom: 0), 8_192)
        XCTAssertEqual(AgentContextPreset.max.tokens(modelMax: 32_768, custom: 0), 32_768)
        XCTAssertEqual(AgentContextPreset.long.tokens(modelMax: 16_000, custom: 0), 16_000, "Long clamps to a smaller model max")
        XCTAssertEqual(AgentContextPreset.custom.tokens(modelMax: 10_000, custom: 999_999), 10_000, "an oversize custom clamps")
    }

    func testProviderEffectiveBudgetIsClampedMinOfUserSkillAndModelMax() {
        struct FixedOverride: SkillContextOverriding { let v: Int?; func contextOverride(forSkill: String?) -> Int? { v } }
        // A heavy skill raises the budget above the user's value...
        let raised = AgentContextBudgetProvider(userContextTokens: 8_192, modelMaxContextTokens: 131_072,
                                                activeSkillID: "summarizer", skillOverrides: FixedOverride(v: 64_000))
        XCTAssertEqual(raised.maxContextTokens, 64_000, "max(user, skillOverride)")
        // ...but everything is clamped to the model max.
        let clamped = AgentContextBudgetProvider(userContextTokens: 999_999, modelMaxContextTokens: 32_768,
                                                 skillOverrides: FixedOverride(v: nil))
        XCTAssertEqual(clamped.maxContextTokens, 32_768, "∩ model max")
    }

    func testGrowingTheBudgetDefersCompaction() {
        // The C3 tie-in: conversation-runtime's compaction reads THIS provider, so a larger budget defers
        // compaction and a smaller one triggers it sooner — they never disagree about "the budget".
        let convo = AgentConversation(title: "t",
                                      messages: (0..<20).map { AgentMessage(role: .user, text: "message number \($0) with some words") })
        let big = AgentContextBudgetProvider(userContextTokens: 100_000, modelMaxContextTokens: 131_072)
        let small = AgentContextBudgetProvider(userContextTokens: 10, modelMaxContextTokens: 131_072)
        XCTAssertFalse(ConversationCompactor.needsCompaction(convo, budget: big), "a large budget defers compaction")
        XCTAssertTrue(ConversationCompactor.needsCompaction(convo, budget: small), "a small budget triggers it sooner")
    }

    // MARK: - AppSettings persistence (defaults / clamp-at-use / reset / legacy)

    private func freshSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "tfs-batched-\(UUID().uuidString)")!)
    }

    func testContextSettingsDefaultsAndLegacyDecode() {
        let s = freshSettings()   // empty suite = legacy (no keys written)
        XCTAssertEqual(s.agentContextPreset, .balanced)
        XCTAssertEqual(s.agentContextTokens, 8_192)
        XCTAssertFalse(s.agentCompactKV)
    }

    func testContextSettingsPersistAndReset() {
        let suite = UserDefaults(suiteName: "tfs-batched-persist-\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        s.agentContextPreset = .max
        s.agentContextTokens = 131_072
        s.agentCompactKV = true
        // A fresh instance over the same suite reads the persisted values.
        let reloaded = AppSettings(defaults: suite)
        XCTAssertEqual(reloaded.agentContextPreset, .max)
        XCTAssertEqual(reloaded.agentContextTokens, 131_072)
        XCTAssertTrue(reloaded.agentCompactKV)
        // Reset-to-defaults returns them to Balanced / off (a behavior tunable).
        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.agentContextPreset, .balanced)
        XCTAssertEqual(reloaded.agentContextTokens, 8_192)
        XCTAssertFalse(reloaded.agentCompactKV)
    }

    // MARK: - Subagent (fixed-pattern context hygiene)

    func testSubagentRunsInFreshContextAndIsBounded() {
        let sub = Subagent(name: "summarize_docs", systemPrompt: "You summarize.", maxTurns: 0)
        XCTAssertEqual(sub.maxTurns, 1, "maxTurns is bounded ≥ 1")
        let convo = sub.freshConversation(input: "the long document")
        XCTAssertEqual(convo.messages.map(\.role), [.system, .user], "a fresh, isolated conversation — no orchestrator history")
        XCTAssertEqual(convo.messages[1].text, "the long document")
        XCTAssertEqual(convo.skillID, "summarize_docs")
        XCTAssertNotEqual(sub.freshConversation(input: "a").id, sub.freshConversation(input: "a").id,
                          "each run gets a distinct session id")
    }

    func testSubagentExposesARoutableToolDescriptor() {
        let sub = Subagent(name: "research", systemPrompt: "…")
        let d = sub.toolDescriptor
        XCTAssertEqual(d.name, "subagent:research")
        XCTAssertEqual(d.writePolicy, .auto, "a subagent is read-only to the orchestrator's world")
    }

    // MARK: - Stub batched runtime de-mux

    func testBatchStepDeMuxesTokensToTheRightSession() async throws {
        let a = AgentSessionID(), b = AgentSessionID()
        let stub = StubBatchedRuntime(maxConcurrentStreams: 3,
                                      perStream: [a: ["a1", "a2"], b: ["b1", "b2", "b3"]])
        var byID: [AgentSessionID: [String]] = [:]
        for try await (id, token) in stub.batchStep([a: req(), b: req()]) {
            byID[id, default: []].append(token.text)
        }
        XCTAssertEqual(byID[a], ["a1", "a2"], "stream A's tokens de-mux to A")
        XCTAssertEqual(byID[b], ["b1", "b2", "b3"], "stream B's tokens de-mux to B")
    }

    private func req() -> LLMChatRequest { LLMChatRequest(messages: [AgentMessage(role: .user, text: "hi")]) }

    // MARK: - AgentContextCostModel (the Hub cost surface, task 5.3)

    func testCostModelBackgroundStreamsDropAsContextGrows() {
        let mem = Int64(48) * 1_000_000_000
        let weights = Int64(17) * 1_000_000_000
        let small = AgentContextCostModel(contextTokens: 4_000, compactKV: false, weightBytes: weights, unifiedMemoryBytes: mem)
        let large = AgentContextCostModel(contextTokens: 100_000, compactKV: false, weightBytes: weights, unifiedMemoryBytes: mem)
        XCTAssertGreaterThanOrEqual(small.maxStreams, large.maxStreams, "more context → no more streams")
        XCTAssertGreaterThanOrEqual(small.backgroundStreams, large.backgroundStreams)
        XCTAssertGreaterThanOrEqual(large.maxStreams, 1, "foreground always fits (K ≥ 1)")
    }

    func testCostModelCompactKVAffordsAtLeastAsManyStreams() {
        let mem = Int64(48) * 1_000_000_000
        let weights = Int64(17) * 1_000_000_000
        let bf16 = AgentContextCostModel(contextTokens: 64_000, compactKV: false, weightBytes: weights, unifiedMemoryBytes: mem)
        let kv8 = AgentContextCostModel(contextTokens: 64_000, compactKV: true, weightBytes: weights, unifiedMemoryBytes: mem)
        XCTAssertGreaterThanOrEqual(kv8.maxStreams, bf16.maxStreams, "8-bit KV halves per-token cost → ≥ streams")
        XCTAssertLessThanOrEqual(kv8.estimatedRAMBytes, bf16.estimatedRAMBytes + weights, "compact KV is not more RAM per stream")
    }

    func testCostModelSpeedNoteBucketsByContext() {
        let weights = Int64(17) * 1_000_000_000
        XCTAssertEqual(AgentContextCostModel(contextTokens: 8_000, compactKV: false, weightBytes: weights).speedNote, "fastest per-token speed")
        XCTAssertEqual(AgentContextCostModel(contextTokens: 32_000, compactKV: false, weightBytes: weights).speedNote, "moderate per-token speed")
        XCTAssertEqual(AgentContextCostModel(contextTokens: 100_000, compactKV: false, weightBytes: weights).speedNote, "slower per-token speed")
    }

    func testCostModelBackgroundTextHonestAtKEqualsOne() {
        // A tiny memory budget so only the foreground fits → "no background sessions" honestly.
        let cost = AgentContextCostModel(contextTokens: 100_000, compactKV: false,
                                         weightBytes: Int64(45) * 1_000_000_000,
                                         unifiedMemoryBytes: Int64(48) * 1_000_000_000)
        XCTAssertEqual(cost.maxStreams, 1)
        XCTAssertEqual(cost.backgroundStreams, 0)
        XCTAssertEqual(cost.backgroundText, "no background sessions")
    }

    /// A deterministic `BatchedLLMRuntime` (test-only, task 1.4): scripts per-stream token sequences and
    /// de-muxes them by `AgentSessionID`.
    private final class StubBatchedRuntime: BatchedLLMRuntime, @unchecked Sendable {
        let capabilities: Set<Modality> = [.text]
        let maxConcurrentStreams: Int
        private let perStream: [AgentSessionID: [String]]
        init(maxConcurrentStreams: Int, perStream: [AgentSessionID: [String]]) {
            self.maxConcurrentStreams = maxConcurrentStreams
            self.perStream = perStream
        }
        func generate(_ request: LLMRequest) -> AsyncThrowingStream<Token, Error> {
            AsyncThrowingStream { c in c.yield(Token(request.prompt, isFinal: true)); c.finish() }
        }
        func structured<T: Decodable & Sendable>(_ request: LLMRequest, schema: StructuredSchema,
                                                 as type: T.Type) async throws -> StructuredOutcome<T> {
            throw RuntimeError.couldNotProduceValid(attempts: 1)
        }
        func batchStep(_ requests: [AgentSessionID: LLMChatRequest]) -> AsyncThrowingStream<(AgentSessionID, Token), Error> {
            let scripts = requests.keys.map { ($0, perStream[$0] ?? ["?"]) }
            return AsyncThrowingStream { c in
                for (id, toks) in scripts {
                    for (i, t) in toks.enumerated() { c.yield((id, Token(t, isFinal: i == toks.count - 1))) }
                }
                c.finish()
            }
        }
    }
}
