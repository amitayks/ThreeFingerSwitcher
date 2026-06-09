import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests for the AI error taxonomy + the single central translator (change: harden-ai-error-handling):
/// the classifier over synthetic `NSError`s (offline / dropped / 5xx / auth) and over the app's own
/// `RuntimeError` / `TaskError`, asserting (a) a clean per-case headline, (b) the raw text rides on
/// `details` and NEVER on the headline, and (c) `RuntimeError` is self-describing for every case.
final class AIErrorTests: XCTestCase {

    /// A headline must read as a human sentence — never a reflected `NSError`/enum dump.
    private func assertHeadlineIsClean(_ presented: AIPresentedError,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(presented.headline.isEmpty, "headline is non-empty", file: file, line: line)
        for needle in ["Domain=", "Code=", "Error Domain", "UserInfo"] {
            XCTAssertFalse(presented.headline.contains(needle),
                           "headline must not contain raw error text (\(needle)): \(presented.headline)",
                           file: file, line: line)
        }
    }

    // MARK: - 7.1 vendor/OS classifier over synthetic NSErrors

    func testOfflineNotConnectedMapsToConnectivityHeadline() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) // -1009
        let presented = AIError.message(for: ns)
        assertHeadlineIsClean(presented)
        XCTAssertEqual(presented.headline, RuntimeError.offline.errorDescription)
        XCTAssertNotNil(presented.details)
        XCTAssertTrue(presented.details?.contains("-1009") ?? false,
                      "the raw NSError text is preserved as opt-in details")
    }

    func testDroppedConnectionMapsToOffline() {
        let ns = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost) // -1005
        XCTAssertEqual(AIError.message(for: ns).headline, RuntimeError.offline.errorDescription)
    }

    func testServerError5xxMapsToServerUnavailable() {
        let ns = NSError(domain: "HTTPTransport", code: 503)
        let presented = AIError.message(for: ns)
        assertHeadlineIsClean(presented)
        XCTAssertEqual(presented.headline, RuntimeError.serverUnavailable.errorDescription)
    }

    func testHTTP401_403_404MapToAccessDenied() {
        for code in [401, 403, 404] {
            let ns = NSError(domain: "HTTPTransport", code: code)
            XCTAssertEqual(AIError.message(for: ns).headline,
                           RuntimeError.authOrAccessDenied.errorDescription,
                           "HTTP \(code) → access denied")
        }
    }

    func testUnknownErrorFallsBackToGenericHeadlineWithRawDetails() {
        struct Weird: Error { let secret = "raw-internal-1234" }
        let presented = AIError.message(for: Weird())
        XCTAssertEqual(presented.headline, AIError.unknownHeadline, "unknown → safe generic headline")
        XCTAssertTrue(presented.details?.contains("Weird") ?? false,
                      "the raw description is preserved as details, never in the headline")
        assertHeadlineIsClean(presented)
    }

    // MARK: - 7.1 app taxonomy → its own clean description

    func testRuntimeErrorUsesItsLocalizedDescriptionAsHeadline() {
        let presented = AIError.message(for: RuntimeError.modelMissing)
        XCTAssertEqual(presented.headline, "The model is not downloaded yet.")
    }

    func testModelLoadFailedCarriesDetailNotHeadline() {
        let presented = AIError.message(for: RuntimeError.modelLoadFailed(detail: "MLX abort 0xDEAD"))
        XCTAssertEqual(presented.headline, "The model could not be loaded.")
        XCTAssertEqual(presented.details, "MLX abort 0xDEAD",
                       "the diagnostic detail is carried as details, kept off the headline")
        XCTAssertFalse(presented.headline.contains("0xDEAD"), "raw detail never appears in the headline")
    }

    func testTaskErrorUsesItsLocalizedDescriptionAsHeadline() {
        let presented = AIError.message(for: TaskError.calendarPermissionDenied)
        XCTAssertEqual(presented.headline, TaskError.calendarPermissionDenied.errorDescription)
        XCTAssertTrue(presented.headline.contains("Calendar"))
        XCTAssertNotEqual(presented.headline, "calendarPermissionDenied", "not the raw enum case name")
    }

    func testCancellationGetsBenignHeadline() {
        let presented = AIError.message(for: CancellationError())
        XCTAssertEqual(presented.headline, RuntimeError.cancelled.errorDescription)
    }

    // MARK: - 7.2 RuntimeError: LocalizedError — every case is self-describing

    func testEveryRuntimeErrorCaseHasNonEmptyDescription() {
        let cases: [RuntimeError] = [
            .unavailable(reason: "no hw"), .modelMissing, .integrityFailed, .cancelled,
            .couldNotProduceValid(attempts: 3), .decodeFailed(detail: "x"), .unsupportedModality(.vision),
            .offline, .serverUnavailable, .authOrAccessDenied, .modelLoadFailed(detail: nil)
        ]
        for c in cases {
            let description = c.errorDescription
            XCTAssertNotNil(description, "\(c) has a localized description")
            XCTAssertFalse(description?.isEmpty ?? true, "\(c) has a non-empty description")
        }
    }

    func testOfflineDescriptionIsAConnectivityHint() {
        let description = (RuntimeError.offline.errorDescription ?? "").lowercased()
        XCTAssertTrue(description.contains("internet") || description.contains("connection"),
                      "the offline message hints at connectivity, got: \(description)")
    }

    func testDecodeFailedHeadlineDropsRawDetail() {
        // The decode detail (which can carry a raw decoder error) must not leak into the headline.
        let description = RuntimeError.decodeFailed(detail: "keyNotFound rawDump").errorDescription ?? ""
        XCTAssertFalse(description.contains("rawDump"), "the raw decode detail is kept off the headline")
    }

    // MARK: - HTTP-status classifier shared with the runtime boundary

    func testHTTPStatusClassifierMatchesTaxonomy() {
        XCTAssertEqual(AIError.runtimeError(forHTTPStatus: 403), .authOrAccessDenied)
        XCTAssertEqual(AIError.runtimeError(forHTTPStatus: 500), .serverUnavailable)
        XCTAssertNil(AIError.runtimeError(forHTTPStatus: 200), "a 2xx is not a failure to classify")
        XCTAssertNil(AIError.runtimeError(forHTTPStatus: 0))
    }
}
