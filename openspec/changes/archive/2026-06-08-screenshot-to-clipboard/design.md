## Context

The two screenshot actions fire by synthesizing a native macOS shortcut to the HID event tap (`LaunchService.perform`):

```swift
case .screenshotSelection:  postKey(0x15, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘4
case .screenshotFullScreen: postKey(0x14, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘3
case .screenshotTools:      postKey(0x17, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘5
```

macOS routes the **identical** capture to the clipboard instead of a Desktop file when ⌃ is added: ⌃⇧⌘3 (full screen → clipboard), ⌃⇧⌘4 (selection → clipboard). The toolbar (⇧⌘5) instead exposes a "Save to" menu and has no modifier equivalent. So the whole feature is "OR `.maskControl` into the flags for two cases when a per-item flag is set" — plus the model, persistence, and inspector plumbing to carry that flag.

The directly-relevant precedent is the volume/brightness **value control** (`ValueAdjustment? = nil`), added as a trailing **Optional** associated value on the same `.action` case. Its `ActionValueTests.testLegacyActionItemDecodesWithoutAdjustment` proves that an `.action` blob encoded before the extra value (`{"action":{"_0":"volumeUp"}}`) still decodes. The reason — verified during implementation — is specifically that the value is **`Optional`**: Swift's synthesized enum `Codable` uses `decodeIfPresent` for an Optional associated value, so a missing key decodes to `nil`. (A *non*-optional value with a `= false` default does **not** decode when absent — the default participates only at construction sites, not in `init(from:)`; the legacy-decode tests caught this.) So the new value must likewise be `Bool?`, mirroring `ValueAdjustment?` exactly.

## Goals / Non-Goals

**Goals:**
- A per-item toggle on Screenshot — Selection and Screenshot — Full Screen that routes the capture to the clipboard (only), via the native ⌃-modified shortcut.
- Zero new permissions, zero new capture code, no temp files: the OS still performs the capture.
- Backward-compatible persistence with no `schemaVersion` bump; default-off preserves today's behavior.

**Non-Goals:**
- A "save to both file *and* clipboard" mode — macOS's native shortcuts are file-XOR-clipboard, and "both" would require us to capture via `screencapture`/CGDisplay ourselves (new code path, new file-write surface). Out of scope.
- A clipboard destination for Screenshot — Tools (the toolbar owns its own destination menu).
- Any change to where file-destination screenshots land, or to the clipboard-history feature itself (it merely benefits when both are on).

## Decisions

### Model the toggle as `screenshotToClipboard: Bool?`, not an enum

`case action(SystemAction, ValueAdjustment? = nil, screenshotToClipboard: Bool? = nil)`.

A `Bool?` (where `nil`/`false` = off, `true` = clipboard) is chosen over a `ScreenshotDestination { file, clipboard }` enum because:
- The user asked for a *toggle*; a boolean is the honest model and binds directly to a SwiftUI `Toggle` (read via `?? false`; an enum would force a `Picker` for a two-state choice).
- macOS offers exactly two native destinations and no modifier path to a third, so the enum's extensibility buys nothing today.
- An **Optional** trailing value reproduces the value-control shape precisely (`ValueAdjustment?`), inheriting its proven `decodeIfPresent` legacy-decode behavior — see Context. The inspector stores `nil` when off so the encoded form is byte-identical to a pre-feature item. (Widening `Bool?` → an Optional enum later is a self-contained future change if a third destination ever appears.)

*Alternative considered — new `SystemAction` cases* (`screenshotSelectionToClipboard`, …): rejected in exploration. It is not a "toggle," it doubles the screenshot tiles in the action browser, and it has no clean home for Tools.

### `supportsClipboardDestination` gates which actions show/honor the toggle

Add a computed `SystemAction.supportsClipboardDestination` returning `true` only for `screenshotSelection` and `screenshotFullScreen`, paralleling `isValueAdjustable`. The inspector shows the toggle exactly when this is true; `perform` only consults the flag for those cases. `screenshotTools` returns `false`, so the flag is inert for it even if somehow set.

### Effect: OR `.maskControl` into the flags, keep ⇧⌘ base

`perform(_:adjustment:toClipboard:)` gains the bool. For the two cases:
`flags: toClipboard ? [.maskControl, .maskShift, .maskCommand] : [.maskShift, .maskCommand]`.
The `LaunchService.swift:142-144` comment already establishes non-arrow shortcuts need no special flag handling, so adding ⌃ is safe. The pure flag-selection can be factored into a small `nonisolated static` helper so it is unit-testable without synthesizing events (mirroring `targetLevel`/`stepCount`).

### Inspector placement mirrors `valueControl`

In `FavoritesEditorView`, beside the existing `if case let .action(action, adjustment) = item.kind, action.isValueAdjustable { valueControl(...) }`, add `if case let .action(action, _, toClip) = item.kind, action.supportsClipboardDestination { Toggle("Save screenshot to clipboard", …) }`. The toggle's setter rebuilds the kind preserving the action and any (irrelevant here) adjustment. Bump `inspectorHeight` for the screenshot case.

## Risks / Trade-offs

- **Arity change ripples to every `.action` pattern match / construction.** → Small, enumerated set: dispatch in `LaunchService.fire`, two matches + the height switch in `FavoritesEditorView`, and the `.action` match in `ActionValueTests`. Constructions that omit the trailing value (`.action(action)`, `.action(action, newAdj)`) keep compiling because it is defaulted. The compiler flags any site missed.
- **Legacy favorites must still decode (a throw wipes favorites to seeded defaults).** → Covered by making the value `Optional` (`Bool?`), so synthesized `decodeIfPresent` yields `nil` for the absent key — *not* by the construction-site default, which does not apply on decode. A legacy-decode test with an `.action` blob that has no third value asserts it decodes to `nil`. (This was the one real trap, caught by the test during implementation.)
- **User confusion: "to clipboard" replaces the Desktop file rather than adding to it.** → The inspector toggle label/help states it captures to the clipboard only (matching the native ⌃ shortcut); "both" is explicitly a non-goal.
- **Verifying the actual capture-to-clipboard requires a signed on-device run** (synthesized shortcuts and pasteboard side effects can't be asserted in `swift test`). → Unit-test the pure flag selection and the model/persistence; the end-to-end clipboard capture is a manual on-device check (the standard split in this repo).

## Migration Plan

No data migration. `Favorites.currentSchemaVersion` stays at 1. New favorites encode the third value only when on (the inspector writes `nil` when off); old favorites omit it and decode to `nil` (file behavior). Rollback is a plain revert — any favorites saved with the flag decode fine under the old binary (the unknown trailing key is ignored on decode), losing only the toggle state, never the item.
