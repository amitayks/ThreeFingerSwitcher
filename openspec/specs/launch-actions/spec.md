# launch-actions Specification

## Purpose

Define how the launcher fires each launch-item kind — apps (without unexpected Space switches), paths, URLs, shortcuts, scripts, built-in system actions, and presets — including per-item/per-band strategy resolution and the single-window and new-window dispatch behaviors.
## Requirements
### Requirement: Firing an app yields a usable window without an unexpected Space switch
When firing an app item, the system SHALL produce a usable window without ever activating an app while its only windows are on another Space (which would silently teleport the user). If the app is not running it SHALL be launched (its first window opens on the current Space). If the app is running and is capable of multiple windows, the system SHALL create a new window for it on the current Space. If the app is running and is single-window with its window on another Space, the system SHALL apply the single-window strategy (go to the window, or quit-and-reopen here — see that requirement) rather than blindly activating it.

#### Scenario: Not running launches it
- **WHEN** an app item is fired and the app is not running
- **THEN** the app launches and its first window opens on the current Space

#### Scenario: Multi-window app gets a new window here
- **WHEN** an app item is fired, the app is running, and it supports multiple windows
- **THEN** a new window is created and the user is not taken to another Space

#### Scenario: No teleport for an app living elsewhere
- **WHEN** an app item is fired and the app's existing windows are on other Spaces
- **THEN** the current Space is not switched away

### Requirement: New window via the app's own menu, with capability detection
For the smart/new-window strategies, the system SHALL create a new window by locating the app's own "New Window" (or equivalent "New") menu item via the Accessibility API and performing its press action, falling back to synthesizing the new-window keyboard shortcut only when the menu item cannot be located. The presence of such a menu item SHALL be used to classify the app as multi-window-capable.

#### Scenario: Menu press creates the window
- **WHEN** a new window is requested for a capable app
- **THEN** the system presses the app's File ▸ New Window (or New) menu item via Accessibility

#### Scenario: Capability detection from the menu
- **WHEN** the system evaluates an app under the smart strategy
- **THEN** an app exposing a New Window/New menu item is treated as multi-window-capable, and one without it is treated as single-window

#### Scenario: Keystroke fallback
- **WHEN** no New Window/New menu item can be located for a capable app
- **THEN** the system synthesizes the new-window keyboard shortcut as a fallback

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

### Requirement: Per-item strategy with per-band default
Each app item SHALL resolve its strategy as its own explicit override if set, otherwise its context band's default strategy. The available strategies SHALL include smart, always-new-window, bring-existing-here, quit-and-reopen-here, and new-instance. New-instance (a separate process) and quit-and-reopen-here (destructive — it quits the app) SHALL only be used when explicitly chosen, never as a smart default.

#### Scenario: Item inherits band default
- **WHEN** an app item has no explicit strategy and its band default is bring-existing-here
- **THEN** firing the item resolves to the bring-existing-here behavior (go to the window)

#### Scenario: Item override wins
- **WHEN** an app item sets always-new-window while its band default is bring-existing-here
- **THEN** firing the item creates a new window

#### Scenario: New-instance is opt-in only
- **WHEN** an app is fired under the smart strategy
- **THEN** the system never spawns a second process; new-instance occurs only when explicitly selected

### Requirement: Fire paths, URLs, shortcuts, and scripts
The system SHALL open path items (file/folder) and URL items via the system opener, run shortcut items via Shortcuts.app, and execute script items (shell, AppleScript, or a script file). Consequential kinds (scripts and presets) SHALL surface a success or failure notification after firing.

A URL item SHALL open with its chosen handler application when one is set (else the system default). When the item requests a new window, the system SHALL attempt to open the link in a new window of that app on a best-effort basis (common browsers) and SHALL fall back to a normal open if that is not possible, so a link always opens. When it requests reuse (the default), the system SHALL open the link normally (reusing the app's existing window).

#### Scenario: Path opens
- **WHEN** a path item is fired
- **THEN** the file or folder opens in its default handler

#### Scenario: URL opens with the chosen app
- **WHEN** a URL item with an "open with" handler set is fired
- **THEN** the link opens in that application rather than the system default

#### Scenario: New-window preference is best-effort with a safe fallback
- **WHEN** a URL item requesting a new window is fired and the handler can open one
- **THEN** the link opens in a new window; otherwise it falls back to a normal open so the link still opens

#### Scenario: Shortcut runs
- **WHEN** a shortcut item is fired
- **THEN** the named Shortcuts.app shortcut runs

#### Scenario: Script reports result
- **WHEN** a script item is fired
- **THEN** the script executes and a success or failure notification is shown

### Requirement: Built-in system actions
The system SHALL support launch items that are built-in actions performed natively (Accessibility, NSWorkspace, the private Dock notification used for Mission Control, and synthesized key/media events) **without any new permission** (no Automation/Apple-Events, beyond the Accessibility and Screen Recording the app already holds). Actions whose target is "the front app/window" SHALL act on the application that was frontmost when the launcher opened (captured at open time, since the overlay is non-activating). Actions SHALL be addable from the editor's Actions source, grouped by category (Window, App, System, Media & Display). The set SHALL include at least: window management (minimize, zoom, toggle full screen, maximize, center, left/right/top/bottom half, four quarters, close front window, close all windows); app control (new window, hide front app, hide others, quit, force-quit); system (Mission Control, App Exposé, Show Desktop, next/previous Space, lock screen, screen saver, sleep display, empty Trash, screenshots); and media/display keys (play-pause, next, previous, volume up/down/mute, brightness up/down).

#### Scenario: A front-window action targets the pre-launcher front window
- **WHEN** a window action (e.g. close front window, minimize, tile) is fired from the launcher
- **THEN** it acts on the window that was frontmost when the launcher opened, without launching a helper process or requesting a new permission

#### Scenario: AX path falls back to a keystroke when unavailable
- **WHEN** a window lacks the relevant Accessibility affordance (e.g. no close button, or full-screen not settable)
- **THEN** the system synthesizes the equivalent keystroke to the owning app instead

#### Scenario: Actions are browsable by category
- **WHEN** the user opens the Actions source in the editor
- **THEN** the available actions are listed grouped by category and selecting one adds it to the active band

### Requirement: Presets fire their items in order
Firing a preset SHALL fire each referenced item in its stored order using the same dispatch as a directly-fired item, and SHALL report overall success or failure.

#### Scenario: Preset runs its steps in order
- **WHEN** a preset containing an app, a path, and a script is fired
- **THEN** each item is fired in the stored order

#### Scenario: Preset reports completion
- **WHEN** a preset finishes firing its items
- **THEN** a notification reports overall success or which step failed

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

### Requirement: Volume and brightness actions support an optional value control
The volume and brightness actions (`volumeUp`, `volumeDown`, `brightnessUp`, `brightnessDown`) SHALL support an optional per-item value control with two modes, performed natively and **without any new permission**:
- **Absolute** — set the level directly to a target percentage (e.g. volume = 30%).
- **Relative** — change the current level by a percentage-point amount; the action's direction selects the sign (Up adds, Down subtracts).

When no value control is set, the action SHALL retain its current behavior (synthesize the native media/brightness key, stepping by the OS increment). Levels SHALL be clamped to the valid 0–100% range. Volume SHALL be controlled via the system audio service and brightness via the display service; where a level cannot be read or set (e.g. some external displays), the system SHALL fall back to native key-stepping rather than failing or requesting a permission.

#### Scenario: Absolute sets the exact level
- **WHEN** a volume or brightness action with an absolute control of N% is fired
- **THEN** the corresponding level is set to N% (clamped to 0–100%), regardless of the action's up/down direction

#### Scenario: Relative changes by an amount
- **WHEN** a Volume Up (or Brightness Up) action with a relative control of N% is fired
- **THEN** the level increases by N percentage points from its current value (clamped); the Down variant decreases by N

#### Scenario: No control keeps native stepping
- **WHEN** a volume or brightness action with no value control is fired
- **THEN** it steps by the OS increment exactly as before

#### Scenario: Unsupported target falls back, never fails
- **WHEN** an absolute/relative control is fired but the level cannot be read or set (e.g. an external display without brightness control)
- **THEN** the system falls back to native key-stepping and does not crash or request a new permission

### Requirement: Value control is editable per item
The launcher editor SHALL let the user configure the value control on a volume or brightness action item: choosing Step (default), Set to a percentage, or Change by a percentage, and entering the percentage for the latter two. The setting SHALL persist with the item, and existing saved items (which predate the control) SHALL load unchanged with no control set.

#### Scenario: Configure a value action in the inspector
- **WHEN** the user selects a volume or brightness action item in the editor
- **THEN** the inspector offers Step / Set to % / Change by % and a percentage entry for the latter two, saved to the item

#### Scenario: Older favorites load without a control
- **WHEN** favorites saved before this feature are loaded
- **THEN** their action items decode successfully with no value control (native stepping), and favorites are not reset

### Requirement: Screenshot actions support a save-to-clipboard destination
The **Screenshot — Selection** and **Screenshot — Full Screen** actions SHALL support an optional, per-item "save to clipboard" destination, performed natively and **without any new permission**. When the option is **off** (the default), the action SHALL retain its current behavior — synthesize the native file-capture shortcut (⇧⌘4 for selection, ⇧⌘3 for full screen), which writes a file to the user's screenshot location. When the option is **on**, the action SHALL synthesize the native capture-to-clipboard shortcut (⌃⇧⌘4 for selection, ⌃⇧⌘3 for full screen) by adding the Control modifier to the same base shortcut, so the capture goes **only** to the clipboard and no screenshot file is written.

The option SHALL apply only to the Selection and Full Screen actions. The **Screenshot — Tools** action (⇧⌘5) SHALL NOT support the option, because the system screenshot toolbar carries its own "Save to" destination menu; it SHALL continue to open the toolbar unmodified.

#### Scenario: Default keeps the file capture
- **WHEN** a Screenshot — Selection or Screenshot — Full Screen action with the save-to-clipboard option off is fired
- **THEN** the system synthesizes the unmodified ⇧⌘4 / ⇧⌘3 shortcut and the capture is written to a file exactly as before

#### Scenario: Toggle on captures to the clipboard only
- **WHEN** a Screenshot — Selection (or Screenshot — Full Screen) action with the save-to-clipboard option on is fired
- **THEN** the system synthesizes ⌃⇧⌘4 (or ⌃⇧⌘3), the capture is placed on the clipboard, and no screenshot file is written to the Desktop

#### Scenario: Tools action ignores the option
- **WHEN** the Screenshot — Tools action is fired
- **THEN** it opens the system screenshot toolbar via the unmodified ⇧⌘5, regardless of any clipboard setting, and lets the toolbar's own destination menu decide where the capture goes

#### Scenario: No new permission
- **WHEN** a screenshot action is fired with the save-to-clipboard option on
- **THEN** the capture uses only the Accessibility/HID path the screenshot actions already use (the OS performs the capture) and requests no additional permission

### Requirement: Screenshot clipboard destination is editable per item
The launcher editor SHALL let the user toggle "save to clipboard" on a Screenshot — Selection or Screenshot — Full Screen action item from the item inspector, and SHALL NOT offer the toggle for any other action (including Screenshot — Tools). The setting SHALL persist with the item. Existing saved items (which predate this option) SHALL load unchanged with the option off, with no schema-version bump and no loss of the item.

#### Scenario: Configure a screenshot action in the inspector
- **WHEN** the user selects a Screenshot — Selection or Screenshot — Full Screen action item in the editor
- **THEN** the inspector offers a "save to clipboard" toggle whose state is saved to the item

#### Scenario: Toggle is not offered for other actions
- **WHEN** the user selects a Screenshot — Tools action, or any non-screenshot action, in the editor
- **THEN** no save-to-clipboard toggle is shown for that item

#### Scenario: Older favorites load without the option
- **WHEN** favorites saved before this option are loaded
- **THEN** every `.action` item decodes successfully with the save-to-clipboard option off, and the favorites are not reset to defaults

