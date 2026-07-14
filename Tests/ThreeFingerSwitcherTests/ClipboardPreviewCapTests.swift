import XCTest
@testable import ThreeFingerSwitcherCore

/// The clipboard value preview must render a hard-bounded string so a large or many-line item can never
/// drive an unbounded TextKit layout (the 1000+-line freeze). Covers `ClipboardValueView.capForPreview`.
final class ClipboardPreviewCapTests: XCTestCase {

    func testManyShortLinesCappedByLineCount() {
        // ~1400 short lines is a small byte size but a huge line count — the reported freeze case.
        let raw = (1...1400).map { "line \($0)" }.joined(separator: "\n")
        let out = ClipboardValueView.capForPreview(raw, maxChars: 8_000, maxLines: 200)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.text.split(separator: "\n", omittingEmptySubsequences: false).count, 200)
        XCTAssertLessThanOrEqual(out.text.count, 8_000)
    }

    func testHugeSingleLineCappedByChars() {
        let out = ClipboardValueView.capForPreview(String(repeating: "x", count: 500_000),
                                                   maxChars: 8_000, maxLines: 200)
        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.text.count, 8_000)
    }

    func testSmallTextIsUnchanged() {
        let out = ClipboardValueView.capForPreview("one\ntwo\nthree", maxChars: 8_000, maxLines: 200)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.text, "one\ntwo\nthree")
    }

    func testExactlyMaxLinesIsNotTruncated() {
        let raw = (1...200).map { "l\($0)" }.joined(separator: "\n")
        let out = ClipboardValueView.capForPreview(raw, maxChars: 100_000, maxLines: 200)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.text, raw)
    }
}
