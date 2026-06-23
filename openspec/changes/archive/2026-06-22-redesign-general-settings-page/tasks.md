## 1. Reusable Hub controls

- [x] 1.1 Add a `SwitchRow` view to `HubControls.swift` — title + optional caption on the left, right-aligned `Toggle("", isOn:).labelsHidden().toggleStyle(.switch)`, in an `HStack` (caption styled like the existing `ToggleRow` caption).
- [x] 1.2 Add a `ToggleCard` view to `HubControls.swift` — a full-body button (whole card is the hit target) bound to a `Bool`, showing a title + caption, rendering a tinted highlight (fill/stroke) when selected, with toggle/selected accessibility semantics.

## 2. General page — consolidated switch section

- [x] 2.1 In `GeneralPage` (`HubFeaturePages.swift`), replace the three separate `HubSection`s (Reliability / Startup / Diagnostics) with one `HubSection("General")` containing three `SwitchRow`s separated by `Divider()`: Self-heal focus after switching, Open at Login, Show diagnostic tools.
- [x] 2.2 Preserve bindings/behavior: `focusWatchdogEnabled`, the Open-at-Login refresh-on-toggle binding, and `showDiagnostics`. Update the Show-diagnostic-tools caption to state it adds Write Diagnostics & Copy Focus Log to the menu-bar menu.
- [x] 2.3 Remove the inline `Write Diagnostics → /tmp` and `Copy Focus Log` buttons (and the `if settings.showDiagnostics { … }` block) from the page.

## 3. General page — Danger zone 2×2 toggle-card grid

- [x] 3.1 In `GeneralPage.dangerZone`, replace the four `ToggleRow`/`Divider` selectors with a 2×2 grid (`LazyVGrid` with two flexible columns, or two `HStack` rows) of `ToggleCard`s bound to the existing `wipeAppData` / `wipeCaches` / `wipeAIModels` / `wipePermissions` `@State` booleans (App data & settings, Caches, AI models, Permissions).
- [x] 3.2 Keep `dangerSelection` / `DangerZoneSelection`, the Clear-selected gating + confirmation, and the Restore-native-gestures action unchanged below the grid.

## 4. Diagnostics in the status menu

- [x] 4.1 Expose `showDiagnostics` from `AppCoordinator` (a read accessor delegating to `AppSettings.showDiagnostics`) for `StatusItemController` to read.
- [x] 4.2 In `StatusItemController.rebuildMenu()`, when `coordinator.showDiagnostics` is true, append a diagnostics group (its own divider-separated group, before Quit) with **Write Diagnostics → /tmp** and **Copy Focus Log** items wired to new `@objc` actions that call `coordinator.writeDiagnostics()` / `coordinator.copyFocusLog()`.
- [x] 4.3 Confirm the menu reflects the preference on next open (existing `menuNeedsUpdate` → `rebuildMenu`); no live observer needed. Verify the actions are absent when the preference is off.

## 5. Verify

- [x] 5.1 `swift build` and `swift test` (Core/test target) pass; `xcodebuild` compile-check the app target for the `StatusItemController`/`HubFeaturePages` changes.
- [x] 5.2 Run `openspec validate redesign-general-settings-page --strict` and confirm the General page (one switch section, no inline buttons, 2×2 danger grid) and the status menu (diagnostics group appears only when Show diagnostic tools is on) match the spec deltas.
