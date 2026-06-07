## 1. Data model & on-disk store

- [x] 1.1 Add `Clipboard/ClipboardEntry.swift`: a `Codable` value type with id, `capturedAt`, source-app bundle id, a derived single-line `key`, a `kind` (text / richText / image / file / color / url), a `pinned` flag, and a representation map (UTI → inline bytes or a blob reference). No AppKit in the model (mirror `LaunchItem.swift`'s AppKit-free, testable style).
- [x] 1.2 Add `Clipboard/ClipboardStore.swift`: an on-disk store under Application Support — a small JSON index + a blob directory for image/thumbnail payloads — with a `schemaVersion` for forward migration. Keep it fully separate from `FavoritesStore`/UserDefaults.
- [x] 1.3 Implement de-duplication: inserting content equal to an existing entry updates that entry's recency instead of adding a duplicate (pure, unit-testable key/equality logic).
- [x] 1.4 Implement retention caps (count, total bytes, age) with oldest-non-pinned-first eviction; pinned entries exempt from count/age eviction.
- [x] 1.5 Implement pin/unpin persistence and a `recentWindow(limit:)` accessor that returns the most-recent N entries with pinned entries ordered first (the band-build slice).

## 2. Recorder / monitor

- [x] 2.1 Add `Clipboard/ClipboardMonitor.swift`: poll `NSPasteboard.general.changeCount` on a tunable interval; snapshot only when it advances; run only while the opt-in is on and not paused.
- [x] 2.2 Multi-representation capture: rich text → rich + plain fallback; inline image → image bytes; file → file-URL reference (+ optional cached content thumbnail); color/URL → canonical string; derive the entry `key` and source app.
- [x] 2.3 Privacy filter: skip items tagged `org.nspasteboard.ConcealedType` / `TransientType`; skip copies whose source app is on the exclusion list; honor the pause flag.

## 3. Settings: opt-in, tunables & UI

- [x] 3.1 In `Settings/AppSettings.swift`, add a `keepClipboardHistory` opt-in (default OFF) plus tunables: recent-window size, retention caps (count/bytes/age), poll interval, edge-acceleration sensitivity, the excluded-apps list, and a pause flag. Ensure older settings decode with the opt-in OFF (no reset).
- [x] 3.2 In `Settings/SettingsView.swift`, surface the toggle, the tunables, a "Clear history" action (with an option to also clear pinned), and excluded-apps management. Wire the toggle to start/stop the monitor and to gate band injection — no re-login, no native-gesture change, no new permission.

## 4. Synthetic Clipboard band

- [x] 4.1 Add `Clipboard/ClipboardBandBuilder.swift`: build an ephemeral `ContextBand`-shaped Clipboard band from `ClipboardStore.recentWindow` (recent slice, pinned-first). Represent entries as a synthetic, non-persisted launcher cell (not user-creatable, never serialized into the Favorites record).
- [x] 4.2 In `App/AppCoordinator.swift`, when the opt-in is on, append the Clipboard band as the **last** band passed to `launcherOverlay.show(...)`; never set it as the home band; show an empty state when history is empty.

## 5. Overlay model & navigation

- [x] 5.1 In `Overlay/LauncherModel.swift`, mark the Clipboard band as a distinct band kind/style (single-column master-detail). In that band, vertical travel scrubs between entries (rows) and at the top rises to the headers as today.
- [x] 5.2 Repurpose horizontal travel in the Clipboard band: RIGHT toggles the selected entry's pin (deferred reorder — selection stays put this session); LEFT switches to the previous band, dropping the selection into that band's grid. Require a dominant horizontal step so vertical scrubbing never pins by accident.
- [x] 5.3 Wire pin toggle through to `ClipboardStore` (persist), keeping the live list order unchanged for the rest of the session; best-effort haptic + pin indicator on toggle.

## 6. Master-detail rendering & previews

- [x] 6.1 In `Overlay/LauncherView.swift` (or a new `Overlay/ClipboardBandView.swift`), render the Clipboard band as a key list (left, multi-line, type glyph + pin indicator) and a large value preview (right).
- [x] 6.2 Value preview shows actual content: rendered `NSImage` for image entries; a QuickLook content preview (`QLThumbnailGenerator`) for file entries (not the file icon); full text for text entries; a color swatch for color entries. Overflow may clip (no focusable/scrollable value pane).
- [x] 6.3 Size the Clipboard-band panel large enough to show several keys and a sizeable value preview at once (its own metrics, independent of `LauncherGridLayout`).

## 7. Edge-triggered scroll acceleration

- [x] 7.1 Add an edge signal: detect when the controlling contact is in the edge zone of the trackpad (normalized position near 0/1 on the scroll axis) via `Gesture/GestureRecognizer.swift` / `TouchInput/TouchEngine.swift`, exposed to the overlay controller.
- [x] 7.2 In `Overlay/LauncherOverlayController.swift`, run an accelerating auto-repeat that advances the selection while the edge condition holds (and the list overflows), stopping when the contact leaves the edge, reverses, or lifts. Make edge zone / base rate / acceleration / max rate tunable; no-op on lists that fit.

## 8. Paste on fire

- [x] 8.1 Add the paste path (in `Launcher/LaunchService.swift` or a sibling): on firing a Clipboard entry, restore its representations to `NSPasteboard.general` and synthesize ⌘V to the captured front-app pid (reuse the existing key-synthesis + `capturedFrontApp`). The chosen entry becomes the current clipboard.
- [x] 8.2 Handle a stale file reference gracefully (no crash, no harmful paste); split the paste decision logic so it is unit-testable without system access.

## 9. Tests

- [x] 9.1 `ClipboardStore` tests: de-dup (no duplicate, recency bump), retention eviction (oldest-non-pinned first, pinned exempt), pin persistence, `recentWindow` ordering (pinned-first), and schema-version load/migration.
- [x] 9.2 Capture tests: representation selection per kind and concealed/transient + excluded-app skipping (pure helpers, no live pasteboard).
- [x] 9.3 Navigation tests: in the Clipboard band, vertical scrubs entries; a dominant RIGHT toggles pin without moving the selection; a dominant LEFT lands in the previous band; jittery vertical does not pin.
- [x] 9.4 Edge-acceleration tests: auto-advance starts at the edge with overflow, accelerates over time, stops on leave/reverse/lift, and no-ops when the list fits.
- [x] 9.5 Paste-decision tests: representations chosen for re-paste per kind; stale-reference path is safe.

## 10. Build & spec sync

- [x] 10.1 `swift build` and `swift test` green. Do NOT assemble/sign/install the `.app` from the agent shell (per CLAUDE.md); leave in-app + permission/paste verification to the user's own stable-signed build.
- [x] 10.2 After implementation, run `/opsx:sync` (or `openspec`) to fold the `clipboard-history`, `launcher-overlay`, and `tunable-settings` deltas into the main specs, then archive the change.
