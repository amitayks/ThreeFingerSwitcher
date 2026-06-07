import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure capture decisions: concealed/transient skipping, app-exclusion, and
/// kind classification from available UTIs. No live pasteboard.
final class ClipboardCaptureTests: XCTestCase {

    // MARK: Concealed / transient

    func testConcealedTypeIsSkipped() {
        XCTAssertTrue(ClipboardCapture.isConcealed(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardCapture.isConcealed(types: ["org.nspasteboard.TransientType"]))
    }

    func testOrdinaryTypesAreNotConcealed() {
        XCTAssertFalse(ClipboardCapture.isConcealed(types: ["public.utf8-plain-text", "public.rtf"]))
    }

    // MARK: Exclusion list

    func testExcludedAppIsNotRecorded() {
        XCTAssertFalse(ClipboardCapture.shouldRecord(sourceBundleID: "com.agilebits.onepassword7",
                                                     excluded: ["com.agilebits.onepassword7"]))
    }

    func testNonExcludedAppIsRecorded() {
        XCTAssertTrue(ClipboardCapture.shouldRecord(sourceBundleID: "com.apple.Safari",
                                                    excluded: ["com.agilebits.onepassword7"]))
    }

    func testUnknownSourceIsRecorded() {
        XCTAssertTrue(ClipboardCapture.shouldRecord(sourceBundleID: nil, excluded: ["x"]))
    }

    // MARK: Classification priority

    func testFileWinsOverImage() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.fileURL, ClipboardUTI.tiff]), .file)
    }

    func testImageClassification() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.png]), .image)
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.tiff]), .image)
    }

    func testRichTextBeatsPlain() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.rtf, ClipboardUTI.plainText]), .richText)
    }

    func testURLBeatsPlain() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.url, ClipboardUTI.plainText]), .url)
    }

    func testPlainTextClassification() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.plainText]), .text)
    }

    func testColorClassification() {
        XCTAssertEqual(ClipboardCapture.classify(types: [ClipboardUTI.color]), .color)
    }

    func testNothingRecordable() {
        XCTAssertNil(ClipboardCapture.classify(types: ["com.unknown.weird"]))
    }

    // MARK: Key derivation

    func testKeyFromTextUsesFirstNonEmptyLineAndTruncates() {
        XCTAssertEqual(ClipboardKey.fromText("\n  \nhello world\nsecond"), "hello world")
        let long = String(repeating: "a", count: 200)
        let key = ClipboardKey.fromText(long, maxLength: 10)
        XCTAssertEqual(key, String(repeating: "a", count: 10) + "…")
    }

    func testKeyFromFileUsesLastComponent() {
        XCTAssertEqual(ClipboardKey.fromFile(URL(fileURLWithPath: "/tmp/foo/bar.zip")), "bar.zip")
    }

    func testKeyFromImageShowsDimensions() {
        XCTAssertEqual(ClipboardKey.fromImage(width: 1280, height: 800), "Image 1280×800")
    }
}
