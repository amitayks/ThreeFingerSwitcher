## Why

The launcher stacks the band strip as a horizontal tab row **above** the icon grid, so bands compete with the grid for vertical space and read as secondary chrome. Moving the bands into a vertical **list on the left** — with the grid on the right — makes the band a first-class column you land on, scroll, and step through, and frees the grid's vertical axis for rows only. It also gives multi-band setups (apps + AI + clipboard) a natural "pick a band, then drill into items" shape.

## What Changes

- **Relocate the band strip** from a horizontal tab row above the grid to a vertical band-title list on the **left**, with the content (the 6-per-row icon grid) on the **right**. Grid layout and grid scrolling are otherwise unchanged.
- **Land on the band title on open** (multi-band): the launcher opens with focus on the band list at the home band, nothing armed. The trade-off is one short rightward step to reach the first item. **BREAKING** to deterministic home-cell entry: the entry point is now a band title, not a grid item, when more than one band exists.
- **Single band collapses to the grid only**: when there is exactly one band, no band list is shown and the launcher lands on the **first item** (armable immediately), exactly as today.
- **Navigation transpose (same swipe mechanics, relocated target).** The horizontal/vertical swipe plumbing and grid stepping do not change; only what the strip-axis points at moves:
  - Focus on the band list → **vertical** travel switches the active band (the existing *deliberate* band-step, relocated to the vertical axis); **horizontal right** crosses into the grid.
  - Focus in the grid → horizontal steps items within a row (unchanged); **horizontal left from the first column** crosses back to the band list; vertical steps between rows (unchanged) and clamps at the top/bottom (no longer rises to a header row).
- **Active band title stays vertically centered** in the band list; the list scrolls (with the already-implemented edge auto-repeat **acceleration**) when bands overflow, scrolling-to-keep the active title centered.
- **Min-height that grows to a max-height**, driven by the taller of the two panes. Both panes scroll independently; each scrolls-to-selected when its content exceeds the max-height.
- **Clipboard band adjusts** (only the clipboard): when it is the active band, the window extends to show its master-detail (key list + value preview) as the right pane. Horizontal crosses into the key list, vertical scrolls entries; **left** from the key list returns to the band list (replacing today's "left = previous band"); the deliberate **right** pin flick is preserved.
- **AI preview canvas is untouched** — AI commands are ordinary band items; the canvas is a separate surface opened after a command is fired.
- **Band-row visuals unchanged** — the list reuses today's tab text styling (no new color swatches).

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `launcher-overlay`: the launcher's layout (vertical band list + side grid), landing target (band title vs first item), the band-vs-grid navigation axes (vertical = switch band, horizontal = cross panes), the band-list centering/scrolling, the min→max window sizing with both panes scrollable, and the Clipboard band's horizontal/left semantics under the new shell.

## Impact

- **Code:** `LauncherView` (VStack tabs+grid → HStack band-list+content), `LauncherModel` (`Focus` semantics, `stepHorizontal`/`stepVertical` rewiring, landing focus, single-band case), `LauncherGridLayout` (band-column metrics, min/max height, drop `tabsHeight`), `LauncherOverlayController` (panel sizing with the band column, both-panes-scroll), `GestureRecognizer` (the deliberate band-step gate moves to the vertical axis when focus is on the band list), `AppCoordinator` (`launcherFocusIsOnHeaders` → band-list focus query).
- **Spec:** `openspec/specs/launcher-overlay/spec.md` (activation landing, item/context stepping, deterministic entry, edge auto-repeat axes, context-band visual encoding, Clipboard band navigation).
- **No new settings**, no new dependencies. The AI preview canvas, dwell-to-arm, and lift-fires-when-armed behaviors are unchanged.
