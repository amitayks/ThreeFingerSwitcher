import XCTest
import SwiftUI
@testable import ThreeFingerSwitcherCore

/// Tests for the preview canvas's bidi base-direction heuristic (spec launcher-overlay: "Bidirectional
/// (RTL/LTR) text rendering"). Each line's base direction is decided by its **first strong character**
/// (the first word/char), is **stable** once that char is present (later content never re-decides it),
/// and RTL detection covers **all** RTL scripts. The heuristic is pure; the actual right-aligned
/// `NSTextView` rendering is confirmed on a signed build.
final class BidiTextDirectionTests: XCTestCase {

    // Sample strong characters (kept as scalars so the source stays ASCII-safe and unambiguous).
    private let hebrew = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"         // שלום
    private let hebrewWord = "\u{05DE}\u{05D9}\u{05DC}\u{05D4}"     // מילה
    private let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}" // مرحبا
    private let syriac = "\u{0710}\u{0712}\u{0713}\u{0714}"         // Syriac
    private let thaana = "\u{0780}\u{0781}\u{0782}\u{0783}"         // Thaana
    private let nko = "\u{07C1}\u{07C2}\u{07C3}\u{07C4}"            // N'Ko

    // MARK: - First strong char decides the line

    func testFirstStrongCharDecidesTheLine() {
        XCTAssertEqual(firstStrongDirection(hebrew), .rightToLeft, "a Hebrew-first line is right-to-left")
        XCTAssertEqual(firstStrongDirection("Hello " + hebrew), .leftToRight,
                       "a line that STARTS with Latin is left-to-right (the first word decides)")
        XCTAssertEqual(firstStrongDirection(hebrew + " Hello"), .rightToLeft,
                       "a line that starts with Hebrew is right-to-left even with trailing Latin")
    }

    func testLeadingNeutralsAreSkippedToTheFirstStrongChar() {
        XCTAssertEqual(firstStrongDirection("  \t " + hebrew), .rightToLeft, "leading whitespace is skipped")
        XCTAssertEqual(firstStrongDirection("3. " + hebrew), .rightToLeft, "a leading number/period is skipped")
        XCTAssertEqual(firstStrongDirection("- " + arabic), .rightToLeft, "a leading bullet marker is skipped")
        XCTAssertEqual(firstStrongDirection("\u{2022} " + hebrew), .rightToLeft, "a leading bullet glyph is skipped")
    }

    // MARK: - STABLE: later characters never re-decide the side

    func testDirectionIsStableAsMoreContentIsAppended() {
        // Once the first strong char is present, appending opposite-direction content does NOT flip it —
        // the line's alignment is fixed by how it starts (the user's rule).
        XCTAssertEqual(firstStrongDirection(hebrew), .rightToLeft)
        XCTAssertEqual(firstStrongDirection(hebrew + " hello world foo bar baz qux"), .rightToLeft,
                       "a Hebrew-first line stays RTL no matter how much Latin follows")
        XCTAssertEqual(firstStrongDirection("Hi"), .leftToRight)
        XCTAssertEqual(firstStrongDirection("Hi " + hebrew + hebrew + hebrew + hebrew), .leftToRight,
                       "a Latin-first line stays LTR no matter how much Hebrew follows")
    }

    func testStreamingOnlyAdoptsASideOnceTheFirstStrongCharArrives() {
        // A paragraph that streams neutrals first is LTR (default) until its first strong char arrives,
        // then locks to that side and stays there.
        XCTAssertEqual(firstStrongDirection(""), .leftToRight, "empty ⇒ LTR default")
        XCTAssertEqual(firstStrongDirection("- "), .leftToRight, "neutral-only prefix ⇒ LTR default")
        XCTAssertEqual(firstStrongDirection("- " + hebrew), .rightToLeft, "adopts RTL when the first strong char arrives")
        XCTAssertEqual(firstStrongDirection("- " + hebrew + " and more"), .rightToLeft, "then stays RTL")
    }

    // MARK: - Neutral-only ⇒ LTR

    func testNeutralOnlyIsLeftToRight() {
        XCTAssertEqual(firstStrongDirection("   \n\t  "), .leftToRight, "whitespace-only ⇒ LTR")
        XCTAssertEqual(firstStrongDirection("123 456-789 (00%)"), .leftToRight, "digits/punctuation only ⇒ LTR")
        XCTAssertEqual(firstStrongDirection("https://example.com/path?q=1"), .leftToRight, "a bare URL ⇒ LTR")
    }

    // MARK: - All RTL scripts, not just Hebrew/Arabic

    func testAllRTLScriptsResolveRTL() {
        XCTAssertEqual(firstStrongDirection(arabic), .rightToLeft, "Arabic is RTL")
        XCTAssertEqual(firstStrongDirection(syriac), .rightToLeft, "Syriac is RTL")
        XCTAssertEqual(firstStrongDirection(thaana), .rightToLeft, "Thaana is RTL")
        XCTAssertEqual(firstStrongDirection(nko), .rightToLeft, "N'Ko is RTL")
    }

    // MARK: - Strong-class helpers (regression guard: Hebrew letters are alphabetic — must not count LTR)

    func testStrongClassHelpers() {
        let alef: UInt32 = 0x05D0   // א
        XCTAssertTrue(isStrongRTL(alef), "a Hebrew letter is strong RTL")
        XCTAssertFalse(isStrongLTR(alef), "a Hebrew letter must NOT also count as strong LTR (it is alphabetic)")
        let a: UInt32 = 0x0041      // A
        XCTAssertTrue(isStrongLTR(a))
        XCTAssertFalse(isStrongRTL(a))
        for neutral: UInt32 in [0x0033 /* 3 */, 0x0020 /* space */, 0x002E /* . */, 0x002D /* - */] {
            XCTAssertFalse(isStrongLTR(neutral), "\(neutral) is neutral, not strong LTR")
            XCTAssertFalse(isStrongRTL(neutral), "\(neutral) is neutral, not strong RTL")
        }
    }
}
