## Why

The switcher orders windows by **app**-MRU first, then raw z-order within each app. When several windows share one app (two Chromes, two Terminals), they clump together at the front — so picking one Chrome drags every other Chrome ahead of the window you actually alternate with. The window you last used gets buried behind windows you never touched, and the "one flick = previous window" muscle memory breaks. The switcher should order by the **window** you last focused, not the app.

## What Changes

- Introduce **window-level MRU**: a per-`CGWindowID` focus-recency history, replacing app-MRU as the primary sort key in the switcher snapshot. Windows interleave across apps by true focus recency (full interleave — no app clustering).
- Track focus history from **all** sources, not just switcher commits:
  - the switcher's own commit (`raise`),
  - app activations (`NSWorkspace.didActivateApplicationNotification`),
  - **external** within-app window focus changes (clicking another window, `Cmd-\``, Mission Control) via a live Accessibility focused-window observer on the frontmost app.
  So the *last* focused window and the *second*-to-last are always correct, even when the user switched outside the app.
- The current/frontmost window remains index 0; the previously focused window becomes index 1 — regardless of app.
- Windows never focused since launch fall back to today's exact ordering (current-Space first, then Mission Control Space order, then z-order), so nothing regresses for the single-window-per-app case.
- Ordering stays **ephemeral** (in-memory, resets on relaunch), matching today's app-MRU.

## Capabilities

### New Capabilities
<!-- none — window-level focus tracking is folded into the existing enumeration capability -->

### Modified Capabilities
- `window-enumeration-and-raising`: the "MRU ordering with z-order fallback" requirement becomes genuinely **window-level**; add a requirement for live window-focus tracking (commit + app activation + external focused-window changes) that feeds it.

## Impact

- **Code**: `Sources/ThreeFingerSwitcher/Windows/MRUTracker.swift` (app-level) is superseded/extended by a window-level focus tracker; `WindowService.snapshot()` + `legacySnapshot()` sort keys (`WindowService.swift:267`, `:302`); commit path `AppCoordinator.gestureDidCommit → windowService.raise` (`AppCoordinator.swift:692`); tracker lifecycle wired in `AppCoordinator` alongside the existing `mru.start()/stop()` (`AppCoordinator.swift:331`,`:345`). New AX focused-window observer (reuses `axWindowID` / `axCopy` in `AXPrivate.swift`).
- **Permissions**: no new permission — uses the Accessibility access the app already requires; degrades to activation-only tracking if absent.
- **Specs**: `window-enumeration-and-raising`. No new storage, no UI change, no activation-policy change.
