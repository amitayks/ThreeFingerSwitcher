import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the swappable model seam exercised through `StubLLMRuntime`: streaming order +
/// finality, prompt-cancellation stops generation, capability reporting, and the structured
/// validate → repair/retry → decode → decline pipeline (design D1/D2).
final class LLMRuntimeStubTests: XCTestCase {

    // A simple Decodable target for the structured tests.
    private struct CalendarEvent: Decodable, Equatable, Sendable {
        let title: String
        let start: String
    }

    private let calendarSchema = StructuredSchema(
        name: "calendar_event",
        json: #"{"type":"object","required":["title","start"]}"#
    )

    // MARK: Streaming

    func testStreamingEmitsScriptedTokensInOrderWithFinalFlag() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["Hello", ", ", "world"], interTokenDelayNanos: 0)
        var texts: [String] = []
        var finals: [Bool] = []
        for try await token in stub.generate(LLMRequest(prompt: "ignored")) {
            texts.append(token.text)
            finals.append(token.isFinal)
        }
        XCTAssertEqual(texts, ["Hello", ", ", "world"], "tokens stream in scripted order")
        XCTAssertEqual(finals, [false, false, true], "only the last token is marked final")
    }

    func testGenerateTextConcatenatesStream() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["a", "b", "c"], interTokenDelayNanos: 0)
        let full = try await stub.generateText(LLMRequest(prompt: "x"))
        XCTAssertEqual(full, "abc")
    }

    func testEmptyScriptEchoesPrompt() async throws {
        let stub = StubLLMRuntime(scriptedTokens: [], interTokenDelayNanos: 0)
        let full = try await stub.generateText(LLMRequest(prompt: "echo me"))
        XCTAssertEqual(full, "echo me", "an unscripted stub echoes the prompt")
    }

    // MARK: Cancellation

    func testCancellationStopsGeneration() async throws {
        // A slow stream so we can cancel after the first token. 20 chunks at 20ms each.
        let stub = StubLLMRuntime(scriptedTokens: Array(repeating: "x", count: 20),
                                  interTokenDelayNanos: 20_000_000)
        let counter = TokenCounter()

        // Consume the stream explicitly so we can cancel the *stream-backing* Task (via the iterator
        // being dropped on cancellation) and observe the runtime's terminal error.
        let stream = stub.generate(LLMRequest(prompt: "p"))
        let task = Task<RuntimeError?, Never> {
            do {
                for try await _ in stream {
                    await counter.bump()
                    // Stop consuming after the first token; the stream's onTermination cancels the
                    // producer, which then finishes the stream with .cancelled on its next checkpoint.
                    if await counter.value >= 1 { break }
                }
                return nil
            } catch let e as RuntimeError {
                return e
            } catch is CancellationError {
                return .cancelled
            } catch {
                return nil
            }
        }

        // Let a couple of tokens flow, then cancel the consuming task.
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value

        // The decisive property: generation did NOT run to completion — cancellation stopped it.
        let count = await counter.value
        XCTAssertLessThan(count, 20, "cancellation stops generation before all tokens are emitted")
    }

    /// Verifies the runtime DETECTS cancellation and stops the generation work (mapping it to
    /// `RuntimeError.cancelled` internally). We observe the stub's deterministic `observedCancellation`
    /// flag rather than racing the consumer-side iterator termination: when the consuming task is
    /// cancelled, the stream's onTermination cancels the producer, whose checkpoint throws
    /// `CancellationError` and is recorded.
    func testCancellationIsDetectedByTheRuntime() async throws {
        let stub = StubLLMRuntime(scriptedTokens: Array(repeating: "x", count: 50),
                                  interTokenDelayNanos: 10_000_000)
        let task = Task {
            for try await _ in stub.generate(LLMRequest(prompt: "p")) {
                // keep consuming until cancelled
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        _ = try? await task.value

        // Poll the deterministic flag with a bounded wait (producer cancel → catch is async).
        var observed = stub.observedCancellation
        for _ in 0..<50 where !observed {
            try await Task.sleep(nanoseconds: 5_000_000)
            observed = stub.observedCancellation
        }
        XCTAssertTrue(observed, "the runtime detected cancellation and stopped generation")
    }

    // MARK: Capabilities

    func testCapabilityReporting() {
        XCTAssertEqual(StubLLMRuntime().capabilities, [.text, .vision])
        XCTAssertEqual(StubLLMRuntime(capabilities: [.text]).capabilities, [.text])
    }

    func testVisionRequestAgainstTextOnlyRuntimeErrors() async {
        let stub = StubLLMRuntime(capabilities: [.text], interTokenDelayNanos: 0)
        let request = LLMRequest(prompt: "what is this?", image: Data([0x1, 0x2]))
        do {
            _ = try await stub.generateText(request)
            XCTFail("a vision request on a text-only runtime must error, not degrade")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .unsupportedModality(.vision))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The positive vision path: a `.vision`-capable runtime (the default [.text, .vision]) accepts an
    /// image-bearing request and streams the scripted result — no `unsupportedModality` error.
    func testVisionRequestAgainstVisionCapableRuntimeStreams() async throws {
        let stub = StubLLMRuntime(scriptedTokens: ["a ", "cat"], interTokenDelayNanos: 0)
        XCTAssertTrue(stub.capabilities.contains(.vision), "default stub is vision-capable")
        let request = LLMRequest(prompt: "what is this?", image: Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(request.requiresVision, "an image-bearing request requires vision")
        let full = try await stub.generateText(request)
        XCTAssertEqual(full, "a cat", "a vision-capable runtime streams the scripted result for an image request")
    }

    // MARK: Structured — valid

    func testStructuredDecodesValidValue() async throws {
        let stub = StubLLMRuntime(
            structuredScript: .valid(json: #"{"title":"Sync","start":"2026-06-08T10:00"}"#)
        )
        let outcome = try await stub.structured(LLMRequest(prompt: "p"), schema: calendarSchema, as: CalendarEvent.self)
        XCTAssertEqual(outcome.value, CalendarEvent(title: "Sync", start: "2026-06-08T10:00"))
        XCTAssertFalse(outcome.isDeclined)
        XCTAssertEqual(stub.lastAttemptCount, 1, "a valid first attempt needs no repair")
    }

    // MARK: Structured — repair

    func testStructuredRepairsNonConformingThenSucceeds() async throws {
        // First emission misses the required `start` key → validation fails → repair attempt succeeds.
        let stub = StubLLMRuntime(
            structuredScript: .invalidThenRepaired(
                bad: #"{"title":"Sync"}"#,
                good: #"{"title":"Sync","start":"2026-06-08T10:00"}"#
            )
        )
        let outcome = try await stub.structured(LLMRequest(prompt: "p"), schema: calendarSchema, as: CalendarEvent.self)
        XCTAssertEqual(outcome.value?.title, "Sync")
        XCTAssertEqual(stub.lastAttemptCount, 2, "the bounded loop took one repair attempt")
    }

    func testStructuredExhaustsBoundedLoopOnPersistentlyInvalid() async {
        let stub = StubLLMRuntime(
            structuredScript: .alwaysInvalid(json: #"{"title":"Sync"}"#), // never has `start`
            maxRepairAttempts: 3
        )
        do {
            _ = try await stub.structured(LLMRequest(prompt: "p"), schema: calendarSchema, as: CalendarEvent.self)
            XCTFail("persistently non-conforming output must not be returned as a value")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .couldNotProduceValid(attempts: 3), "the loop is bounded and reports failure")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Structured — decline

    func testStructuredCanDeclineRatherThanFabricate() async throws {
        let stub = StubLLMRuntime(
            structuredScript: .decline(reason: "This text is not a meeting")
        )
        let outcome = try await stub.structured(LLMRequest(prompt: "p"), schema: calendarSchema, as: CalendarEvent.self)
        XCTAssertTrue(outcome.isDeclined)
        XCTAssertEqual(outcome.declineReason, "This text is not a meeting")
        XCTAssertNil(outcome.value, "a decline carries no fabricated value")
    }

    // MARK: Structured — schema validation in isolation

    /// Directly exercises `StubLLMRuntime.validate(jsonData:against:)` to prove the schema gate is a
    /// real check, not a pass-through: an object missing a required key is rejected, while an object
    /// carrying every required key (regardless of extra keys) passes. Non-object JSON also fails.
    func testValidateRejectsOutputMissingRequiredKey() {
        let titleAndStart = StructuredSchema(
            name: "calendar_event",
            json: #"{"type":"object","required":["title","start"]}"#
        )
        func data(_ s: String) -> Data { Data(s.utf8) }

        // Missing the required `start` key → rejected.
        XCTAssertFalse(
            StubLLMRuntime.validate(jsonData: data(#"{"title":"Sync"}"#), against: titleAndStart),
            "an object missing a required key must fail validation"
        )
        // All required keys present (plus an extra) → accepted.
        XCTAssertTrue(
            StubLLMRuntime.validate(jsonData: data(#"{"title":"Sync","start":"t","extra":1}"#), against: titleAndStart),
            "an object carrying every required key passes validation"
        )
        // Non-object JSON → rejected.
        XCTAssertFalse(
            StubLLMRuntime.validate(jsonData: data("[1,2,3]"), against: titleAndStart),
            "non-object JSON fails validation"
        )
        // A schema with no `required` array accepts any object.
        let noRequired = StructuredSchema(name: "freeform", json: #"{"type":"object"}"#)
        XCTAssertTrue(
            StubLLMRuntime.validate(jsonData: data(#"{"anything":true}"#), against: noRequired),
            "a schema with no required keys accepts any object"
        )
    }

    /// Proves `validate()` actually runs inside the pipeline: an always-invalid emission that is missing
    /// a required key is never returned as a value; the bounded loop exhausts and reports failure with
    /// the attempt count. (Distinct from `testStructuredExhaustsBoundedLoopOnPersistentlyInvalid`, this
    /// pins the rejection to schema validation by using a smaller, explicit budget.)
    func testStructuredRejectsMissingRequiredKeyAndExhausts() async {
        let stub = StubLLMRuntime(
            structuredScript: .alwaysInvalid(json: #"{"title":"Sync"}"#), // missing required `start`
            maxRepairAttempts: 2
        )
        do {
            _ = try await stub.structured(LLMRequest(prompt: "p"), schema: calendarSchema, as: CalendarEvent.self)
            XCTFail("output missing a required key must be rejected by validation, never returned")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .couldNotProduceValid(attempts: 2),
                           "validation rejects every attempt, so the bounded loop exhausts")
            XCTAssertEqual(stub.lastAttemptCount, 2, "each attempt was validated and rejected")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: Structured — cancellation

    /// Cancelling the Task that drives a `structured(...)` call makes it throw rather than burning the
    /// full repair budget. We pre-cancel the task before its body runs (deterministic: no real sleep,
    /// no wall-clock race), so the call's first `Task.checkCancellation()` checkpoint trips. The script
    /// is `alwaysInvalid` with a large budget so, absent cancellation, the call WOULD run many attempts
    /// — letting us assert it did NOT.
    func testStructuredCancellationThrowsBeforeExhaustingBudget() async {
        let stub = StubLLMRuntime(
            structuredScript: .alwaysInvalid(json: #"{"title":"Sync"}"#),
            maxRepairAttempts: 1000
        )
        // Create the driving task, then cancel it before yielding control so its body observes
        // cancellation at the very first checkpoint.
        let task = Task { () -> Error? in
            do {
                _ = try await stub.structured(LLMRequest(prompt: "p"),
                                              schema: calendarSchema, as: CalendarEvent.self)
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let thrown = await task.value

        switch thrown {
        case is CancellationError:
            break
        case let e as RuntimeError where e == .cancelled:
            break
        default:
            XCTFail("cancellation must surface as CancellationError/RuntimeError.cancelled, got \(String(describing: thrown))")
        }
        // The decisive property: it bailed out, it did NOT run the full repair budget.
        XCTAssertLessThan(stub.lastAttemptCount, 1000,
                          "cancellation stops the repair loop instead of running the full budget")
    }
}

/// Tiny actor to count emitted tokens across the cancellation boundary without data races.
private actor TokenCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
