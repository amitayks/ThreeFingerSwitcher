> Adds Cut (move-on-Paste) + Delete (to Trash) to the action menu, makes Paste dual-mode, and fits the menu to its content. MLX-free Core + app; `swift build` / `swift test` verify the pure catalog + name resolver, `xcodebuild` compile-verifies the app target, the live move/trash/menu-size are user run-verify. Depends on `add-files-band-actions` (the menu + Paste-into) and composes with `add-files-band-dwell-arm` (the commit gate). Archive **after** `add-files-band-actions`.

## 1. Catalog + model (pure Core)

- [x] 1.1 Added `FilesMenuAction.cut` and `.delete` to the catalog enum (`Files/FilesActionMenu.swift`).
- [x] 1.2 New defaults: `defaultFileItems` = `[copyAsPath, copy, cut, pasteInto, openIn, delete]`; `defaultFolderItems` = `[copyAsPath, copy, cut, pasteInto, openInTerminals, openIn, delete]` (Delete last); `cut`/`delete` added to `defaultCatalog`.
- [x] 1.3 Extended `FilesActionMenuTests` (now 16): defaults contain cut/delete in order for both types (`testDefaultMenusMatchSpec`, updated `testFileRows…`/`testFolderRows…`/`testPasteIntoHidden…`); `testCutAndDeleteAreDefaultForBothTypesAsPlainRows` (plain `.action` passthrough, Delete last, in `defaultCatalog`); `testCutAndDeleteSurviveCodableRoundTrip`.

## 2. Effects + errors (boundary)

- [x] 2.1 Added `FileActionError.trashFailed(name:details:)` (`Files/FileWorkspace.swift`) + its clean `errorDescription` headline + `copyableDetails` (both exhaustive switches updated).
- [x] 2.2 **Cut** (`performMenuAction` `.cut`): writes the entry's `fileURL` to the pasteboard and records `pendingCut = (sources, pb.changeCount)`; `copy`/`copyAsPath`/`copyName` clear `pendingCut` (an explicit copy supersedes a cut; the change-count check also covers external writes).
- [x] 2.3 **Dual-mode Paste** (`performPasteInto`): `isMove = pendingCut?.changeCount == NSPasteboard.general.changeCount`; when true `moveItem` (keep-both target name via `FilesPasteName`) and clear `pendingCut`; else `copyItem` as before. Failure → `pasteFailed` bounded row + rearm (unchanged).
- [x] 2.4 **Delete** (`performMenuAction` `.delete` → `deleteEntry`/`performDelete`): `FileManager.trashItem(at:resultingItemURL:)`; success dismisses; failure → `trashFailed` bounded row + `rearmDrill`. No `removeItem` path. Captured as the retryable `lastFilesOpen` so the failure row's Retry re-trashes.

## 3. View

- [x] 3.1 Added `.cut` ("Cut" / `scissors`) and `.delete` ("Delete" / `trash`) to `FilesBandView.menuRowLabel` / `menuRowGlyph` (exhaustive switches) — which also names them in the data-driven Hub editor (`FilesMenuAction.allCases` + these labels/glyphs; no Hub code change).
- [x] 3.2 **Fit BOTH popups to their content (width + height):** shared `popupWidth(labels:header:trailing:)` (widest label at the real 13pt font + glyph + trailing chevron/"Default"-badge + paddings, clamped `[170, 340]`) and `popupHeight(rowCount:)` (header + rows×`pickerRowHeight` + padding, clamped to the `pickerMaxHeight` safety cap) applied as a **definite** `width × height` to `actionMenuPanel` AND `pickerPanel` (the Open-With grid). Removed the fixed `pickerWidth`. The single sliding highlight (`maxWidth: .infinity`) still spans the definite width.

## 4. Verify

- [x] 4.1 `swift build` green (Core + GemmaRuntime + app executable link locally). `swift test` green — **1022 tests, 0 failures** (FilesActionMenuTests 14 → 16; the move/trash/measure are app/AppKit paths — compile-verified).
- [x] 4.2 `openspec validate add-files-band-file-operations --strict` passes. (The `files-action-menu` catalog-defaults enumeration from `add-files-band-actions` is extended by this change's ADDED requirements; reconcile at archive time, archiving this **after** `add-files-band-actions`.)
- [ ] 4.3 **User run-verify** in a stable-signed build (`INSTALL=1 ./scripts/build-app.sh`): the menu shows Cut + Delete on a file and a folder and is **compact** (fits its content in **both** width and height) — and the **Open-With grid** likewise fits its app names + row count; **Cut** then **Paste** into another folder **moves** the entry (gone from the source, keep-both on name clash); **Copy** then **Paste** still **copies**; a **Copy between Cut and Paste** makes Paste copy (cut superseded); **Delete** moves the entry to the **Trash** (recoverable); a fast scrub-and-lift on Delete dismisses (no deletion — the dwell-arm guards it); removing/reordering Cut/Delete in the Hub persists.
