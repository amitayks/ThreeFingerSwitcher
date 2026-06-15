## 1. Settings & opt-in

- [x] 1.1 Add `showDockPreviews` (Bool, default false) to `Settings/AppSettings.swift` with persistence, mirroring `useBuiltInPlayer`/Files-band opt-ins
- [x] 1.2 Surface a toggle on the Configuration Hub (new or existing page) gating the feature; copy explains it reuses existing permissions and needs no re-login
- [x] 1.3 Wire the flag so flipping it on/off installs/tears down the cursor monitor + Dock reader immediately (no `isEffective` gate, no re-login)

## 2. Core: pure models & seams (verify under `swift build`/`swift test`)

- [x] 2.1 Define `DockTile` (pid, frame, title) and a `DockReader` seam protocol (returns `[DockTile]` + Dock orientation + Dock display); add a stub/fake for tests
- [x] 2.2 Define a `CursorMonitor` seam protocol (start/stop, cursor-point callback); add a fake for tests
- [x] 2.3 Implement `DockHoverModel` — edge-gated hit-test (cursor + tiles → hovered pid/anchor), orientation-aware anchor rect (bottom = above, left/right = beside, away from edge), and the idle/tileHovered/previewOpen/dismissed lifecycle state machine
- [x] 2.4 Implement the unified live-zone + grace-dismiss logic (tile↔popup travel keeps open; moving to another tile swaps; leaving the zone past grace dismisses)
- [x] 2.5 Implement `DockPreviewModel` — row of windows (with minimized flag), stable per-window identity, hovered-card peek selection, commit selection
- [x] 2.6 Define a `DockPreviewError` Core `LocalizedError` taxonomy (parallel to `FileActionError`/`MediaPlayerError`) for commit failures, with a clean per-case headline
- [x] 2.7 Unit tests: hit-test math (bottom/left/right orientation, magnified frames), anchor placement, live-zone grace transitions, empty-app → no-popup, minimized inclusion, stable identity across re-lists

## 3. Core: window enumeration & raising variant

- [x] 3.1 Add an app-scoped, current-Space, **minimized-inclusive** enumeration variant to `WindowService` (filter by owner pid + `isOnCurrentSpace`; stop dropping the minimized subrole in this mode) returning each window's minimized flag; switcher enumeration untouched
- [x] 3.2 Add un-minimize-then-raise to the commit path (clear AX `kAXMinimizedAttribute`, then call existing `raise()`); non-minimized commit unchanged; raise hardening retained
- [x] 3.3 Unit tests for the enumeration variant filter (pid scope, current-Space scope, minimized inclusion + flag) and that switcher enumeration is unaffected

## 4. App boundary: Dock-AX & cursor glue

- [x] 4.1 Implement the real `DockReader` over the Dock's Accessibility tree (`AXUIElementCreateApplication(dockPid)` → tiles; resolve running-app tiles → pid + current frame; ignore folders/stacks/Trash/minimized-region/separators; read orientation + display); degrade to empty (no crash, no raw error) when unreadable
- [x] 4.2 Implement the real `CursorMonitor` as a passive global `.mouseMoved` monitor (no new permission); edge-gate to hot-mode re-reads only while the cursor is in the Dock strip; install only when the feature is enabled
- [x] 4.3 Handle auto-hide: treat hidden Dock as idle; re-read tile frames after reveal rather than caching

## 5. App boundary: the preview overlay

- [x] 5.1 Add a `DockPreviewOverlayController` reusing `SwitcherPanel` but **mouse-interactive** (accepts hover/click) and **non-activating** (never key/main, never the app's focus target); synchronous `orderOut` teardown
- [x] 5.2 Position the panel in the gap between tile and content so native Dock-icon clicks fall through to the system; anchor per orientation/display from `DockHoverModel`
- [x] 5.3 Build the SwiftUI row view: one card per window, minimized badge, hovered-card enlargement; bind to `DockPreviewModel`
- [x] 5.4 Wire peek to `ThumbnailService` (cached row thumbnails + `liveCapture` for the hovered card); retarget the live session on hover-change; end it on dismiss/no-hover
- [x] 5.5 Wire click → commit via the Core commit path (raise / un-minimize+raise); render commit failures as a bounded, non-blocking card (clean headline + opt-in copyable details) over the popup — no `NSAlert`
- [x] 5.6 Inject the `DockReader`, `CursorMonitor`, enumeration/raise, and thumbnail seams (wired in `AppCoordinator`, gated by `showDockPreviews`); coordinate lifecycle there. (AppKit/AX glue lives in MLX-free Core — only MLX is injected at `main.swift` — so the seam is constructed in `AppCoordinator`, not `main.swift`.)

## 6. Verification

- [x] 6.1 `swift build` + `swift test` green (Core models, enumeration variant, error taxonomy) — 846 tests, 0 failures
- [x] 6.2 `xcodebuild` compile-verify the app target (AX/cursor/overlay glue) — BUILD SUCCEEDED
- [ ] 6.3 Manual (user, stable-signed build): hover an app with multiple current-Space windows → row appears anchored to the tile; peek shows live content without disturbing the real window; click raises; minimized window un-minimizes + raises; app with no current-Space windows shows nothing
- [ ] 6.4 Manual: Dock orientations (bottom/left/right), auto-hide, magnification, and a Dock on a secondary display all anchor correctly; native Dock-icon clicks still work; feature off leaves the Dock untouched
- [x] 6.5 Update `CLAUDE.md` with a "Dock window previews — build & landmines" section (cursor-first surface, AX Dock read, live-projection peek, mouse-interactive panel, synchronous teardown)
