import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests the Files-band *integration* into `LauncherModel` (change: files-band, tasks 6.1–6.3): the
/// `currentBandIsFiles` gating, horizontal drilling (descend / ascend) reprojecting the band's items,
/// vertical highlight motion (clamping at the top — no search), remembered-location persistence and the
/// restore-on-re-entry toggle, and the descending sort's folders-first preservation — plus the
/// `FilesColumnController`'s sync-model ⇄ cache bridge in isolation.
///
/// Determinism: every test drives a `FilesColumnController` over a **fully-seeded fixture cache** (the
/// whole tree handed in at init), so the controller never touches `FileManager` and never has to await an
/// async listing — the synchronous navigation model reads the warm cache immediately. This mirrors how
/// `FilesNavigationModelTests` injects a fixture lister; here the fixture is the cache the bridge owns.
@MainActor
final class FilesColumnRoutingTests: XCTestCase {

    // MARK: - Fixture tree

    private func entry(_ path: String, dir: Bool, kind: FileKind, mod: Date? = nil) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                  isDirectory: dir, modificationDate: mod, kind: kind)
    }

    /// The standard two-root tree (same shape as `FilesNavigationModelTests`):
    ///   /Home            → Docs/, photo.png
    ///   /Home/Docs       → Sub/, a.txt
    ///   /Home/Docs/Sub   → deep.txt
    ///   /Work            → notes.md
    private func standardTree() -> [String: [FileEntry]] {
        [
            "/Home": [
                entry("/Home/Docs", dir: true, kind: .folder),
                entry("/Home/photo.png", dir: false, kind: .image),
            ],
            "/Home/Docs": [
                entry("/Home/Docs/Sub", dir: true, kind: .folder),
                entry("/Home/Docs/a.txt", dir: false, kind: .text),
            ],
            "/Home/Docs/Sub": [
                entry("/Home/Docs/Sub/deep.txt", dir: false, kind: .text),
            ],
            "/Work": [
                entry("/Work/notes.md", dir: false, kind: .text),
            ],
        ]
    }

    private var homeRoot: URL { URL(fileURLWithPath: "/Home") }
    private var workRoot: URL { URL(fileURLWithPath: "/Work") }

    /// A controller seeded with the whole tree (no live FS, no async round-trip), landing on the roots list.
    /// `record` collects the `(path, root)` pairs the controller asks to persist (the model's remembered sink).
    private func makeController(remembered: [URL: URL] = [:],
                                direction: FilesSortDirection = .ascending) -> FilesColumnController {
        FilesColumnController(roots: [homeRoot, workRoot],
                              remembered: remembered,
                              sortOrder: .name,
                              sortDirection: direction,
                              seededCache: standardTree())
    }

    /// A `LauncherModel` carrying a normal band 0 plus a Files band at index 1, with the controller wired in.
    /// Mirrors how the wiring layer will call `setBands` (the Files band built from the controller's column).
    private func makeModelWithFilesBand(
        controller: FilesColumnController,
        onRemember: ((_ path: String, _ root: String) -> Void)? = nil
    ) -> LauncherModel {
        let model = LauncherModel()
        model.onFilesRememberLocation = onRemember
        let appBand = [LaunchItem(title: "A0", icon: .appDefault,
                                  kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/A0.app"), strategy: nil))]
        let filesItems = FilesBandBuilder.build(currentColumn: controller.visibleEntries).items
        model.setBands([appBand, filesItems],
                       names: ["Dev", FilesBandBuilder.name],
                       colors: [ItemColor(red: 0, green: 0, blue: 1), FilesBandBuilder.color],
                       startBand: 1, column: 0,
                       filesBandIndex: 1, filesColumn: controller)
        return model
    }

    /// Drive the model onto the Files band's grid (it starts on the band list since there are two bands):
    /// RIGHT crosses into the grid, where the Files band's directory drill takes over.
    private func enterFilesGrid(_ model: LauncherModel) {
        XCTAssertEqual(model.currentBand, 1)
        XCTAssertEqual(model.focus, .bands, "two bands → lands on the band list")
        model.stepHorizontal(1)               // band list → grid (enter the Files column)
        XCTAssertEqual(model.focus, .grid)
    }

    // MARK: - Gating

    func testCurrentBandIsFilesGating() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        XCTAssertTrue(model.currentBandIsFiles, "the active band (index 1) is the Files band")
        XCTAssertNotNil(model.filesColumn)
        // Switch to band 0 (up the list, previous band) and the gate flips off.
        model.stepVertical(1)
        XCTAssertEqual(model.currentBand, 0)
        XCTAssertFalse(model.currentBandIsFiles)
    }

    func testNoFilesBandWhenNotConfigured() {
        let model = LauncherModel()
        model.setBands([[LaunchItem(title: "A0", icon: .appDefault,
                                    kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/A0.app"), strategy: nil))]],
                       names: ["Dev"], colors: [ItemColor(red: 0, green: 0, blue: 1)],
                       startBand: 0, column: 0)
        XCTAssertNil(model.filesBandIndex)
        XCTAssertNil(model.filesColumn)
        XCTAssertFalse(model.currentBandIsFiles)
    }

    // MARK: - Focus-aware crossing & the drill-engaged predicate (refinements 1 + 2)

    /// On the band RAIL (`focus == .bands`) the Files band is current but the drill is NOT engaged — a lift
    /// there must dismiss like any other band, so `filesDrillEngaged` (which gates `filesDrillActive`) is
    /// false until focus crosses INTO the column.
    func testFilesDrillEngagedIsFalseOnTheBandRail() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        XCTAssertEqual(model.focus, .bands, "two bands → lands on the Files band icon (the rail)")
        XCTAssertTrue(model.currentBandIsFiles)
        XCTAssertFalse(model.filesDrillEngaged,
                       "the drill is NOT engaged while resting on the band icon — a lift dismisses")
    }

    /// A horizontal step toward the grid CROSSES focus `.bands` → `.grid` and engages the drill, WITHOUT
    /// descending — it lands on the column the navigator already displays (the roots list here), not a level
    /// deeper. Descend/ascend only apply once `focus == .grid`.
    func testHorizontalAtBandsCrossesToGridWithoutDescending() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        XCTAssertEqual(controller.current, .roots)
        model.stepHorizontal(1)                       // band rail → grid (a pure focus cross, no descend)
        XCTAssertEqual(model.focus, .grid, "the horizontal step crossed into the file column")
        XCTAssertTrue(model.filesDrillEngaged, "the drill engages once focus is in the column")
        XCTAssertEqual(controller.current, .roots, "crossing in did NOT descend — still the displayed column")
        XCTAssertEqual(model.items.map(\.title), ["Home", "Work"], "the displayed roots column is unchanged")
        XCTAssertEqual(model.selectedIndex, 0, "lands at the top of the column (the navigator's highlight)")
    }

    /// The descend happens only on a SECOND horizontal step — the first crossed focus in (no descend), the
    /// second (now at `.grid`) descends. This is the "descend only at `.grid`" invariant.
    func testDescendOnlyHappensOnceFocusIsGrid() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        model.stepHorizontal(1)                       // cross to .grid (no descend)
        XCTAssertEqual(controller.current, .roots)
        model.stepHorizontal(1)                       // now at .grid → descend into the highlighted root (Home)
        XCTAssertEqual(controller.current, .folder(homeRoot), "the second step (at .grid) descends")
        XCTAssertTrue(model.filesDrillEngaged)
        XCTAssertEqual(model.items.map(\.title), ["Docs", "photo.png"])
    }

    /// A vertical step on the band rail switches bands and never descends — the drill stays disengaged the
    /// whole time, and switching off the Files band disengages it (so `filesDrillActive` releases).
    func testVerticalAtBandsSwitchesBandsAndNeverDescends() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        model.stepVertical(1)                         // up the rail → previous band (band 0)
        XCTAssertEqual(model.currentBand, 0, "vertical on the rail switched bands")
        XCTAssertEqual(controller.current, .roots, "switching bands never descended the Files column")
        XCTAssertFalse(model.filesDrillEngaged, "off the Files band → the drill is disengaged")
    }

    /// With restore-at-open ON, the navigator OPENS displaying the remembered deep folder; crossing in from
    /// the icon lands exactly there (the displayed state and the landing MATCH — no jump). A single right
    /// step crosses focus; it does NOT then descend a further level past the restored folder.
    func testCrossingInLandsOnTheRestoredFolderWithNoJump() {
        // A controller that restores last-location to /Home/Docs on open (refinement 2).
        let controller = FilesColumnController(roots: [homeRoot, workRoot],
                                               remembered: [homeRoot: URL(fileURLWithPath: "/Home/Docs")],
                                               sortOrder: .name,
                                               sortDirection: .ascending,
                                               restoreLastLocation: true,
                                               seededCache: standardTree())
        XCTAssertEqual(controller.current, .folder(URL(fileURLWithPath: "/Home/Docs")),
                       "restore-at-open lands the navigator on the remembered folder before any crossing")
        let model = makeModelWithFilesBand(controller: controller)
        // The band already DISPLAYS the restored folder's contents while still on the icon.
        XCTAssertEqual(model.items.map(\.title), ["Sub", "a.txt"],
                       "the column shows the restored folder while on the band icon")
        model.stepHorizontal(1)                       // cross in
        XCTAssertEqual(model.focus, .grid)
        XCTAssertEqual(controller.current, .folder(URL(fileURLWithPath: "/Home/Docs")),
                       "crossing in landed on the SAME displayed folder — no jump deeper")
        XCTAssertEqual(model.items.map(\.title), ["Sub", "a.txt"], "the displayed state and the landing match")
        XCTAssertEqual(model.selectedIndex, 0, "at the top of the restored column")
    }

    // MARK: - Top-of-column up clamps (no search to overflow into)

    /// An up-step at the top of the column is a pure clamp now: the highlight stays put and nothing else
    /// happens (no search field to focus, no depth change).
    func testUpAtTopOfColumnClamps() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        model.stepHorizontal(1)                       // → Home, highlight at the top (index 0)
        model.stepVertical(1)                         // up while already at the top → clamp, no-op
        XCTAssertEqual(model.selectedIndex, 0, "the highlight stays put on a top-of-column up-step")
        XCTAssertEqual(controller.current, .folder(homeRoot), "no depth change, no side effect")
    }

    // MARK: - Horizontal drill (descend / ascend) reprojects the band

    func testHorizontalRightDescendsAndReprojects() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        // Roots column: [Home, Work]; highlight is Home.
        XCTAssertEqual(model.items.map(\.title), ["Home", "Work"])
        model.stepHorizontal(1)               // descend into Home
        XCTAssertEqual(controller.current, .folder(homeRoot))
        XCTAssertEqual(model.items.map(\.title), ["Docs", "photo.png"],
                       "the band's items are reprojected from the new column")
        XCTAssertEqual(model.selectedIndex, 0, "descend resets the highlight to the top")
        // Descend again into Docs.
        model.stepHorizontal(1)
        XCTAssertEqual(controller.current, .folder(URL(fileURLWithPath: "/Home/Docs")))
        XCTAssertEqual(model.items.map(\.title), ["Sub", "a.txt"])
    }

    func testHorizontalLeftAscendsAndReprojects() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        model.stepHorizontal(1)               // → Home
        model.stepHorizontal(1)               // → Home/Docs
        XCTAssertEqual(model.items.map(\.title), ["Sub", "a.txt"])
        model.stepHorizontal(-1)              // ascend → Home
        XCTAssertEqual(controller.current, .folder(homeRoot))
        XCTAssertEqual(model.items.map(\.title), ["Docs", "photo.png"])
        XCTAssertEqual(model.selectedItem?.title, "Docs",
                       "ascend re-highlights the folder we came up from")
    }

    func testHorizontalLeftAtRootsCrossesBackToBandList() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        // On the roots list, ascend can't go further → a LEFT crosses back to the band list (band-0 escape).
        XCTAssertFalse(controller.canAscend)
        model.stepHorizontal(-1)
        XCTAssertEqual(model.focus, .bands, "left at the roots list returns to the band list")
        XCTAssertEqual(model.currentBand, 1, "the Files band stays active")
        XCTAssertEqual(controller.current, .roots, "no spurious ascend happened")
    }

    func testHorizontalRightOnAFileDoesNotDescend() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        model.stepHorizontal(1)               // → Home  ([Docs, photo.png])
        model.stepVertical(-1)                // highlight down → photo.png (a file)
        XCTAssertEqual(model.selectedItem?.title, "photo.png")
        model.stepHorizontal(1)               // descend on a file is a no-op in the navigator
        XCTAssertEqual(controller.current, .folder(homeRoot), "a file doesn't descend")
        XCTAssertEqual(model.items.map(\.title), ["Docs", "photo.png"])
    }

    // MARK: - Vertical highlight (with inversion already applied upstream)

    func testVerticalMovesHighlightDownThenUp() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        model.stepHorizontal(1)               // → Home  ([Docs, photo.png]), highlight Docs (0)
        XCTAssertEqual(model.selectedIndex, 0)
        model.stepVertical(-1)                // down → index 1 (photo.png)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(controller.highlightedEntry?.name, "photo.png")
        model.stepVertical(1)                 // up → back to index 0 (Docs)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(controller.highlightedEntry?.name, "Docs")
    }

    func testVerticalDownClampsAtTheBottom() {
        let controller = makeController()
        let model = makeModelWithFilesBand(controller: controller)
        enterFilesGrid(model)
        model.stepHorizontal(1)               // → Home (2 entries)
        model.stepVertical(-1)                // → index 1
        model.stepVertical(-1)                // already last → clamp
        XCTAssertEqual(model.selectedIndex, 1, "down clamps at the last row")
    }

    // MARK: - Remembered-location persistence on a depth change

    func testDepthChangePersistsRememberedLocation() {
        let controller = makeController()
        var recorded: [(path: String, root: String)] = []
        let model = makeModelWithFilesBand(controller: controller) { path, root in
            recorded.append((path, root))
        }
        enterFilesGrid(model)
        model.stepHorizontal(1)               // descend into Home → a depth change persists
        XCTAssertTrue(recorded.contains { $0.path == "/Home" && $0.root == "/Home" },
                      "descending into a root records it as that root's remembered deepest location")
        model.stepHorizontal(1)               // descend into Docs
        XCTAssertTrue(recorded.contains { $0.path == "/Home/Docs" && $0.root == "/Home" },
                      "descending deeper updates the remembered location under the owning root")
    }

    func testHorizontalThatDoesNotChangeDepthDoesNotPersist() {
        let controller = makeController()
        var recorded: [(path: String, root: String)] = []
        let model = makeModelWithFilesBand(controller: controller) { path, root in
            recorded.append((path, root))
        }
        enterFilesGrid(model)
        // A LEFT at the roots list crosses to the band list (no depth change) → nothing persisted.
        model.stepHorizontal(-1)
        XCTAssertTrue(recorded.isEmpty, "crossing back to the band list is not a depth change")
    }

    func testReentryRestoresRememberedLocationWhenRestoreOn() {
        // Restore ON: the controller opens deep (/Home/Docs); ascend back to roots, then re-descend into Home
        // → `enterRoot` restores the remembered /Home/Docs again.
        let controller = FilesColumnController(roots: [homeRoot, workRoot],
                                               remembered: [homeRoot: URL(fileURLWithPath: "/Home/Docs")],
                                               sortOrder: .name,
                                               sortDirection: .ascending,
                                               restoreLastLocation: true,
                                               seededCache: standardTree())
        XCTAssertEqual(controller.current, .folder(URL(fileURLWithPath: "/Home/Docs")), "opens restored")
        controller.ascend(); controller.ascend()      // /Home/Docs → /Home → roots
        XCTAssertEqual(controller.current, .roots)
        controller.descend()                          // re-enter Home → restores /Home/Docs
        XCTAssertEqual(controller.current, .folder(URL(fileURLWithPath: "/Home/Docs")))
        XCTAssertEqual(controller.visibleEntries.map(\.name), ["Sub", "a.txt"])
    }

    func testReentryDoesNotRestoreWhenRestoreOff() {
        // The bug fix at the integration layer: restore OFF opens on the roots list, and descending into a
        // root from the band lands on the root's TOP level — never the remembered deep folder.
        let controller = makeController(remembered: [homeRoot: URL(fileURLWithPath: "/Home/Docs")])  // restore off
        let model = makeModelWithFilesBand(controller: controller)
        XCTAssertEqual(controller.current, .roots, "restore off → opens on roots")
        enterFilesGrid(model)
        model.stepHorizontal(1)               // descend into Home → lands on the TOP, not the remembered /Home/Docs
        XCTAssertEqual(controller.current, .folder(homeRoot),
                       "restore off → descending into a root never jumps to the last-visited folder")
        XCTAssertEqual(model.items.map(\.title), ["Docs", "photo.png"])
    }

    // MARK: - Descending sort preserves folders-first

    func testDescendingSortPreservesFoldersFirst() {
        // A column with two folders and two files, listed ascending folders-first, then flipped descending.
        let ascending: [FileEntry] = [
            entry("/X/Alpha", dir: true, kind: .folder),
            entry("/X/Beta", dir: true, kind: .folder),
            entry("/X/apple.txt", dir: false, kind: .text),
            entry("/X/banana.txt", dir: false, kind: .text),
        ]
        let descending = FilesColumnController.applyingDirection(.descending, to: ascending)
        // Folders must still lead (not sink to the tail), but reversed within their own group; files too.
        XCTAssertEqual(descending.map(\.name), ["Beta", "Alpha", "banana.txt", "apple.txt"])
        XCTAssertTrue(descending.prefix(2).allSatisfy(\.isDirectory),
                      "descending keeps folders-first — they do not move below the files")
        // Ascending is the identity (the lister already produced folders-first ascending).
        XCTAssertEqual(FilesColumnController.applyingDirection(.ascending, to: ascending).map(\.name),
                       ["Alpha", "Beta", "apple.txt", "banana.txt"])
    }

    func testSortFieldMapping() {
        XCTAssertEqual(FilesColumnController.sortOrder(field: .name), .name)
        XCTAssertEqual(FilesColumnController.sortOrder(field: .date), .dateModified)
        XCTAssertEqual(FilesColumnController.sortOrder(field: .kind), .kind)
    }

    // MARK: - The controller's cache bridge in isolation (async miss → warm → re-feed)

    func testAsyncListingWarmsTheCacheAndRefeeds() async {
        // Build a controller with an EMPTY seed and an async fixture lister, so a descend misses the cache,
        // kicks off the async listing, and the re-feed fills the column once it settles.
        let tree = standardTree()
        let lister: (URL, FilesSortOrder) async -> [FileEntry] = { url, _ in
            tree[url.standardizedFileURL.path] ?? []
        }
        let controller = FilesColumnController(roots: [homeRoot, workRoot],
                                               remembered: [:],
                                               sortOrder: .name,
                                               sortDirection: .ascending,
                                               seededCache: [:],
                                               lister: lister)
        // The roots column is synthesized (no listing), so it's populated even before anything settles.
        XCTAssertEqual(controller.visibleEntries.map(\.name), ["Home", "Work"], "roots need no listing")
        // Descend into Home WITHOUT awaiting first: the init's preview-peek task for /Home hasn't run yet
        // (no suspension point since init), so the cache is a genuine MISS and the column is empty for a beat.
        controller.descend()
        XCTAssertTrue(controller.visibleEntries.isEmpty,
                      "the synchronous model shows empty until the async listing lands")
        await controller.settle()             // drive the async bridge (and its peek cascade) to completion
        XCTAssertEqual(controller.visibleEntries.map(\.name), ["Docs", "photo.png"],
                       "the landed listing was stored and re-fed into the current column")
        XCTAssertNotNil(controller.cache["/Home"], "the completed listing is cached")
    }

    func testPreviewFolderPeekFlowsThroughTheCache() {
        // With the whole tree seeded, the highlighted folder's preview peek reads the cache (no live list).
        let controller = makeController()
        controller.descend()                  // → Home, highlight Docs (a folder)
        guard case let .folder(folderEntry, contents)? = controller.previewTarget else {
            return XCTFail("highlighting a folder yields a folder preview target")
        }
        XCTAssertEqual(folderEntry.name, "Docs")
        XCTAssertEqual(contents.map(\.name), ["Sub", "a.txt"], "the peek's contents come from the cache")
    }
}
