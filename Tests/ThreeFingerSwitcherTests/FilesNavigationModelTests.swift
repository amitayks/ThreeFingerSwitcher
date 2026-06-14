import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests the PURE `FilesNavigationModel` column state machine (change: files-band, tasks 2.3–2.5): the
/// ancestors/current/highlight stack, descend pushes / ascend pops / back-out-to-roots, per-root
/// remembered-location restore (gated by the restore-last-location toggle, at init AND on re-entry into a
/// root), stable path-ids across a re-list, and preview-target for file vs folder. (Type-to-filter search
/// was removed — the navigator is pure-trackpad — so there is no search filter or focus-search signal.)
///
/// Determinism: the model never touches `FileManager` — every folder's contents come from an injected
/// fixture lister, so the whole machine is exercised without a filesystem or a running app (mirroring
/// `FilesSeamsTests`, which is likewise AppKit-free and not `@MainActor`).
final class FilesNavigationModelTests: XCTestCase {

    // MARK: - Fixture filesystem

    /// A tiny in-memory tree the fixture lister serves. Paths are absolute; a folder maps to its child
    /// entries, a file is absent from the map (the lister only ever lists folders).
    private func fileEntry(_ path: String, isDirectory: Bool, kind: FileKind, mod: Date? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                  isDirectory: isDirectory, modificationDate: mod, kind: kind)
    }

    /// Build a lister over a `[folderPath: [FileEntry]]` map. Unlisted/absent folders return empty.
    private func lister(_ tree: [String: [FileEntry]]) -> (URL) -> [FileEntry] {
        { url in tree[url.standardizedFileURL.path] ?? [] }
    }

    /// A standard two-root tree:
    ///   /Home            → Docs/, photo.png
    ///   /Home/Docs       → Sub/, a.txt
    ///   /Home/Docs/Sub   → deep.txt
    ///   /Work            → notes.md
    private func standardModel(remembered: [URL: URL] = [:],
                               restoreLastLocation: Bool = false) -> FilesNavigationModel {
        let tree: [String: [FileEntry]] = [
            "/Home": [
                fileEntry("/Home/Docs", isDirectory: true, kind: .folder),
                fileEntry("/Home/photo.png", isDirectory: false, kind: .image),
            ],
            "/Home/Docs": [
                fileEntry("/Home/Docs/Sub", isDirectory: true, kind: .folder),
                fileEntry("/Home/Docs/a.txt", isDirectory: false, kind: .text),
            ],
            "/Home/Docs/Sub": [
                fileEntry("/Home/Docs/Sub/deep.txt", isDirectory: false, kind: .text),
            ],
            "/Work": [
                fileEntry("/Work/notes.md", isDirectory: false, kind: .text),
            ],
        ]
        return FilesNavigationModel(roots: [URL(fileURLWithPath: "/Home"), URL(fileURLWithPath: "/Work")],
                                    remembered: remembered,
                                    restoreLastLocation: restoreLastLocation,
                                    lister: lister(tree))
    }

    // MARK: - Entry: the roots column

    func testLandsOnTheRootsList() {
        let model = standardModel()
        XCTAssertEqual(model.current, .roots)
        XCTAssertEqual(model.ancestors, [])
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Home", "Work"])
        XCTAssertEqual(model.highlightedIndex, 0)
        XCTAssertEqual(model.highlightedEntry?.name, "Home")
        XCTAssertFalse(model.canAscend, "ascend is a no-op on the roots list")
    }

    // MARK: - Descend pushes an ancestor; ascend pops

    func testDescendIntoRootMakesItCurrentWithEmptyAncestors() {
        var model = standardModel()
        model.descend()    // into /Home (highlighted root)
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")))
        XCTAssertEqual(model.ancestors, [], "a root is the base of its column, not an ancestor")
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Docs", "photo.png"])
        XCTAssertEqual(model.highlightedIndex, 0, "descend resets the highlight to the top")
    }

    func testDescendIntoFolderPushesPriorCurrentOntoAncestors() {
        var model = standardModel()
        model.descend()                 // → /Home  (ancestors [])
        model.descend()                 // highlight is Docs → /Home/Docs
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home/Docs")))
        XCTAssertEqual(model.ancestors, [URL(fileURLWithPath: "/Home")],
                       "the prior current folder becomes the deepest ancestor")
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Sub", "a.txt"])
    }

    func testAscendPopsTheDeepestAncestorBackToCurrent() {
        var model = standardModel()
        model.descend()                 // → /Home
        model.descend()                 // → /Home/Docs  (ancestors [/Home])
        model.ascend()                  // pop → /Home
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")))
        XCTAssertEqual(model.ancestors, [], "the popped ancestor is dropped")
        XCTAssertEqual(model.highlightedEntry?.name, "Docs",
                       "ascend re-highlights the folder we came up from")
    }

    func testAscendFromARootTopLevelReturnsToTheRootsList() {
        var model = standardModel()
        model.descend()                 // → /Home (ancestors [])
        model.ascend()                  // back-out-to-roots
        XCTAssertEqual(model.current, .roots)
        XCTAssertEqual(model.ancestors, [])
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Home", "Work"])
        XCTAssertEqual(model.highlightedEntry?.name, "Home",
                       "the root we came up from is re-highlighted")
    }

    func testAscendOnTheRootsListIsANoOp() {
        var model = standardModel()
        model.ascend()
        XCTAssertEqual(model.current, .roots)
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Home", "Work"])
    }

    func testDescendOnAFileIsANoOp() {
        var model = standardModel()
        model.descend()                 // → /Home
        model.highlightDown()           // highlight photo.png (a file)
        let before = model.current
        model.descend()                 // files open, they don't descend
        XCTAssertEqual(model.current, before, "descending onto a file does nothing")
        XCTAssertEqual(model.highlightedEntry?.name, "photo.png")
    }

    // MARK: - Remembered-location restore (gated by the toggle, on RE-ENTRY into a root)

    func testReEnteringARootRestoresTheDeepestLocationWhenRestoreOn() {
        // Pre-seed Home's remembered deepest as /Home/Docs/Sub. With restore ON the band opens there (init);
        // ascend all the way back to the roots list, then RE-ENTER /Home — `enterRoot` restores it again.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub")]
        var model = standardModel(remembered: remembered, restoreLastLocation: true)
        model.ascend(); model.ascend(); model.ascend()   // /Home/Docs/Sub → … → roots
        XCTAssertEqual(model.current, .roots)
        model.descend()                 // re-enter /Home → restore straight to /Home/Docs/Sub
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home/Docs/Sub")))
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["deep.txt"])
        XCTAssertEqual(model.ancestors,
                       [URL(fileURLWithPath: "/Home"), URL(fileURLWithPath: "/Home/Docs")],
                       "the ancestor chain is rebuilt so ascend walks back up correctly")
    }

    func testDescendIntoARootIgnoresRememberedWhenRestoreOff() {
        // The bug fix: with restore OFF the band opens on the roots list AND descending into a root lands on
        // the root's TOP level — it must NOT jump to the remembered deep folder (the toggle was off).
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub")]
        var model = standardModel(remembered: remembered, restoreLastLocation: false)
        XCTAssertEqual(model.current, .roots, "restore off → opens on the roots list")
        model.descend()                 // enter /Home → land on the TOP level, not /Home/Docs/Sub
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")),
                       "restore off → descending into a root never jumps to the remembered folder")
        XCTAssertEqual(model.ancestors, [])
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Docs", "photo.png"])
    }

    func testNavigatingRecordsTheDeepestLocationForPersistence() {
        var model = standardModel()
        model.descend()                 // → /Home
        model.descend()                 // → /Home/Docs
        // The model surfaces what the caller should persist: Home now remembers /Home/Docs.
        XCTAssertEqual(model.rememberedLocations[URL(fileURLWithPath: "/Home")],
                       URL(fileURLWithPath: "/Home/Docs"))
        // Work is untouched.
        XCTAssertNil(model.rememberedLocations[URL(fileURLWithPath: "/Work")])
    }

    func testEachRootRemembersIndependently() {
        var model = standardModel()
        model.descend()                 // → /Home
        model.descend()                 // → /Home/Docs
        model.ascend(); model.ascend()  // back to roots
        model.highlightDown()           // highlight /Work
        model.descend()                 // → /Work
        XCTAssertEqual(model.rememberedLocations[URL(fileURLWithPath: "/Home")],
                       URL(fileURLWithPath: "/Home/Docs"), "Home kept its own deepest")
        XCTAssertEqual(model.rememberedLocations[URL(fileURLWithPath: "/Work")],
                       URL(fileURLWithPath: "/Work"), "Work remembers its own top level")
    }

    func testStaleRememberedLocationOutsideTheRootIsIgnored() {
        // A remembered path that is NOT under the root must not be restored (e.g. the root moved) even with
        // restore ON: enterRoot skips it and lands on the top level.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Elsewhere/x")]
        var model = standardModel(remembered: remembered, restoreLastLocation: true)
        model.descend()                 // enter /Home → land on the top level, not the stale path
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")))
        XCTAssertEqual(model.ancestors, [])
    }

    // MARK: - Stable identity across a re-list

    func testEntryIDsAreStableAcrossAReList() {
        var model = standardModel()
        model.descend()                 // → /Home
        let idsBefore = model.visibleEntries.map { $0.id }
        model.descend()                 // → /Home/Docs
        model.ascend()                  // re-list /Home
        let idsAfter = model.visibleEntries.map { $0.id }
        XCTAssertEqual(idsBefore, idsAfter, "re-listing the same folder yields the same path-derived ids")
        XCTAssertEqual(idsAfter, ["/Home/Docs", "/Home/photo.png"])
    }

    // MARK: - Preview target (file → self, folder → its contents)

    func testPreviewTargetForAFileIsTheFileItself() {
        var model = standardModel()
        model.descend()                 // → /Home
        model.highlightDown()           // highlight photo.png
        guard case let .file(entry) = model.previewTarget else {
            return XCTFail("a highlighted file previews itself")
        }
        XCTAssertEqual(entry.name, "photo.png")
    }

    func testPreviewTargetForAFolderIsItsContents() {
        var model = standardModel()
        model.descend()                 // → /Home, highlight Docs
        guard case let .folder(entry, contents) = model.previewTarget else {
            return XCTFail("a highlighted folder previews its contents")
        }
        XCTAssertEqual(entry.name, "Docs")
        XCTAssertEqual(contents.map { $0.name }, ["Sub", "a.txt"],
                       "the peek lists exactly what descending would make current")
    }

    func testPreviewTargetIsNilOnAnEmptyColumn() {
        // Descend into an empty folder so the current column has no entries → no preview target.
        let tree: [String: [FileEntry]] = [
            "/R": [fileEntry("/R/Empty", isDirectory: true, kind: .folder)],
            "/R/Empty": [],
        ]
        var model = FilesNavigationModel(roots: [URL(fileURLWithPath: "/R")], lister: lister(tree))
        model.descend()                 // → /R (highlight Empty)
        model.descend()                 // → /R/Empty (empty column)
        XCTAssertNil(model.previewTarget)
    }

    // MARK: - Highlight stepping (clamps both ends; no search overflow)

    func testHighlightDownAndUpStepWithinBounds() {
        var model = standardModel()
        model.descend()                 // → /Home (Docs, photo.png)
        XCTAssertEqual(model.highlightedIndex, 0)
        model.highlightDown()
        XCTAssertEqual(model.highlightedIndex, 1)
        model.highlightDown()           // clamp at the last row
        XCTAssertEqual(model.highlightedIndex, 1)
        model.highlightUp()
        XCTAssertEqual(model.highlightedIndex, 0)
    }

    func testHighlightUpAtTheTopClamps() {
        var model = standardModel()
        model.descend()                 // → /Home, highlight at index 0
        model.highlightUp()             // up at the top → clamp, no overflow, no side effect
        XCTAssertEqual(model.highlightedIndex, 0, "the highlight stays clamped at the top")
        model.highlightUp()             // and again — still a no-op
        XCTAssertEqual(model.highlightedIndex, 0)
    }

    // MARK: - Restore-at-init (refinement 2: the band OPENS displaying the last folder)

    func testRestoreAtInitOpensDisplayingTheRememberedFolderWithRebuiltAncestors() {
        // A prior session left off at /Home/Docs/Sub; with the restore toggle ON the band must OPEN there.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub")]
        let model = standardModel(remembered: remembered, restoreLastLocation: true)
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home/Docs/Sub")),
                       "restore happens AT INIT, not on the first descend")
        XCTAssertEqual(model.ancestors,
                       [URL(fileURLWithPath: "/Home"), URL(fileURLWithPath: "/Home/Docs")],
                       "the ancestor chain is reconstructed so ascending walks back up")
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["deep.txt"],
                       "the restored folder's contents are listed on open")
        XCTAssertEqual(model.highlightedIndex, 0)
    }

    func testRestoreAtInitWithRootTopLevelRememberedLandsOnThatRoot() {
        // Remembered is the root itself (the user only ever reached its top level): open there, no ancestors.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home")]
        let model = standardModel(remembered: remembered, restoreLastLocation: true)
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")))
        XCTAssertEqual(model.ancestors, [], "a root top-level restore has no ancestors")
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Docs", "photo.png"])
    }

    func testRestoreAtInitOffLandsOnTheRootsListEvenWithARememberedLocation() {
        // The toggle OFF must ignore the remembered map and land fresh on the roots list.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub")]
        let model = standardModel(remembered: remembered, restoreLastLocation: false)
        XCTAssertEqual(model.current, .roots)
        XCTAssertEqual(model.ancestors, [])
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Home", "Work"])
    }

    func testRestoreAtInitWithNothingRememberedFallsBackToTheRootsList() {
        // Toggle ON but no remembered location → still the roots list (nothing to restore).
        let model = standardModel(restoreLastLocation: true)
        XCTAssertEqual(model.current, .roots)
        XCTAssertEqual(model.visibleEntries.map { $0.name }, ["Home", "Work"])
    }

    func testRestoreAtInitSkipsAStaleRememberedLocationOutsideTheRoot() {
        // A remembered path no longer under the root (the root moved) must not be restored; fall back to roots.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Elsewhere/x")]
        let model = standardModel(remembered: remembered, restoreLastLocation: true)
        XCTAssertEqual(model.current, .roots, "a stale remembered path is ignored at restore")
    }

    func testRestoreAtInitPicksTheDeepestRememberedLocationAcrossRoots() {
        // Both roots are remembered; the deeper one (/Home/Docs/Sub) wins over /Work's top level.
        let remembered = [
            URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub"),
            URL(fileURLWithPath: "/Work"): URL(fileURLWithPath: "/Work"),
        ]
        let model = standardModel(remembered: remembered, restoreLastLocation: true)
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home/Docs/Sub")),
                       "the deepest remembered path is the most specific 'where you left off'")
        XCTAssertEqual(model.ancestors,
                       [URL(fileURLWithPath: "/Home"), URL(fileURLWithPath: "/Home/Docs")])
    }

    func testRestoredDepthAtInitAscendsBackUpToTheRootsList() {
        // The reconstructed chain must let ascend walk all the way back to the roots list.
        let remembered = [URL(fileURLWithPath: "/Home"): URL(fileURLWithPath: "/Home/Docs/Sub")]
        var model = standardModel(remembered: remembered, restoreLastLocation: true)
        model.ascend()                  // → /Home/Docs
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home/Docs")))
        model.ascend()                  // → /Home
        XCTAssertEqual(model.current, .folder(URL(fileURLWithPath: "/Home")))
        model.ascend()                  // → roots
        XCTAssertEqual(model.current, .roots)
    }

    // MARK: - Breadcrumb (refinement 4: root → … → highlighted item)

    func testBreadcrumbAtTheRootsListIsTheHighlightedRoot() {
        let model = standardModel()
        XCTAssertEqual(model.breadcrumb.map { $0.name }, ["Home"],
                       "at the entry column the highlighted root is the whole path")
        XCTAssertEqual(model.breadcrumb.map { $0.url }, [URL(fileURLWithPath: "/Home")])
    }

    func testBreadcrumbIsRootThroughCurrentToHighlightedEntry() {
        var model = standardModel()
        model.descend()                 // → /Home, highlight Docs
        model.descend()                 // → /Home/Docs, highlight Sub
        // ancestors [/Home] + current /Home/Docs + highlighted Sub.
        XCTAssertEqual(model.breadcrumb.map { $0.name }, ["Home", "Docs", "Sub"])
        XCTAssertEqual(model.breadcrumb.map { $0.url },
                       [URL(fileURLWithPath: "/Home"),
                        URL(fileURLWithPath: "/Home/Docs"),
                        URL(fileURLWithPath: "/Home/Docs/Sub")])
    }

    func testBreadcrumbUpdatesLiveAsTheHighlightMoves() {
        var model = standardModel()
        model.descend()                 // → /Home, highlight Docs (a folder)
        XCTAssertEqual(model.breadcrumb.map { $0.name }, ["Home", "Docs"])
        model.highlightDown()           // highlight photo.png (a file)
        XCTAssertEqual(model.breadcrumb.map { $0.name }, ["Home", "photo.png"],
                       "the leaf follows the highlight live (folder → file)")
    }

    func testBreadcrumbStopsAtTheCurrentFolderWhenTheColumnIsEmpty() {
        // An empty folder → nothing highlighted, so the path stops at the current folder.
        let tree: [String: [FileEntry]] = [
            "/R": [fileEntry("/R/Empty", isDirectory: true, kind: .folder)],
            "/R/Empty": [],
        ]
        var model = FilesNavigationModel(roots: [URL(fileURLWithPath: "/R")], lister: lister(tree))
        model.descend()                 // → /R
        model.descend()                 // → /R/Empty (empty column)
        XCTAssertNil(model.highlightedEntry)
        XCTAssertEqual(model.breadcrumb.map { $0.name }, ["R", "Empty"],
                       "with nothing highlighted the path stops at the current folder")
    }
}
