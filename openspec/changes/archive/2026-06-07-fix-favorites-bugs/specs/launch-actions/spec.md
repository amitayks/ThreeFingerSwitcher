## ADDED Requirements

### Requirement: Arrow-key system shortcuts are synthesized faithfully
Built-in actions that work by synthesizing a system keyboard shortcut bound to an **arrow key** (notably Next/Previous Space, which post ⌃→ / ⌃←) SHALL synthesize an event that mimics a real arrow press — including both the numeric-pad flag and the secondary-Fn flag (on macOS the arrow keys are function keys, so a genuine arrow event carries both) in addition to the modifier. macOS's default Space-switch hotkey matches only such a faithful event; a synthetic arrow missing either intrinsic flag is dropped silently and the action does nothing, even though the corresponding physical shortcut works and other (non-arrow) synthesized shortcuts work.

#### Scenario: Next/Previous Space switches the Space
- **WHEN** the Next Space or Previous Space action is fired while the system Move-left/right-a-space shortcut is enabled and an adjacent Space exists
- **THEN** the system moves to the adjacent Space (the synthesized ⌃→ / ⌃← carries the numeric-pad flag so the WindowServer recognizes it)

#### Scenario: Non-arrow system shortcuts are unaffected
- **WHEN** a non-arrow system shortcut action is fired (e.g. a screenshot or lock screen)
- **THEN** it continues to fire without the numeric-pad flag, as before

### Requirement: Space-switch actions leave the destination's front window focused
After a Next/Previous Space action switches Spaces, the system SHALL establish real keyboard focus on the destination Space's front window (the native shortcut leaves it visually front but not key, so the user would otherwise have to click before typing). It SHALL wait until the active Space has actually changed before focusing, SHALL target the front-most switchable window of the new Space, and SHALL NOT move focus when the action did not change Spaces (e.g. there is no Space in that direction).

#### Scenario: Typing works immediately after switching
- **WHEN** a Next/Previous Space action switches to an adjacent Space that has a window
- **THEN** the front window of that Space becomes key, so keyboard input goes to it without a click

#### Scenario: No-op switch does not steal focus
- **WHEN** a Next/Previous Space action is fired but there is no Space in that direction (the Space does not change)
- **THEN** focus is left untouched

## MODIFIED Requirements

### Requirement: Single-window apps — go to the window, or quit-and-reopen here
Moving a foreign app's window between Spaces is not possible without elevated system privileges (verified on-device: the private move/add APIs and an Accessibility minimize→restore all return success but have no effect). Therefore, when a single-window app's window is on another Space, the default behavior (`smart`, `bring-existing-here`) SHALL be to **go to the window**: switch to its Space and focus it via the same robust raise the window switcher uses. The system SHALL NOT silently teleport before this point (it MUST NOT activate the app while its window is off-Space). If a window is already on the current Space, the system SHALL focus it locally without any Space switch. If the app is running but has **no windows on any Space**, the system SHALL reopen it via the workspace (the Dock-click equivalent that fires the app's reopen handler) so a fresh window opens on the current Space — it SHALL NOT merely activate the running process, which fronts the app without producing a window (a silent no-op). Because some apps (notably Mac Catalyst apps) ignore reopen while fully windowless, the system SHALL escalate **non-destructively**: if no window has appeared shortly after the reopen, it SHALL invoke the app's own new-window command (File ▸ New Window via Accessibility, else a synthesized ⌘N), without double-opening a window when the reopen already succeeded. An app that produces a window by neither reopen nor a new-window command SHALL require the explicit `quit-and-reopen-here` strategy; the non-destructive path SHALL never quit a running app on its own. As an explicit per-item opt-in, the `quit-and-reopen-here` strategy SHALL quit the app (gracefully, allowing it to save) and relaunch it so a fresh window opens on the current Space; this strategy SHALL never be chosen by `smart`.

#### Scenario: Single-window app on another Space — go to it
- **WHEN** a single-window app item is fired under smart/bring-existing-here and the app's window is on another Space
- **THEN** the system switches to that window's Space and focuses it, and does not first activate the app from the current Space (no double Space switch / no focus vacuum)

#### Scenario: Window already on the current Space is focused in place
- **WHEN** a single-window app item is fired and the app already has a window on the current Space
- **THEN** that window is focused without switching Spaces

#### Scenario: Running but windowless app reopens a window here
- **WHEN** a single-window app item is fired under smart/bring-existing-here, the app is running in the background, and it has no windows on any Space
- **THEN** the app is reopened via the workspace so a fresh window opens on the current Space (not a no-op activate), and no Space switch occurs

#### Scenario: Windowless app that ignores reopen gets a new-window command
- **WHEN** a windowless running app is reopened under smart/bring-existing-here and still has no window shortly after
- **THEN** the system invokes the app's own new-window command (File ▸ New Window, else ⌘N) without quitting the app, and does not double-open a window for apps where the reopen already produced one

#### Scenario: Quit-and-reopen-here opens a fresh window locally
- **WHEN** an app item whose strategy is quit-and-reopen-here is fired and the app is running on another Space
- **THEN** the app is quit and relaunched so a new window opens on the current Space, and smart never selects this strategy on its own
