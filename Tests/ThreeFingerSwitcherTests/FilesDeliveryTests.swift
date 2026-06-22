import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure delivery-payload builder (`Files/FilesDelivery.swift`) — the dual-representation
/// payload that `files-contextual-delivery` writes so a text target receives the path and Finder receives
/// the file.
final class FilesDeliveryTests: XCTestCase {

    func testPayloadCarriesBothRepresentations() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/Users/me/notes.txt"), name: "notes.txt",
                              isDirectory: false, modificationDate: nil, kind: .text)
        let payload = FilesDelivery.payload(for: entry)
        XCTAssertEqual(payload.url, URL(fileURLWithPath: "/Users/me/notes.txt").standardizedFileURL,
                       "the file reference is present for Finder")
        XCTAssertEqual(payload.path, "/Users/me/notes.txt", "the path string is present for text targets")
    }

    func testPayloadPathIsStandardized() {
        // A non-standard path (a trailing component that standardizes away) is canonicalized.
        let raw = URL(fileURLWithPath: "/Users/me/sub/../notes.txt")
        let entry = FileEntry(url: raw, name: "notes.txt", isDirectory: false, modificationDate: nil, kind: .text)
        let payload = FilesDelivery.payload(for: entry)
        XCTAssertEqual(payload.path, "/Users/me/notes.txt", "the delivered path is the standardized absolute path")
        XCTAssertEqual(payload.path, entry.id, "and equals the entry's stable id")
    }

    func testFolderPayload() {
        let entry = FileEntry(url: URL(fileURLWithPath: "/tmp/dir"), name: "dir",
                              isDirectory: true, modificationDate: nil, kind: .folder)
        let payload = FilesDelivery.payload(for: entry)
        XCTAssertEqual(payload.path, "/tmp/dir")
        XCTAssertTrue(payload.url.isFileURL)
    }
}
