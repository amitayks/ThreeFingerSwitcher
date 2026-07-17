import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the deterministic CPU-lane stub (`StubTernaryRuntime`, task §2.3) and the CPU-lane error
/// mapping into `RuntimeError` → `AIError.message(for:)` (tasks §4.1 / §4.2). These exercise the
/// EXISTING `LLMRuntime` seam (design D2 — a second conformer, not a new protocol) without real weights.
final class StubTernaryRuntimeTests: XCTestCase {

    private struct RouteDecision: Codable, Equatable { let action: String }

    // MARK: - §2.3 structured route turn + short generate, de-mux to the right session

    func testStructuredRouteTurnProducesValue() async throws {
        let json = "{\"action\":\"open\"}"
        let runtime = StubTernaryRuntime(
            structuredScript: .valid(json: json)
        )
        let schema = StructuredSchema(name: "route", json: "{\"required\":[\"action\"]}")
        let outcome = try await runtime.structured(
            LLMRequest(prompt: "route this"),
            schema: schema,
            as: RouteDecision.self
        )
        XCTAssertEqual(outcome.value, RouteDecision(action: "open"))
    }

    func testStructuredCanDecline() async throws {
        let runtime = StubTernaryRuntime(structuredScript: .decline(reason: "not a tool task"))
        let schema = StructuredSchema(name: "route", json: "{\"required\":[\"action\"]}")
        let outcome = try await runtime.structured(
            LLMRequest(prompt: "chat"),
            schema: schema,
            as: RouteDecision.self
        )
        XCTAssertTrue(outcome.isDeclined)
        XCTAssertEqual(outcome.declineReason, "not a tool task")
    }

    func testShortGenerateStreamsScriptedTokens() async throws {
        let runtime = StubTernaryRuntime(scriptedTokens: ["yes", " ", "park"], interTokenDelayNanos: 0)
        var out = ""
        for try await token in runtime.generate(LLMRequest(prompt: "should park?")) {
            out += token.text
        }
        XCTAssertEqual(out, "yes park")
    }

    func testTokensDeMuxToTheRightSession() async throws {
        // Two independent sessions, each its own stub burst → each session's text stays its own.
        let sessionA = AgentSessionID()
        let sessionB = AgentSessionID()
        let rtA = StubTernaryRuntime(scriptedTokens: ["A1", "A2"], interTokenDelayNanos: 0)
        let rtB = StubTernaryRuntime(scriptedTokens: ["B1", "B2"], interTokenDelayNanos: 0)

        var collected: [AgentSessionID: String] = [:]
        for try await t in rtA.generate(LLMRequest(prompt: "a")) {
            collected[sessionA, default: ""] += t.text
        }
        for try await t in rtB.generate(LLMRequest(prompt: "b")) {
            collected[sessionB, default: ""] += t.text
        }
        XCTAssertEqual(collected[sessionA], "A1A2")
        XCTAssertEqual(collected[sessionB], "B1B2")
    }

    // MARK: - §5.3 capabilities = text only; vision is a hard error (never routed to CPU)

    func testCapabilitiesAdvertiseTextOnly() {
        let runtime = StubTernaryRuntime()
        XCTAssertEqual(runtime.capabilities, [.text])
        XCTAssertFalse(runtime.capabilities.contains(.vision))
    }

    func testVisionRequestIsHardError() async {
        let runtime = StubTernaryRuntime()
        let request = LLMRequest(prompt: "describe", image: Data([0x1]))
        do {
            for try await _ in runtime.generate(request) {}
            XCTFail("a vision request against the text-only CPU lane must error")
        } catch let RuntimeError.unsupportedModality(modality) {
            XCTAssertEqual(modality, .vision)
        } catch {
            XCTFail("expected unsupportedModality, got \(error)")
        }
    }

    // MARK: - §4.1 a simulated CPU-lane failure → clean AIPresentedError headline (no raw text)

    func testSimulatedCPULaneFailureMapsToCleanHeadline() async {
        let runtime = StubTernaryRuntime(scriptedError: .modelLoadFailed(detail: "bitnet ctx init -12"))
        do {
            for try await _ in runtime.generate(LLMRequest(prompt: "route")) {}
            XCTFail("the scripted failure must throw")
        } catch {
            let presented = AIError.message(for: error)
            XCTAssertEqual(presented.headline, "The model could not be loaded.")
            // The raw vendor text rides on details ONLY — never the headline.
            XCTAssertFalse(presented.headline.contains("bitnet"))
            XCTAssertEqual(presented.details, "bitnet ctx init -12")
        }
    }

    func testStructuredFailureMapsToCleanHeadline() async {
        let runtime = StubTernaryRuntime(scriptedError: .unavailable(reason: "ternary lane unavailable"))
        let schema = StructuredSchema(name: "route", json: "{\"required\":[\"action\"]}")
        do {
            _ = try await runtime.structured(LLMRequest(prompt: "x"), schema: schema, as: RouteDecision.self)
            XCTFail("the scripted failure must throw")
        } catch {
            let presented = AIError.message(for: error)
            XCTAssertEqual(presented.headline, "ternary lane unavailable")
        }
    }

    // MARK: - §4.2 a cancelled CPU-lane turn is NOT a failure

    func testCancelledCPULaneTurnIsNotAFailure() async throws {
        // A slow burst we cancel mid-stream. Dropping the iterator after the first token fires the
        // stream's `onTermination`, which cancels the producer — whose next checkpoint surfaces a benign
        // cancellation (RuntimeError.cancelled / CancellationError), NEVER a real `.failed` for the turn.
        let runtime = StubTernaryRuntime(scriptedTokens: Array(repeating: "x", count: 30),
                                         interTokenDelayNanos: 20_000_000)  // 20 ms/token
        enum Outcome: Equatable { case benignCancelled, completed, otherFailure }
        var consumed = 0
        let stream = runtime.generate(LLMRequest(prompt: "long"))
        let task = Task { () -> Outcome in
            do {
                for try await _ in stream {
                    consumed += 1
                    if consumed >= 1 { break }   // stop consuming → onTermination cancels the producer
                }
                return .completed
            } catch RuntimeError.cancelled {
                return .benignCancelled
            } catch is CancellationError {
                return .benignCancelled
            } catch {
                return .otherFailure
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let result = await task.value
        // The decisive property: the burst did NOT run to completion, and the outcome is benign (a
        // discarded turn), not a failure.
        XCTAssertLessThan(consumed, 30, "cancellation stops the CPU-lane burst before all tokens emit")
        XCTAssertNotEqual(result, .otherFailure, "a cancelled CPU-lane turn is NOT a real failure")
        // AIError gives a clean benign "Cancelled." headline — NOT a generic failure or a false "done."
        XCTAssertEqual(AIError.message(for: CancellationError()).headline, "Cancelled.")
        XCTAssertEqual(AIError.message(for: RuntimeError.cancelled).headline, "Cancelled.")
    }
}
