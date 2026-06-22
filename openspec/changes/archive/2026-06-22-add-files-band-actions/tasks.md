> Decomposed for a workflow fan-out: §1–§2 are the pure Core substrate (do first), §3–§4 build the menu surface + effects on it, §5 is the picker follow-on, §6 is customization (depends on §2), §7 verifies. MLX-free Core throughout; `swift build`/`swift test` verify the logic, `xcodebuild` compile-verifies the app target, and the live paste/copy-in/app-grid/terminal launch are user run-verify.

## 1. Delivery substrate (pure Core + reused paste seam)

- [x] 1.1 Add a pure **delivery representation builder** (MLX-free Core): given a `FileEntry`, produce the dual-representation pasteboard payload — the `.fileURL` **and** the standardized POSIX path as `.string` — as a single item. Pure → unit-tested (both reps present; path is standardized). *(`Files/FilesDelivery.swift` + `FilesDeliveryTests`.)*
- [x] 1.2 Add `SelectionService.deliverFile(url:path:)` + a `setFileDelivery(url:path:)` pasteboard seam (writes `.string` path + `.fileURL` in one item), keeping the snapshot → write → activate → ⌘V (`0x09`) → **restore** round-trip and the `getpid()` self-guard. Existing text-paste callers unchanged.
- [x] 1.3 Add `filesDeliver()` on the Files-drill path in `AppCoordinator`: `filesOpen()`'s picker-closed branch now switches on `settings.filesLiftAction` — `.deliver` (default) builds the payload (§1.1) and delivers via §1.2 into the **captured** front app; `.open` keeps the old open. Added `FilesLiftAction` + persisted `AppSettings.filesLiftAction` (default `.deliver`).
- [x] 1.4 **Observability:** a no-front-app delivery surfaces a bounded `filesOpenFailure` row and keeps the navigator open (re-armed) — `hide()` destroys the panel synchronously, so the row only shows while open (mirrors `surfaceNoApplication`); never a fabricated "Done" for the keystroke.
- [x] 1.5 Unit tests: representation builder (`FilesDeliveryTests`); `deliverFile` writes both reps + restores the clipboard + targets the captured app; no-front-app reports false (no write, no clipboard touch) (`SelectionServiceTests`, +2).

## 2. Action-menu model (pure Core)

- [x] 2.1 Add `FilesMenuAction` (catalog enum: `copyAsPath, copy, pasteInto, openIn, openInTerminals, openInEditor, revealInFinder, addToFavorites, copyName`; named to avoid colliding with the existing `GestureBindings.FilesAction`) and a pure `FilesActionMenu` model holding two ordered `[FilesMenuAction]` lists (file, folder) with the **exact** defaults (file: copyAsPath/copy/pasteInto/openIn; folder: + openInTerminals before openIn). *(`Files/FilesActionMenu.swift`.)*
- [x] 2.2 `visibleRows(for entry: FileEntry, pasteboardHasFile: Bool, terminals: [FilesTool], editors:) -> [FilesMenuRow]`: resolve the ordered catalog into concrete rows for an entry — expand `openInTerminals` to one row per enabled terminal, hide `pasteInto` when no file is on the pasteboard, file vs folder set selection. Pure → unit-tested.
- [x] 2.3 Add a pure **keep-both name resolver** (`FilesPasteName.uniqueName`: `name` → `name copy` → `name copy 2` …) for Paste-into conflicts. Pure → unit-tested (no collision, single collision, repeated collisions, extension-preserving).
- [x] 2.4 Unit tests: defaults match the spec exactly; per-type independence; `pasteInto`/terminals visibility rules; Codable round-trip. *(`FilesActionMenuTests`, 14 tests.)*

## 3. Action-menu surface + drill wiring

- [x] 3.1 Repointed the Files-drill `+1`-finger excursion: `filesOpenWith()` now opens the **action menu** for **both files and folders** (Open-With folds in as the menu's "Open in ▸"); kept four-finger discard backing out and **re-arms the drill** on enter and back-out.
- [x] 3.2 Rendered the action menu as a scrubbable popup in `FilesBandView` (`actionMenuPopup`), modeled on the Open-With picker (single sliding highlight, vertical scrub, **lift commits**, discard closes). Added `LauncherModel.FilesActionMenuState` + `filesActionMenu` sub-state alongside `filesPicker`.
- [x] 3.3 Routed drill highlight/lift/discard to the menu while open (`filesActionMenuMove`/`exitFilesActionMenu`); depth ignored while a popup is open; "Open in ▸" descends into the app grid; discard backs out **one level** (grid → menu → folder list) via `filesPickerOriginEntry`.
- [x] 3.4 Commit dispatch (`filesCommitMenuRow`): a lift on a row runs its effect (§4); "Open in ▸" descends into the app grid; a tool row opens the folder in that terminal/editor.

## 4. Menu item effects

- [x] 4.1 **Copy as path** → write the standardized path to the live pasteboard; the clipboard **monitor** captures it into history (single source — no manual `ClipboardStore.insert`/double-capture). *(Simpler than the planned manual insert; same observable result.)*
- [x] 4.2 **Copy** → write the entry's `.fileURL` **object** to the pasteboard (files and folders) via `writeObjects([url as NSURL])`.
- [x] 4.3 **Paste into** → bounded `FileManager.copyItem` of the pasteboard's **file URLs** into the target (highlighted folder, or a file's **containing** folder), using the §2.3 keep-both resolver; **never** overwrite/move/delete. Added `FileActionError.pasteFailed` mapped at the boundary, surfaced as the bounded `filesOpenFailure` row.
- [~] 4.4 **Open in ▸** → reuses the existing scrubbable Open-With **picker** for files (`openWithCandidates`, default marked) AND folders (Finder + curated editors/terminals via `folderOpenerCandidates`); lift opens with the highlighted app; pure-trackpad. **Deferred:** the 2-D *grid* (app-drawer) layout — currently the vertical list; functionally complete, visual upgrade pending.
- [x] 4.5 **Terminals / Open in ‹editor›** → `openEntry(_:inToolBundleID:)` opens the folder (or a file's parent) in the chosen tool via `NSWorkspace.open(_:withApplicationAt:)` (CWD); tools from the auto-detected + curated set (§6.3 / `FilesToolCatalog`).
- [x] 4.6 **Extras** → Reveal in Finder (`activateFileViewerSelecting`); Add to Favorites (`.path` `LaunchItem` → `FavoritesStore.addItem`, home/first/new band); Copy name (`name` → pasteboard).

## 5. Open/save-panel delivery (follow-on)

> **Deferred** (design.md Decision 7 already frames this as an AX-gated follow-on). Reliable detection is **infeasible from here**: a **sandboxed** app's open/save panel runs in a SEPARATE process (the powerbox / `com.apple.appkit.xpc.openAndSavePanelService`), so it is **not in the captured front app's AX tree** at all — the front app's AX cannot confidently identify a panel. The graceful **fallback already runs**: delivery always uses the dual-representation pasteboard contract (§1), which a panel ignores without misfiring the common text/Finder cases (satisfying the spec's "uncertain → fall back to the contract" scenario). The `⌘⇧G`-drive enhancement needs on-device AX verification and is left as a follow-on.

- [~] 5.1 Conservative front-context detection of an open/save panel — **deferred** (sandboxed-panel separate-process limitation above).
- [x] 5.2 Fallback to the dual-representation contract is the **current behavior** for the picker case (no misfire into text/Finder).
- [~] 5.3 Detection-gate test — **deferred** with §5.1.

## 6. Customization: bindings + persistence + Hub

- [x] 6.1 **Lift action = an orthogonal `FilesLiftAction {deliver, open}` (NOT a binding restructure).** Implementation revealed that adding `deliver`/`openMenu` to `GestureBindings.FilesDrillBinding` would break its shipped one-to-one 3-excursion invariant + the in-flight change's tests/consumers. Instead: keep the drill binding intact (which excursion is primary/menu/discard); add `FilesLiftAction` (Core) + persisted `AppSettings.filesLiftAction` (default `.deliver`) deciding what the primary-resolve excursion *does*; the `+1`-finger excursion's handler (`filesOpenWith`) will open the action menu (Phase 3). *Artifact note: design.md Decision 9 / §6.1 reframed from "extend the vocabulary" to this less-invasive split — the spec deltas (`files-band`/`tunable-settings`) already describe a configurable lift action without mandating a binding-enum change.*
- [x] 6.2 Persist the per-type menu lists (`AppSettings.filesActionMenu`, Codable blob via `persistCodable`/`loadCodable`), defaulting to §2.1; included in reset; default-on-absent/unreadable. (Plus `filesLiftAction` from §1.3.)
- [x] 6.3 Persist the **curated terminals/editors** allow-list (`AppSettings.filesToolsDisabled` — bundle ids the user disabled; default empty = all enabled); detection via `detectFilesTools()` + `FilesToolCatalog`.
- [x] 6.4 Hub **Files page** (`HubFilesPage.swift`) gained an **Action menu** section: the lift-action picker (deliver/open → `filesLiftAction`), per-type menu editors (add/remove/reorder from the catalog, mirroring the roots rows), and terminal/editor curation toggles (`filesToolsDisabled`). The existing previewed header, drill-binding picker, roots, appearance, and behavior sections are unchanged.

## 7. Verify

- [x] 7.1 `swift build` + `swift test` green — **1012 tests, 0 failures**. Pure tests cover the representation builder (`FilesDeliveryTests`), `FilesActionMenu` defaults/visibility + keep-both rename (`FilesActionMenuTests`), `deliverFile` round-trip + no-front-app (`SelectionServiceTests`), and the new settings persistence/reset/defaults (`FilesActionSettingsTests`). The full product builds + links (Core + GemmaRuntime/MLX) via `swift build` here (Metal toolchain present). *(Picker-detection-gate test deferred with §5; `GestureBindings` not extended — `FilesLiftAction` is orthogonal, §6.1.)*
- [x] 7.2 `openspec validate add-files-band-actions --strict` passes. Spec deltas match the implementation **except** the two documented deferrals: open/save-panel navigation (§5 — sandboxed-panel limitation; the contract fallback runs) and the Open-in **2-D grid** layout (§4.4 — functional via the vertical picker; visual upgrade pending).
- [ ] 7.3 **User run-verify** in a stable-signed build (`INSTALL=1 ./scripts/build-app.sh`): lift on a file in a terminal pastes its **path**; lift with Finder front **copies the file in**; the `+1`-finger menu opens on a **folder** and a **file**; Copy-as-path lands in clipboard history; Paste-into copies a clipboard file into a folder (keep-both on conflict); Open in ▸ shows the chooser and opens with the highlighted app (files **and** folders); a folder opens in a chosen terminal at its CWD; the user clipboard is intact after a delivery; reordering a menu and rebinding lift to "open" both persist and take effect.
