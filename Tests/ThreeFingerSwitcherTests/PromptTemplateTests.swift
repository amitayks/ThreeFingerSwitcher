import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for prompt template resolution (spec: "Prompt template token resolution"): {input}/{app}/
/// {url} substitution, missing-token degradation to empty (never fail), and unknown-token passthrough.
final class PromptTemplateTests: XCTestCase {

    func testInputTokenIsSubstituted() {
        let context = FireContext(inputText: "teh quick brown fox")
        let resolved = PromptTemplate.resolve("Fix the grammar:\n{input}", with: context)
        XCTAssertEqual(resolved, "Fix the grammar:\nteh quick brown fox")
    }

    func testAppAndUrlTokensSubstitute() {
        let context = FireContext(capturedAppName: "Safari",
                                  inputText: "x",
                                  url: URL(string: "https://example.com/page"))
        let resolved = PromptTemplate.resolve("In {app} at {url}: {input}", with: context)
        XCTAssertEqual(resolved, "In Safari at https://example.com/page: x")
    }

    func testMissingUrlAndAppDegradeToEmptyString() {
        // No app name, no URL exposed → both resolve to "" and the command still runs (spec).
        let context = FireContext(capturedAppName: nil, inputText: "body", url: nil)
        let resolved = PromptTemplate.resolve("[{app}|{url}] {input}", with: context)
        XCTAssertEqual(resolved, "[|] body", "missing {app}/{url} degrade to empty, never fail")
    }

    func testEmptyInputDegradesToEmptyString() {
        let context = FireContext(inputText: nil)
        let resolved = PromptTemplate.resolve("Q: {input}", with: context)
        XCTAssertEqual(resolved, "Q: ")
    }

    func testUnknownTokenIsLeftUntouched() {
        let context = FireContext(inputText: "hi")
        let resolved = PromptTemplate.resolve("{input} {unknown} {foo}", with: context)
        XCTAssertEqual(resolved, "hi {unknown} {foo}",
                       "unknown tokens are passed through verbatim, not dropped")
    }

    func testUnknownTokenBeforeKnownTokenStillResolvesKnown() {
        let context = FireContext(inputText: "BODY")
        let resolved = PromptTemplate.resolve("{mystery} then {input}", with: context)
        XCTAssertEqual(resolved, "{mystery} then BODY")
    }

    func testDateTokenIsSubstituted() {
        // Pin a known date and a fixed format so the assertion is deterministic.
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let context = FireContext(date: date)
        let resolved = PromptTemplate.resolve("Today: {date}", with: context)

        let expected = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        XCTAssertEqual(resolved, "Today: \(expected)")
    }

    func testSubstitutedValueIsNotReinterpretedAsToken() {
        // If {input} contains text that looks like a token, it must NOT be re-substituted.
        let context = FireContext(capturedAppName: "Mail", inputText: "see {app}")
        let resolved = PromptTemplate.resolve("{input}", with: context)
        XCTAssertEqual(resolved, "see {app}",
                       "a substituted value is emitted literally, not re-scanned for tokens")
    }

    func testLoneBraceIsPreserved() {
        let context = FireContext(inputText: "x")
        let resolved = PromptTemplate.resolve("a { b {input}", with: context)
        XCTAssertEqual(resolved, "a { b x")
    }

    // MARK: - {lang} runtime-parameter token (spec: "Language token resolves to the active language")

    func testLangTokenSubstitutesActiveLanguage() {
        let context = FireContext(inputText: "hello")
        let resolved = PromptTemplate.resolve("Translate to {lang}:\n{input}", with: context,
                                              activeLanguage: "Hebrew")
        XCTAssertEqual(resolved, "Translate to Hebrew:\nhello")
    }

    func testLangTokenWithoutActiveLanguageDegradesToEmpty() {
        // A command with no language parameter passes activeLanguage == nil → {lang} resolves empty.
        let context = FireContext(inputText: "hello")
        let resolved = PromptTemplate.resolve("[{lang}] {input}", with: context)
        XCTAssertEqual(resolved, "[] hello", "{lang} with no active language degrades to empty, never fails")
    }
}
