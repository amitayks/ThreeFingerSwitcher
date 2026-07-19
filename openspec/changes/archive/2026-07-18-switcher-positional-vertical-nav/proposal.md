# Proposal: switcher-positional-vertical-nav

## Why

Vertical navigation in the switcher grid is positionally blind: moving to an adjacent visual row always lands on that row's **first (leftmost) card** (`SwitcherModel.moveVertical` → `rows[r±1].first`), and crossing a Space edge resets the selection to column 0. With two or more rows, "up" from the middle or right of a row teleports the highlight to the far left — the user cannot travel straight up/down through the grid the way the cards are actually arranged. The ⌘-Tab driver is worse: its Up/Down arrows skip grid rows entirely and jump straight to the adjacent Space. All the geometry needed to fix this (per-card sizes, row composition, spacing, centered rows) already exists in the solved `SwitcherGridLayout`, so true positional navigation is a pure-model change.

## What Changes

- **Positional (sticky-x) vertical movement within a Space**: an up/down step lands on the card in the adjacent visual row whose horizontal span is nearest the selection's x-center — not the row's first card.
- **Preferred-x anchor**: the selection's x-center is captured when a run of vertical steps starts and reused for every subsequent vertical step in that run, so travelling up through several rows doesn't drift sideways through narrow cards. Any horizontal step (or a fresh show) clears the anchor.
- **Positional Space-edge crossing**: scrubbing up past the top row lands in the next Space's **bottom** row at nearest-x (spatially continuous with the reel); scrubbing down past the bottom row lands in the previous Space's **top** row at nearest-x — replacing the column-0 reset. A fresh open (and the ⌘-Tab linear Tab/Shift-Tab reel flow) is unchanged.
- **⌘-Tab arrows adopt grid navigation**: Up/Down step between visual grid rows within the current Space exactly like the trackpad's vertical scrub, switching Space only at the grid's top/bottom edge (landing positionally). Left/Right, Tab/Shift-Tab linear flow, commit, and Esc are untouched.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `switcher-overlay`: the "Grid navigation within a Space" requirement changes from land-on-first-card to positional nearest-x landing with a sticky preferred-x anchor; the "Animated row switching" requirement changes the *vertical-scrub edge crossing* landing from first-card/bottom-left to positional (bottom row nearest-x going up, top row nearest-x going down).
- `command-tab-switcher`: the "Arrow keys navigate the open switcher" requirement changes Up/Down from jump-to-adjacent-Space to grid-row navigation identical to the trackpad's vertical scrub (Space switch only at the grid edge).

## Impact

- **Code** (all MLX-free Core; verified by `swift build` / `swift test`):
  - `Sources/ThreeFingerSwitcher/Overlay/SwitcherModel.swift` — `moveVertical` gains positional landing + the preferred-x anchor; `moveHorizontal` clears the anchor; a positional entry point for the Space-switch landing.
  - `Sources/ThreeFingerSwitcher/Overlay/SwitcherLayout.swift` — pure helpers to compute card x-centers from `rows` + `sizes` + spacing (rows are centered), reused by the model.
  - `Sources/ThreeFingerSwitcher/Overlay/OverlayController.swift` — plumb the positional Space-switch landing (today `updateRow` resets to column 0).
  - `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` — `gestureDidStepRow` / `switchSpace` pass the vertical direction so the landing row+column is positional; ⌘-Tab arrow Up/Down delegate routes to the same grid-vertical path instead of the Space jump.
  - `Sources/ThreeFingerSwitcher/Gesture/KeyboardSwitcher.swift` — doc/comment update only (its `arrow` enum stays; the delegate's handling changes).
  - `Tests/ThreeFingerSwitcherTests/SwitcherModelTests.swift` — new coverage for nearest-x landing, anchor stickiness/reset, and positional Space-edge crossing.
- **No new permissions, no persistence, no UI chrome changes** — the moving highlight simply lands where the user aimed.
- **Specs**: delta files for `switcher-overlay` and `command-tab-switcher`.
