## Why

The built-in **Screenshot — Selection** and **Screenshot — Full Screen** actions save a PNG file to the Desktop, which the user then has to find, drag, or attach. macOS already supports capturing straight to the clipboard from the very same shortcuts (just add ⌃), so a per-item "save to clipboard" toggle lets the user grab a region and immediately paste it — no Desktop clutter, no new permission, no new capture code. It also dovetails with the in-flight clipboard-history feature: a screenshot taken to the clipboard becomes a scrubbable image entry in the Clipboard band.

## What Changes

- The `.action` launch-item kind gains a third, **Optional** associated value `screenshotToClipboard: Bool? = nil`, mirroring exactly how `ValueAdjustment? = nil` was added for the value control. `nil`/`false` preserves today's behavior, and — because the value is Optional, the synthesized decoder uses `decodeIfPresent` — favorites saved before this change decode unchanged (to `nil`).
- When `screenshotToClipboard` is on, firing **Screenshot — Selection** synthesizes ⌃⇧⌘4 and **Screenshot — Full Screen** synthesizes ⌃⇧⌘3 (the native "capture to clipboard" shortcuts) instead of ⇧⌘4 / ⇧⌘3. The capture goes **only** to the clipboard; no file is written to the Desktop.
- The toggle applies only to the two area/full-screen screenshot actions. **Screenshot — Tools** (⇧⌘5) opens the system toolbar, which carries its own "Save to" destination menu, so it does not get the toggle.
- The launcher editor's item inspector shows a **"Save screenshot to clipboard"** toggle for those two actions (and only those), beside where the volume/brightness value control already appears. The setting persists with the item.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `launch-actions`: the Screenshot — Selection and Screenshot — Full Screen actions gain an optional, per-item "save to clipboard" destination (default off = the current Desktop-file behavior; on = the native ⌃-modified capture-to-clipboard shortcut). The option is editable in the item inspector and persists backward-compatibly. Screenshot — Tools is unaffected.

## Impact

- **Modified code:**
  - `Launcher/LaunchItem.swift` — add `screenshotToClipboard: Bool? = nil` to the `.action` case; add a `SystemAction.supportsClipboardDestination` helper (true only for `screenshotSelection` / `screenshotFullScreen`), paralleling `isValueAdjustable`.
  - `Launcher/LaunchService.swift` — thread the new flag through `fire`'s `.action` dispatch into `perform(...)`; when set, OR `.maskControl` into the Selection/Full-Screen shortcut flags. Tools ignores it.
  - `Settings/FavoritesEditorView.swift` — render the toggle in the inspector for screenshot actions; update the two `if case let .action(action, adjustment)` matches to the new arity; bump the inspector height for the screenshot case.
  - `Tests/ThreeFingerSwitcherTests/ActionValueTests.swift` — update its `.action` pattern match to the new arity (the legacy-decode and round-trip tests otherwise stand).
- **New tests:** clipboard-destination round-trip + legacy decode + `supportsClipboardDestination`, and the pure shortcut/flag selection for screenshot actions.
- **Permissions:** none new — the synthesized ⌃⇧⌘3 / ⌃⇧⌘4 use the Accessibility/HID path the screenshot actions already use; the OS performs the capture, so no Screen Recording change and no temp-file surface.
- **Persistence:** no `schemaVersion` bump — the new associated value is an Optional trailing value, the same shape the value control used; pre-change favorites decode with `screenshotToClipboard == nil` (the synthesized decoder uses `decodeIfPresent`).
