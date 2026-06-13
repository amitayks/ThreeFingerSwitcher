import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests the synthetic **Files band** projection (change: files-band, tasks 4.1/4.2/5.1):
/// `FilesBandBuilder` turning a directory column's `[FileEntry]` into a `ContextBand` of `.fileEntry`
/// `LaunchItem`s. The load-bearing guarantee is **path-stable item identity** — a `LaunchItem.id` is a
/// `UUID` but a `FileEntry.id` is a path `String`, so the builder must derive a *deterministic* UUID from
/// the path or the selection highlight strobes on every re-list (design D2). Like the foundation tests,
/// this is AppKit-free and not `@MainActor` (the builder never touches `FileManager` or AppKit).
final class FilesBandBuilderTests: XCTestCase {

    // MARK: - Fixtures

    private func fileEntry(_ path: String, isDirectory: Bool = false, kind: FileKind = .other,
                           mod: Date? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                  isDirectory: isDirectory, modificationDate: mod, kind: kind)
    }

    // MARK: - Band shape & sentinel

    func testBuildCarriesTheSentinelNameAndIcon() {
        let band = FilesBandBuilder.build(currentColumn: [])
        XCTAssertEqual(band.id, FilesBandBuilder.bandID)
        XCTAssertEqual(band.name, "Files")
        XCTAssertEqual(band.icon, .sfSymbol("folder.fill"))
        XCTAssertTrue(band.items.isEmpty)
    }

    func testIsFilesBandMatchesOnlyTheSentinel() {
        XCTAssertTrue(FilesBandBuilder.isFilesBand(FilesBandBuilder.build(currentColumn: [])))
        // A band with any other id is not the Files band — including the other synthetic bands.
        XCTAssertFalse(FilesBandBuilder.isFilesBand(ContextBand(name: "x", color: FilesBandBuilder.color)))
        XCTAssertFalse(FilesBandBuilder.isFilesBand(ClipboardBandBuilder.build(from: [])))
        XCTAssertFalse(FilesBandBuilder.isFilesBand(AIBand.band(from: [])))
    }

    func testSentinelIsDistinctFromTheOtherSyntheticBands() {
        XCTAssertNotEqual(FilesBandBuilder.bandID, ClipboardBandBuilder.bandID)
        XCTAssertNotEqual(FilesBandBuilder.bandID, AIBand.bandID)
    }

    // MARK: - Entry → item mapping

    func testEachEntryBecomesAFileEntryItemPreservingOrderAndTitle() {
        let entries = [
            fileEntry("/Home/Docs", isDirectory: true, kind: .folder),
            fileEntry("/Home/photo.png", kind: .image),
            fileEntry("/Home/a.txt", kind: .text),
        ]
        let band = FilesBandBuilder.build(currentColumn: entries)
        XCTAssertEqual(band.items.count, 3)
        XCTAssertEqual(band.items.map(\.title), ["Docs", "photo.png", "a.txt"])
        for (item, entry) in zip(band.items, entries) {
            guard case let .fileEntry(carried) = item.kind else {
                return XCTFail("a Files-band item must carry .fileEntry, got \(item.kind)")
            }
            XCTAssertEqual(carried, entry, "the item must carry the exact source entry")
        }
    }

    func testItemIconIsTheKindGlyph() {
        let band = FilesBandBuilder.build(currentColumn: [fileEntry("/Home/clip.mp4", kind: .video)])
        XCTAssertEqual(band.items.first?.icon, FilesBandBuilder.glyph(for: .video))
        XCTAssertEqual(band.items.first?.icon, .sfSymbol("film"))
    }

    // MARK: - Path-stable identity (the anti-strobe guarantee, design D2)

    func testReListingTheSamePathYieldsTheSameItemID() {
        // Re-entry / a changed file → a fresh FileEntry with the same path but new metadata. The derived
        // LaunchItem.id MUST be identical so the SwiftUI selection keeps its target and never strobes.
        let path = "/Home/Docs/a.txt"
        let first = FilesBandBuilder.item(for: fileEntry(path, kind: .text,
                                                         mod: Date(timeIntervalSince1970: 0)))
        let relisted = FilesBandBuilder.item(for: fileEntry(path, kind: .text,
                                                            mod: Date(timeIntervalSince1970: 9_999)))
        XCTAssertEqual(first.id, relisted.id)
        // …and the rebuilt band agrees, item-for-item, across two independent projections of the column.
        let a = FilesBandBuilder.build(currentColumn: [fileEntry(path, kind: .text)])
        let b = FilesBandBuilder.build(currentColumn: [fileEntry(path, kind: .text)])
        XCTAssertEqual(a.items.map(\.id), b.items.map(\.id))
    }

    func testDistinctPathsYieldDistinctItemIDs() {
        let ids = FilesBandBuilder.build(currentColumn: [
            fileEntry("/Home/a.txt"), fileEntry("/Home/b.txt"), fileEntry("/Home/Docs/a.txt"),
        ]).items.map(\.id)
        XCTAssertEqual(Set(ids).count, 3, "different paths must not collide onto one UUID")
    }

    func testUUIDForPathIsDeterministicAndPathSensitive() {
        XCTAssertEqual(FilesBandBuilder.uuid(forPath: "/Home/a.txt"),
                       FilesBandBuilder.uuid(forPath: "/Home/a.txt"))
        XCTAssertNotEqual(FilesBandBuilder.uuid(forPath: "/Home/a.txt"),
                          FilesBandBuilder.uuid(forPath: "/Home/A.txt"))
    }

    // MARK: - Glyphs

    func testGlyphCoversEveryFileKind() {
        // Every kind maps to a concrete, non-empty SF Symbol — folders never fall through to the generic
        // document glyph, so a Files row's icon always reads as its kind.
        for kind in FileKind.allCases {
            guard case let .sfSymbol(name) = FilesBandBuilder.glyph(for: kind) else {
                return XCTFail("\(kind) must map to an .sfSymbol glyph")
            }
            XCTAssertFalse(name.isEmpty, "\(kind) glyph name must be non-empty")
        }
        XCTAssertEqual(FilesBandBuilder.glyph(for: .folder), .sfSymbol("folder.fill"))
    }
}
