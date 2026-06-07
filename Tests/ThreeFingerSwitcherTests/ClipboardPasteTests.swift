import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests the pure paste-decision logic (`LaunchService.pasteboardWrites`): the representations chosen
/// for a re-paste per kind, and that unmaterialized / empty entries produce no harmful writes.
final class ClipboardPasteTests: XCTestCase {

    private func textEntry() -> ClipboardEntry {
        ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .text, key: "hi",
                       representations: [ClipboardUTI.plainText: .inline(Data("hi".utf8))],
                       fingerprint: "text:hi")
    }

    func testTextEntryWritesPlainText() {
        let writes = LaunchService.pasteboardWrites(for: textEntry())
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.uti, ClipboardUTI.plainText)
        XCTAssertEqual(writes.first?.data, Data("hi".utf8))
    }

    func testRichTextWritesBothRepresentations() {
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .richText, key: "styled",
                                   representations: [
                                       ClipboardUTI.rtf: .inline(Data("{\\rtf1}".utf8)),
                                       ClipboardUTI.plainText: .inline(Data("styled".utf8))
                                   ],
                                   fingerprint: "rich:1")
        let writes = LaunchService.pasteboardWrites(for: entry)
        let utis = Set(writes.map(\.uti))
        XCTAssertEqual(utis, [ClipboardUTI.rtf, ClipboardUTI.plainText])
    }

    func testUnmaterializedBlobIsSkipped() {
        // A blob payload that wasn't materialized has no inline bytes — it must not be written.
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .image, key: "Image 1×1",
                                   representations: [ClipboardUTI.png: .blob("missing.bin")],
                                   fingerprint: "image:1")
        XCTAssertTrue(LaunchService.pasteboardWrites(for: entry).isEmpty,
                      "an unresolved blob produces no pasteboard write (no harmful/garbled paste)")
    }

    func testEmptyEntryProducesNoWrites() {
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .text, key: "",
                                   representations: [:], fingerprint: "empty")
        XCTAssertTrue(LaunchService.pasteboardWrites(for: entry).isEmpty)
    }

    func testFileEntryWritesFileURLAndPathFallback() {
        // The file-url is kept (Finder pastes the file) AND a plain-text POSIX path is added so a text
        // field pastes the path.
        let url = "file:///Users/me/foo%20bar.zip"
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .file, key: "foo bar.zip",
                                   representations: [ClipboardUTI.fileURL: .inline(Data(url.utf8))],
                                   fingerprint: "file:/Users/me/foo bar.zip")
        let writes = LaunchService.pasteboardWrites(for: entry)
        let map = Dictionary(uniqueKeysWithValues: writes.map { ($0.uti, $0.data) })
        XCTAssertNotNil(map[ClipboardUTI.fileURL], "file-url kept for Finder/IDE")
        XCTAssertEqual(map[ClipboardUTI.plainText].flatMap { String(data: $0, encoding: .utf8) },
                       "/Users/me/foo bar.zip", "decoded POSIX path as text fallback")
    }

    func testFolderPathFallback() {
        let url = "file:///Users/me/Documents/"
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .file, key: "Documents",
                                   representations: [ClipboardUTI.fileURL: .inline(Data(url.utf8))],
                                   fingerprint: "file:/Users/me/Documents")
        XCTAssertEqual(LaunchService.plainTextFallback(for: entry), "/Users/me/Documents")
    }

    func testURLFallbackWhenNoPlainText() {
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .url, key: "https://x.com",
                                   representations: [ClipboardUTI.url: .inline(Data("https://x.com".utf8))],
                                   fingerprint: "url:https://x.com")
        let writes = LaunchService.pasteboardWrites(for: entry)
        XCTAssertTrue(writes.contains { $0.uti == ClipboardUTI.plainText &&
            String(data: $0.data, encoding: .utf8) == "https://x.com" })
    }

    func testTextEntryGetsNoDuplicateFallback() {
        let writes = LaunchService.pasteboardWrites(for: textEntry())
        XCTAssertEqual(writes.filter { $0.uti == ClipboardUTI.plainText }.count, 1,
                       "an entry that already has plain text gets no duplicate fallback")
    }

    func testImageHasNoTextFallback() {
        let entry = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 0), kind: .image, key: "Image 2×2",
                                   representations: [ClipboardUTI.png: .inline(Data([1, 2, 3]))],
                                   fingerprint: "image:1")
        XCTAssertNil(LaunchService.plainTextFallback(for: entry))
    }
}
