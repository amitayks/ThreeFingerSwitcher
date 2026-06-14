## 1. Settings & opt-in (foundation)

- [x] 1.1 Add `filesBandEnabled` opt-in to `AppSettings` (default **false**, `Defaults` + `Keys` entries, `didSet` persist) mirroring `keepClipboardHistory` — a pure software gate, **no** `is…Effective` gate.
- [x] 1.2 Add Files tunables to `AppSettings` (persisted, live-applied): roots list (local folder bookmarks/paths), column width/density, tint, icon-vs-preview, sort order, default-open action, and which metadata a row shows.
- [x] 1.3 Add per-root **remembered-location** persistence (a `root → last path` map) so each root restores where the user left off.

## 2. Filesystem domain — Core, MLX-free, testable

- [x] 2.1 Define a `FileEntry` value type: stable id **derived from the absolute path**, name, isDirectory, modDate, type/kind (AppKit-free where possible).
- [x] 2.2 Implement a `DirectoryLister`: async `contentsOfDirectory(at:includingPropertiesForKeys:[.isDirectoryKey,.contentModificationDateKey,.isRegularFileKey])` on a detached `userInitiated` task; **local-only**; returns `[FileEntry]` sorted by the configured order; map FileManager errors into the shared error taxonomy at the boundary.
- [x] 2.3 Implement `FilesNavigationModel` (pure stack): ancestors + current folder + highlighted index; `descend`/`ascend` transitions; roots entry and back-out-to-roots; per-root remembered-location restore **gated by `restoreLastLocation` at init AND in `enterRoot`** (toggle OFF lands on the root top, never the remembered folder — bug fix); preview-target derivation (file→self, folder→its contents); top-of-list up simply clamps.
- [x] ~~2.4 Implement the live **search filter**~~ — **REMOVED** (amendment): type-to-filter search is gone; the navigator is pure-trackpad.
- [x] 2.5 Unit tests: descend pushes ancestor / ascend pops / back-out-to-roots; remembered-location restore on re-entry (toggle ON) and the no-jump regression (toggle OFF); stable-id stability across re-list; preview-target for file vs folder; top-of-list up clamps.

## 3. File open / Open-With service — Core seam + workspace boundary

- [x] 3.1 Define a `FileWorkspace` protocol (`open(url)`, `open(url, withApp:)`, `urlsForApplications(toOpen:)`, `urlForApplication(toOpen:)`) so logic is testable against a stub; the real conformer wraps `NSWorkspace`.
- [x] 3.2 Implement `FileOpenService`: open-in-default (window lands on the current Space, **not** via `SpaceWindowMover`); Open-With enumeration via `urlsForApplications(toOpen:)` with the default app indicated, mapped to the existing `AppCandidate`; open-with-chosen-app; all targeting the **captured front app**; map workspace errors into the taxonomy and surface an observable `.failed`, never silent.
- [x] 3.3 Implement the **defusable open**: a held `PendingOpen` with `commit()`/`cancel()`, a short pre-launch fuse (retained `Task`/timer) cancelled on discard; **never terminates an already-running app**.
- [x] 3.4 Unit tests (against the stub workspace): default open routes to default app; Open-With lists only capable apps with the default indicated; chosen-app open; defuse cancels a pending open and opens nothing; a failure surfaces a clean bounded headline (no raw error text).

## 4. LaunchItem `.fileEntry` kind

- [x] 4.1 Add an **ephemeral** `.fileEntry(FileEntry)` case to `LaunchItemKind` (`LaunchItem.swift:192`), never-persisted (modeled on `.clipboardEntry`, not `.aiCommand`), id == `entry.id`.
- [x] 4.2 Satisfy every exhaustive `switch item.kind` (compiler-guided): `LaunchItem.isConsequential:215`, `LaunchService.fire:56`, `LauncherView.kindMarker:213` + `iconView:199`, `LauncherModel.isPinned:106`, and the new view's extractor.

## 5. FilesBandBuilder — the synthetic band

- [x] 5.1 Add `FilesBandBuilder` with its **own** sentinel `bandID` UUID (distinct from clipboard/AI), name, color, icon, `build(currentColumn:) -> ContextBand` mapping `FileEntry → LaunchItem` (stable ids), and an `isFilesBand(_:)` matcher. Never written to `FavoritesStore`.

## 6. LauncherModel gating + column navigation

- [x] 6.1 Add `filesBandIndex: Int?` + `currentBandIsFiles` to `LauncherModel`; extend `setBands(...)` to accept/store it; make `currentColumns` return 1 for the Files band.
- [x] 6.2 Route Files-band navigation in `stepHorizontal`/`stepVertical`: horizontal → depth (descend/ascend through `FilesNavigationModel`, then rebuild current items à la `applyCurrentBand`); vertical → highlight (top-of-list up clamps — no search); apply the same `reverseDirection`/`reverseVerticalDirection` settings.
- [x] 6.3 Hold the `FilesNavigationModel` state in/alongside `LauncherModel` and rebuild the band's `items` from the current column on every depth change.

## 7. Recognizer drill-in sub-state

- [x] 7.1 Add `filesDrillActive` + private baseline scalars to `GestureRecognizer`; add the **second** early short-circuit at the very top of `feed()` (immediately after the canvas check, line 161) routing to a new sustained `trackFilesDrill(frame)`.
- [x] 7.2 Implement `trackFilesDrill`: alive while `count >= 2`; **re-baseline** origin + carry on every contact-count change (copy 435-441); emit depth (horizontal) / highlight (vertical) with direction-reversal; detect **relative +1 finger** (`count > drillContacts`) → pending Open-With latch; fresh four-finger horizontal swipe → discard; one-shot resolution on lift (`belowTargetFrames >= 2` debounce): plain lift → open, +1-latched lift → open-with.
- [x] 7.3 Add delegate methods `filesDepth`/`filesHighlight`/`filesOpen`/`filesOpenWith`/`filesDiscard` to `GestureRecognizerDelegate` with default no-op extensions.
- [x] 7.4 Unit tests: depth/highlight emission; relative +1-finger detection incl. baseline 3→4; re-baseline suppresses phantom steps on relax/add; one-shot resolution (stray re-lift = no-op); four-finger horizontal discard.

## 8. AppCoordinator wiring + injection

- [x] 8.1 In `launcherDidActivate()` (724-750), under `filesBandEnabled`, append `FilesBandBuilder.build(...)` to the **local** `bands` copy and set `filesBandIndex = bands.count-1`; thread it through `show(...) → setBands(...)`. Keep out of `Favorites`.
- [x] 8.2 Wire `launcherOverlay.onFilesColumnStateChanged = { active in recognizer.filesDrillActive = active }` (mirror 243-245); implement the new delegate methods to forward intents to the overlay/model.
- [x] 8.3 Route open / open-with / discard resolutions to `FileOpenService` targeting `capturedFrontApp` (740); surface failures via the bounded `.failed` state (no app-modal alert).
- [x] 8.4 Add the wizard-tour twin at `ctx.launcherBands` (1757) so Files appears in onboarding with sample roots when none are configured — or explicitly skip with a code comment. (Skipped for v1 onboarding with an explanatory comment — the Files band is a live controller-backed drill surface the static tour can't meaningfully exercise.)

## 9. BubbleMorph — the app's first spring

- [x] 9.1 Add `Overlay/BubbleMorph.swift`: a `ViewModifier` (+ `View.bubbleMorph(anchor:)`) doing `scaleEffect(0.02 → 1, anchor:)` + opacity on `.spring(response: 0.34, dampingFraction: 0.72)`, entrance on `.onAppear` / membership / depth change, with an exit path for structural changes.
- [x] 9.2 Confirm it does **not** retrofit the existing charge ramp (`linear(dwell)`) or arm snap (`easeOut`); keep haptics to the single `.alignment` arm tick.

## 10. FilesBandView — the column navigator

- [x] 10.1 Add `Overlay/FilesBandView.swift`: icon-rail ancestors + current full list + live preview, bounded width at any depth, observing `LauncherModel`.
- [x] 10.2 Promote the private `FilePreview` (`ClipboardBandView.swift:202-228`) to internal; embed it for files (QuickLook, icon fallback); add the folder-contents **peek** for folder highlights.
- [x] 10.3 Single **sliding** selection highlight (clone `RowHighlight`/`SelectionSquare`) — never per-row; bubble only row content / structural changes.
- [x] 10.4 Depth transition: collapse-current-into-ancestor-icon / bloom-icon-into-current via `.id(depth)` + scale transition (the `SwitcherView` idiom, scaling not sliding).
- [x] ~~10.5 The type-to-filter **search field**~~ — **REMOVED** (amendment): no search field, no `@FocusState`, no key-interactive panel flip; an up-step at the top of the column clamps.
- [x] 10.6 The **Open-With** menu surface (bubble-morph), driven by the held Open-With resolution.
- [x] 10.7 Wire `FilesBandView` into `LauncherView.body` before the grid fallback (order: canvas → clipboard → files → grid).
- [x] 10.8 Fill with the availability-gated `glassEffect(.regular[.tint], in:)` / `.ultraThinMaterial` idiom (clone `bandIconBackground`/`HubGlass`).

## 11. LauncherOverlayController — panel sizing & lifecycle

- [x] 11.1 Add a `FilesBandLayout` (or reuse) in `LauncherGridLayout`; branch `layout(...)` (397-415) on `currentBandIsFiles` to size the panel to the depth's **final** frame.
- [x] 11.2 Add the held-state lifecycle: on a resolving lift keep the panel **visible** (the `.aiCommand` exception in `end()`); enter/exit flips `onFilesColumnStateChanged`.
- [ ] 11.3 Animated teardown for the receding exit: animate `shown = false` then **delay** `panel.close()`.
- [x] 11.4 ~~Suppress **horizontal** edge auto-repeat for the Files band~~ — **REVERSED** (depth-parity refinement): `setEdgeAutoScroll` now keeps horizontal auto-repeat for the Files band (only Clipboard suppresses it), so holding depth at the border auto-drills the tree — full launcher parity, per the user's request. Depth is also position-tracking (not out-and-back) in `configureFilesNav`/`updateFilesDrill`.
- [x] 11.5 Only if a real `ScrollView` is introduced: add a `filesDrillActive` carve-out to `shouldConsumeScroll` + flip the panel key-interactive; otherwise keep it gesture-only.

## 12. Hub — Files page

- [x] 12.1 Add a **Files** page to the Hub grouped sidebar + an Overview master toggle for `filesBandEnabled`.
- [x] 12.2 Roots editor: add / remove / reorder **local** folders (reject network/iCloud), via a security-scoped folder picker; persists to the roots list.
- [x] 12.3 Appearance controls (column width/density, tint, icon-vs-preview), reusing `AppearanceEditor` where it fits.
- [x] 12.4 Behavior controls (sort order, default-open action, metadata shown); persist + live-apply; shared Liquid Glass styling.

## 13. Verification & docs

- [x] 13.1 `swift build` + `swift test` green — the existing 614 tests plus the new navigation / open-service / recognizer tests.
- [x] 13.2 `xcodebuild` compile-check the MLX-linked app target (the new files must compile in the app; the MLX split is untouched).
- [x] 13.3 Update `README.md` (B1 repo map + the 30-second feature brief) and `CLAUDE.md` landmines (the files-drill modal sub-state, the first-spring/bubble-morph rule, the relative +1-finger rule, the defuse-never-kills-a-running-app rule).
- [x] 13.4 Hand the user a manual in-app smoke checklist (stable-signed build): land on Files band → descend/ascend → preview → open → Open-With → discard mid-open → remember-last-folder toggle on/off → bubble-morph feel.
