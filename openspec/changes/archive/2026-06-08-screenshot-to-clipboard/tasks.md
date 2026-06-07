## 1. Model

- [x] 1.1 In `Launcher/LaunchItem.swift`, change the `.action` case to `case action(SystemAction, ValueAdjustment? = nil, screenshotToClipboard: Bool? = nil)` (trailing **Optional** — same shape as the value control; Optional is required so synthesized `decodeIfPresent` lets pre-feature items decode).
- [x] 1.2 Add a computed `SystemAction.supportsClipboardDestination` returning `true` only for `.screenshotSelection` and `.screenshotFullScreen` (paralleling `isValueAdjustable`).
- [x] 1.3 Confirm `LaunchItem.isConsequential` and any other `.action` matches in `LaunchItem.swift` still compile (the case list match on line ~195 ignores associated values, so it is unaffected).

## 2. Effect (LaunchService)

- [x] 2.1 Add a `nonisolated static` pure helper that, given a `SystemAction` and `toClipboard: Bool`, returns the `(keyCode, CGEventFlags)` for the screenshot shortcut — OR-ing `.maskControl` into `[.maskShift, .maskCommand]` only for Selection/Full Screen when `toClipboard` is true; Tools always returns the unmodified ⇧⌘5.
- [x] 2.2 Update `perform(_:adjustment:)` to `perform(_:adjustment:toClipboard:)` and route the three screenshot cases through the helper from 2.1.
- [x] 2.3 Update the `.action` dispatch in `fire(_:inBand:)` to destructure the third value and pass it to `perform`.

## 3. Editor (FavoritesEditorView)

- [x] 3.1 Update the two `if case let .action(action, adjustment) = item.kind` / `if case let .action(action, _) = item.kind` sites to the new arity.
- [x] 3.2 Add an inspector `Toggle("Save screenshot to clipboard", …)` shown only when `action.supportsClipboardDestination`, placed beside the existing `valueControl`; its setter rebuilds `.action(action, adjustment, newValue)` via `store.updateItem`.
- [x] 3.3 Add a short caption under the toggle clarifying it captures to the clipboard only (no Desktop file), and bump `inspectorHeight` for the screenshot case.

## 4. Tests

- [x] 4.1 In `Tests/ThreeFingerSwitcherTests/ActionValueTests.swift`, update the `case let .action(action, adjustment)` match in `testLegacyActionItemDecodesWithoutAdjustment` to the new arity (`, _`).
- [x] 4.2 Add a test asserting `supportsClipboardDestination` is true for Selection/Full Screen and false for Tools and non-screenshot actions.
- [x] 4.3 Add a Codable round-trip test for a screenshot action with `screenshotToClipboard == true`.
- [x] 4.4 Add a legacy-decode test: an `.action` blob with no third value (e.g. `{"action":{"_0":"screenshotSelection"}}`) decodes with `screenshotToClipboard == false`.
- [x] 4.5 Add tests for the 2.1 helper: Selection/Full Screen with `toClipboard` true add `.maskControl` (and false do not); Tools never adds it.

## 5. Verify

- [x] 5.1 `swift build` and `swift test` pass. (Clean build; 308/308 tests green, incl. the new screenshot/legacy-decode tests.)
- [x] 5.2 Spec delta noted for archive (`/opsx:archive` syncs `specs/launch-actions/spec.md` into the main spec); confirmed no `schemaVersion` bump was needed (`Favorites.currentSchemaVersion` stays 1, legacy-decode tests pass).
- [x] 5.3 (User, on-device, signed build) Add a Screenshot — Selection action, enable the toggle, fire it, confirm the capture lands on the clipboard (paste into an app) and no file appears on the Desktop; with clipboard-history on, confirm it shows as an image entry in the Clipboard band.
