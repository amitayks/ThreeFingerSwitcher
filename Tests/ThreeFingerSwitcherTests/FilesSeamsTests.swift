import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests for the two Files-band foundation types (change: files-band, tasks 2.1 / 3.1):
/// `FileEntry` (a path-stable, ephemeral value type), the `FileWorkspace` seam (proven conformable by a
/// pure-Foundation stub, no AppKit), and the `FileActionError` taxonomy (clean per-case headlines, raw
/// error text only on the side, never on the headline).
final class FilesSeamsTests: XCTestCase {

    // MARK: - FileEntry: stable, path-derived identity

    func testIDIsTheStandardizedAbsolutePath() {
        let url = URL(fileURLWithPath: "/Users/x/Documents/report.pdf")
        let entry = FileEntry(url: url, name: "report.pdf", isDirectory: false,
                              modificationDate: nil, kind: .pdf)
        XCTAssertEqual(entry.id, "/Users/x/Documents/report.pdf")
        XCTAssertEqual(entry.id, entry.path)
    }

    func testRelistingTheSamePathYieldsTheSameID() {
        // Re-listing the same folder (on re-entry, or because a file changed) must keep the SAME id so the
        // selection highlight has a stable target and never strobes — the core reason the id is path-derived.
        let url = URL(fileURLWithPath: "/tmp/files-band/a.txt")
        let first = FileEntry(url: url, name: "a.txt", isDirectory: false,
                              modificationDate: Date(timeIntervalSince1970: 0), kind: .text)
        let relistedSamePathNewModDate = FileEntry(url: url, name: "a.txt", isDirectory: false,
                                                   modificationDate: Date(timeIntervalSince1970: 999),
                                                   kind: .text)
        XCTAssertEqual(first.id, relistedSamePathNewModDate.id)
    }

    func testEqualPathsButDifferentMetadataAreNotEqualButShareIdentity() {
        let url = URL(fileURLWithPath: "/tmp/files-band/a.txt")
        let a = FileEntry(url: url, name: "a.txt", isDirectory: false,
                          modificationDate: Date(timeIntervalSince1970: 0), kind: .text)
        let b = FileEntry(url: url, name: "a.txt", isDirectory: false,
                          modificationDate: Date(timeIntervalSince1970: 1), kind: .text)
        // Same identity (path) but not value-equal (the mod date differs) — exactly what keeps the SwiftUI
        // row stable while still letting the view notice a metadata change.
        XCTAssertEqual(a.id, b.id)
        XCTAssertNotEqual(a, b)
    }

    func testStandardizationCollapsesRelativeComponents() {
        let messy = URL(fileURLWithPath: "/Users/x/Documents/../Documents/./report.pdf")
        let entry = FileEntry(url: messy, name: "report.pdf", isDirectory: false,
                              modificationDate: nil, kind: .pdf)
        XCTAssertEqual(entry.id, "/Users/x/Documents/report.pdf")
        XCTAssertEqual(entry.url.path, "/Users/x/Documents/report.pdf")
    }

    func testDirectoryFlagAndKindArePreserved() {
        let dir = FileEntry(url: URL(fileURLWithPath: "/Users/x/Projects"), name: "Projects",
                            isDirectory: true, modificationDate: nil, kind: .folder)
        XCTAssertTrue(dir.isDirectory)
        XCTAssertEqual(dir.kind, .folder)
        XCTAssertEqual(dir.name, "Projects")
    }

    // MARK: - FileWorkspace: the seam is conformable without AppKit

    func testStubConformsAndRecordsDefaultOpen() async throws {
        let workspace = RecordingFileWorkspace()
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        try await workspace.open(url)
        XCTAssertEqual(workspace.openedDefault, [url])
    }

    func testStubRecordsOpenWith() async throws {
        let workspace = RecordingFileWorkspace()
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app")
        try await workspace.open(url, withApplicationAt: app)
        XCTAssertEqual(workspace.openedWith.count, 1)
        XCTAssertEqual(workspace.openedWith.first?.file, url)
        XCTAssertEqual(workspace.openedWith.first?.app, app)
    }

    func testStubSurfacesAssociationQueries() {
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app")
        let workspace = RecordingFileWorkspace(apps: [app], defaultApp: app)
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(workspace.urlsForApplications(toOpen: url), [app])
        XCTAssertEqual(workspace.urlForApplication(toOpen: url), app)
    }

    func testStubOpenCanThrowAFileActionError() async {
        let workspace = RecordingFileWorkspace(openError: .openFailed(name: "a.txt", details: nil))
        do {
            try await workspace.open(URL(fileURLWithPath: "/tmp/a.txt"))
            XCTFail("expected the stub to throw")
        } catch let error as FileActionError {
            XCTAssertEqual(error, .openFailed(name: "a.txt", details: nil))
        } catch {
            XCTFail("expected a FileActionError, got \(error)")
        }
    }

    // MARK: - FileActionError: clean, per-case headlines

    /// A headline must read as a human sentence — never a reflected enum dump or raw OS text.
    private func assertHeadlineIsClean(_ error: FileActionError,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let headline = error.errorDescription
        XCTAssertNotNil(headline, "every case is self-describing", file: file, line: line)
        let h = headline ?? ""
        XCTAssertFalse(h.isEmpty, "headline is non-empty", file: file, line: line)
        for needle in ["Domain=", "Code=", "Error Domain", "UserInfo", "FileActionError"] {
            XCTAssertFalse(h.contains(needle),
                           "headline must not contain raw error text (\(needle)): \(h)",
                           file: file, line: line)
        }
    }

    func testEveryCaseHasACleanHeadline() {
        assertHeadlineIsClean(.folderUnreadable(name: "Secret", details: nil))
        assertHeadlineIsClean(.openFailed(name: "report.pdf", details: nil))
        assertHeadlineIsClean(.noApplicationForFile(name: "thing.weird"))
    }

    func testHeadlineNamesTheFileButNotTheRawDetails() {
        let rawDetails = "Error Domain=CocoaErrorDomain Code=257 \"You don't have permission.\""
        let error = FileActionError.openFailed(name: "report.pdf", details: rawDetails)
        let headline = error.errorDescription ?? ""
        XCTAssertTrue(headline.contains("report.pdf"))
        // The raw OS text rides on the side payload, NOT the headline.
        XCTAssertFalse(headline.contains("CocoaErrorDomain"))
        XCTAssertFalse(headline.contains("Code=257"))
        // ...but it IS available for an opt-in disclosure / log.
        XCTAssertEqual(error.copyableDetails, rawDetails)
    }

    func testNoApplicationCaseCarriesNoDetails() {
        XCTAssertNil(FileActionError.noApplicationForFile(name: "x").copyableDetails)
    }

    func testFolderUnreadableExposesDetails() {
        let error = FileActionError.folderUnreadable(name: "Secret",
                                                     details: "Error Domain=NSCocoaErrorDomain Code=257")
        XCTAssertEqual(error.copyableDetails, "Error Domain=NSCocoaErrorDomain Code=257")
    }
}

// MARK: - Test stub (Foundation-only — proves `FileWorkspace` conforms without AppKit)

/// A pure-Foundation `FileWorkspace` for tests: records opens and returns canned associations. Its mere
/// existence (no `import AppKit`) demonstrates the seam is dependency-light enough to stub. `fileprivate`
/// so it never collides with the open-service agent's own stub.
private final class RecordingFileWorkspace: FileWorkspace {
    private(set) var openedDefault: [URL] = []
    private(set) var openedWith: [(file: URL, app: URL)] = []
    private let apps: [URL]
    private let defaultApp: URL?
    private let openError: FileActionError?

    init(apps: [URL] = [], defaultApp: URL? = nil, openError: FileActionError? = nil) {
        self.apps = apps
        self.defaultApp = defaultApp
        self.openError = openError
    }

    func open(_ url: URL) async throws {
        if let openError { throw openError }
        openedDefault.append(url)
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
        if let openError { throw openError }
        openedWith.append((file: url, app: applicationURL))
    }

    func urlsForApplications(toOpen url: URL) -> [URL] { apps }

    func urlForApplication(toOpen url: URL) -> URL? { defaultApp }
}
