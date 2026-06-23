## Why

The Hub's **General** page reads as three separate one-line cards (Reliability / Startup / Diagnostics), each holding a checkbox-style `Toggle`, and it buries the two diagnostic *actions* (Write Diagnostics, Copy Focus Log) inline on the page. The settings — Self-heal, Open at Login, Show diagnostic tools — are immediate on/off preferences that read more naturally as one grouped section of switches, and the diagnostic *actions* belong with the app's other quick actions in the menu-bar status menu (the "Show diagnostic tools" preference should gate their *visibility there*, not host the buttons). The Danger-zone selectors are also plain checkbox rows that would read better as a compact selectable grid.

## What Changes

- **General page → one switch section.** Collapse the three top cards (Reliability / Startup / Diagnostics) into a single titled **"General"** card of switch-style rows (`.switch` toggle, title + caption on the left, switch on the right, dividers between): Self-heal focus after switching, Open at Login, Show diagnostic tools.
- **Diagnostic actions move to the status menu.** Remove the inline **Write Diagnostics → /tmp** and **Copy Focus Log** buttons from the General page. When **Show diagnostic tools** (`showDiagnostics`) is on, these two actions appear as items in the menu-bar status menu (their own group, before Quit); when off (default) they appear nowhere. The "Show diagnostic tools" caption is updated to say it adds them to the menu-bar menu. **BREAKING (spec):** this reverses the prior decision that diagnostics live on the Hub's General page and never in the status menu.
- **Danger zone → 2×2 selectable toggle-cards.** The four reset-category selectors (App data & settings, Caches, AI models, Permissions) render as a 2×2 grid of full-body toggle-cards — the whole card is the click target and a selected card is highlighted. Selection semantics, confirmation flow, and the Clear-selected / Restore-native-gestures actions are unchanged.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `menubar-app-shell`: The status menu's "Status menu organization and diagnostics visibility" requirement is rewritten — the diagnostic actions (write diagnostics, copy focus log) now live **in the status menu**, gated by the show-diagnostics preference, instead of on the Hub's General page. The default-off behavior (shown nowhere when the preference is off) is preserved.
- `configuration-hub`: The General page no longer hosts the diagnostic action buttons (it keeps only the show-diagnostics *visibility* toggle, which now governs the status menu); the page's preference toggles are presented as one consolidated switch section; the General-page Danger-zone selectors are presented as a 2×2 selectable toggle-card grid (selective-clear behavior unchanged).

## Impact

- **Code:**
  - `Sources/ThreeFingerSwitcher/Hub/HubFeaturePages.swift` — `GeneralPage`: consolidate the three sections into one switch section; remove the inline diagnostics buttons; rebuild the Danger-zone selectors as a 2×2 toggle-card grid.
  - `Sources/ThreeFingerSwitcher/App/StatusItemController.swift` — `rebuildMenu()`: append a diagnostics group (Write Diagnostics, Copy Focus Log) when the show-diagnostics preference is on.
  - `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` — expose the show-diagnostics state (and the existing `writeDiagnostics()` / `copyFocusLog()` actions) to `StatusItemController`; trigger a menu rebuild when the preference flips.
  - Likely small additions to `Sources/ThreeFingerSwitcher/Hub/HubControls.swift` (or a new control file) for the switch-style row and the selectable toggle-card.
- **Persistence/permissions:** none — `showDiagnostics` (`AppSettings`) already exists and persists; no new keys, no new permissions, no gesture relocation.
- **Specs:** delta files for `menubar-app-shell` and `configuration-hub`.
