import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure Files action-menu model (`Files/FilesActionMenu.swift`) and the keep-both
/// Paste-into name resolver — the `files-action-menu` defaults, per-type independence, the runtime
/// visibility rules (pasteInto gating, terminal expansion), and the conflict-free rename.
final class FilesActionMenuTests: XCTestCase {

    // MARK: - Fixtures

    private func file(_ path: String) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
                  isDirectory: false, modificationDate: nil, kind: .other)
    }
    private func folder(_ path: String) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
                  isDirectory: true, modificationDate: nil, kind: .folder)
    }
    private func term(_ id: String, _ name: String, enabled: Bool = true) -> FilesTool {
        FilesTool(bundleID: id, name: name, role: .terminal, enabled: enabled)
    }

    // MARK: - Defaults match the spec exactly

    func testDefaultMenusMatchSpec() {
        XCTAssertEqual(FilesActionMenu.defaultFileItems,
                       [.copyAsPath, .copy, .cut, .pasteInto, .openIn, .delete],
                       "file default: Copy as path · Copy · Cut · Paste · Open in · Delete (Delete last)")
        XCTAssertEqual(FilesActionMenu.defaultFolderItems,
                       [.copyAsPath, .copy, .cut, .pasteInto, .openInTerminals, .openIn, .delete],
                       "folder default adds the terminals group before Open in; Cut after Copy, Delete last")
        XCTAssertEqual(FilesActionMenu.default.fileItems, FilesActionMenu.defaultFileItems)
        XCTAssertEqual(FilesActionMenu.default.folderItems, FilesActionMenu.defaultFolderItems)
    }

    func testItemsForTypeSelectsTheRightList() {
        let menu = FilesActionMenu.default
        XCTAssertEqual(menu.items(forFolder: false), FilesActionMenu.defaultFileItems)
        XCTAssertEqual(menu.items(forFolder: true), FilesActionMenu.defaultFolderItems)
    }

    // MARK: - Visible rows: file vs folder, pasteInto gating, terminal expansion

    func testFileRowsOmitTerminalsAndExpandNothing() {
        let rows = FilesActionMenu.default.visibleRows(
            for: file("/tmp/a.txt"), pasteboardHasFile: true,
            terminals: [term("com.apple.Terminal", "Terminal")], editors: [])
        XCTAssertEqual(rows, [.action(.copyAsPath), .action(.copy), .action(.cut),
                              .action(.pasteInto), .action(.openIn), .action(.delete)])
    }

    func testFolderRowsExpandOneRowPerEnabledTerminal() {
        let rows = FilesActionMenu.default.visibleRows(
            for: folder("/tmp/dir"), pasteboardHasFile: true,
            terminals: [term("com.apple.Terminal", "Terminal"), term("com.googlecode.iterm2", "iTerm")],
            editors: [])
        XCTAssertEqual(rows, [
            .action(.copyAsPath), .action(.copy), .action(.cut), .action(.pasteInto),
            .tool(.openInTerminals, term("com.apple.Terminal", "Terminal")),
            .tool(.openInTerminals, term("com.googlecode.iterm2", "iTerm")),
            .action(.openIn), .action(.delete)
        ])
    }

    func testDisabledTerminalsAreFilteredOut() {
        let rows = FilesActionMenu.default.visibleRows(
            for: folder("/tmp/dir"), pasteboardHasFile: false,
            terminals: [term("com.apple.Terminal", "Terminal", enabled: false),
                        term("com.googlecode.iterm2", "iTerm")],
            editors: [])
        let toolRows = rows.filter { if case .tool = $0 { return true } else { return false } }
        XCTAssertEqual(toolRows, [.tool(.openInTerminals, term("com.googlecode.iterm2", "iTerm"))])
    }

    func testEmptyTerminalsVanishEntirely() {
        let rows = FilesActionMenu.default.visibleRows(
            for: folder("/tmp/dir"), pasteboardHasFile: true, terminals: [], editors: [])
        XCTAssertFalse(rows.contains { if case .tool = $0 { return true } else { return false } },
                       "no terminals installed → no terminal rows")
    }

    func testPasteIntoHiddenWithoutFileOnPasteboard() {
        let rows = FilesActionMenu.default.visibleRows(
            for: file("/tmp/a.txt"), pasteboardHasFile: false, terminals: [], editors: [])
        XCTAssertFalse(rows.contains(.action(.pasteInto)), "Paste is hidden when the pasteboard holds no file")
        XCTAssertEqual(rows, [.action(.copyAsPath), .action(.copy), .action(.cut),
                              .action(.openIn), .action(.delete)])
    }

    // MARK: - Cut / Delete (file operations)

    func testCutAndDeleteAreDefaultForBothTypesAsPlainRows() {
        // Both are catalog defaults for files and folders, pass through as plain `.action` rows (no grouping
        // or visibility special-casing), and Delete is ordered last (set apart from the everyday actions).
        XCTAssertTrue(FilesActionMenu.defaultFileItems.contains(.cut))
        XCTAssertTrue(FilesActionMenu.defaultFileItems.contains(.delete))
        XCTAssertTrue(FilesActionMenu.defaultFolderItems.contains(.cut))
        XCTAssertTrue(FilesActionMenu.defaultFolderItems.contains(.delete))
        XCTAssertEqual(FilesActionMenu.defaultFileItems.last, .delete, "Delete is last")
        XCTAssertEqual(FilesActionMenu.defaultFolderItems.last, .delete, "Delete is last")
        XCTAssertTrue(FilesMenuAction.defaultCatalog.contains(.cut))
        XCTAssertTrue(FilesMenuAction.defaultCatalog.contains(.delete))

        let fileRows = FilesActionMenu.default.visibleRows(
            for: file("/tmp/a.txt"), pasteboardHasFile: false, terminals: [], editors: [])
        XCTAssertTrue(fileRows.contains(.action(.cut)))
        XCTAssertTrue(fileRows.contains(.action(.delete)))
    }

    func testCutAndDeleteSurviveCodableRoundTrip() throws {
        let menu = FilesActionMenu(fileItems: [.cut, .delete], folderItems: [.delete, .cut])
        let data = try JSONEncoder().encode(menu)
        XCTAssertEqual(try JSONDecoder().decode(FilesActionMenu.self, from: data), menu)
    }

    // MARK: - Per-type independence

    func testEditingFolderMenuLeavesFileMenuUntouched() {
        var menu = FilesActionMenu.default
        menu.folderItems = [.openIn]
        XCTAssertEqual(menu.fileItems, FilesActionMenu.defaultFileItems, "file menu unaffected by folder edit")
        XCTAssertEqual(menu.items(forFolder: true), [.openIn])
    }

    // MARK: - Codable round-trip (the persistence shape)

    func testCodableRoundTrip() throws {
        var menu = FilesActionMenu.default
        menu.fileItems = [.addToFavorites, .copyAsPath, .openIn]
        let data = try JSONEncoder().encode(menu)
        XCTAssertEqual(try JSONDecoder().decode(FilesActionMenu.self, from: data), menu)
    }

    // MARK: - Keep-both Paste-into name resolution

    func testUniqueNameReturnsDesiredWhenFree() {
        XCTAssertEqual(FilesPasteName.uniqueName(for: "report.pdf", existing: []), "report.pdf")
        XCTAssertEqual(FilesPasteName.uniqueName(for: "report.pdf", existing: ["other.pdf"]), "report.pdf")
    }

    func testUniqueNameFirstCollisionAppendsCopyPreservingExtension() {
        XCTAssertEqual(FilesPasteName.uniqueName(for: "report.pdf", existing: ["report.pdf"]), "report copy.pdf")
    }

    func testUniqueNameRepeatedCollisionsCount() {
        let existing: Set<String> = ["report.pdf", "report copy.pdf", "report copy 2.pdf"]
        XCTAssertEqual(FilesPasteName.uniqueName(for: "report.pdf", existing: existing), "report copy 3.pdf")
    }

    func testUniqueNameNoExtension() {
        XCTAssertEqual(FilesPasteName.uniqueName(for: "Makefile", existing: ["Makefile"]), "Makefile copy")
        XCTAssertEqual(FilesPasteName.uniqueName(for: "Makefile", existing: ["Makefile", "Makefile copy"]),
                       "Makefile copy 2")
    }

    func testUniqueNameFolderName() {
        // A folder (no extension) collides like an extensionless file.
        XCTAssertEqual(FilesPasteName.uniqueName(for: "Projects", existing: ["Projects"]), "Projects copy")
    }
}
