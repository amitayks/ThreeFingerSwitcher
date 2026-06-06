## ADDED Requirements

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
Moving a foreign app's window between Spaces is not possible without elevated system privileges (verified on-device: the private move/add APIs and an Accessibility minimize→restore all return success but have no effect). Therefore, when a single-window app's window is on another Space, the default behavior (`smart`, `bring-existing-here`) SHALL be to **go to the window**: switch to its Space and focus it via the same robust raise the window switcher uses. The system SHALL NOT silently teleport before this point (it MUST NOT activate the app while its window is off-Space). If a window is already on the current Space, the system SHALL focus it locally without any Space switch. As an explicit per-item opt-in, the `quit-and-reopen-here` strategy SHALL quit the app (gracefully, allowing it to save) and relaunch it so a fresh window opens on the current Space; this strategy SHALL never be chosen by `smart`.

#### Scenario: Single-window app on another Space — go to it
- **WHEN** a single-window app item is fired under smart/bring-existing-here and the app's window is on another Space
- **THEN** the system switches to that window's Space and focuses it, and does not first activate the app from the current Space (no double Space switch / no focus vacuum)

#### Scenario: Window already on the current Space is focused in place
- **WHEN** a single-window app item is fired and the app already has a window on the current Space
- **THEN** that window is focused without switching Spaces

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

#### Scenario: Path opens
- **WHEN** a path item is fired
- **THEN** the file or folder opens in its default handler

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
