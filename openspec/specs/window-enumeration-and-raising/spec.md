# window-enumeration-and-raising Specification

## Purpose

Define enumeration of normal windows across all Spaces in MRU order, thumbnail capture via ScreenCaptureKit, and raising+focusing a chosen window using the Accessibility API and application activation.

## Requirements

### Requirement: Enumerate normal windows across all Spaces
The system SHALL enumerate normal application windows across all Spaces, excluding minimized windows by default, and SHALL snapshot this ordered list at the start of each gesture.

#### Scenario: Includes windows on other Spaces
- **WHEN** the window list is built
- **THEN** normal windows on Spaces other than the current one are included

#### Scenario: Excludes minimized windows
- **WHEN** a window is minimized
- **THEN** it is not included in the switcher list

#### Scenario: Snapshot is frozen during gesture
- **WHEN** a gesture begins
- **THEN** the ordered window list is captured once and not re-ordered while scrubbing

### Requirement: MRU ordering with z-order fallback
The system SHALL order the window list most-recently-used so a short flick lands on the previously focused window, falling back to on-screen z-order when usage history is incomplete.

#### Scenario: Previous window is adjacent
- **WHEN** the user has two windows and switches between them
- **THEN** the most-recently-used window is positioned so a single step reaches the previous one

#### Scenario: Fallback to z-order
- **WHEN** focus history is unavailable for some windows
- **THEN** those windows are ordered by on-screen stacking order

### Requirement: Thumbnail capture via ScreenCaptureKit
The system SHALL capture per-window thumbnails using ScreenCaptureKit and SHALL degrade to an app-icon placeholder when a thumbnail is unavailable or Screen Recording permission is not granted.

#### Scenario: Thumbnail rendered when permitted
- **WHEN** Screen Recording permission is granted and a window is on the list
- **THEN** a thumbnail image is captured and provided to the overlay

#### Scenario: Placeholder when capture unavailable
- **WHEN** a thumbnail cannot be captured for a window
- **THEN** the app icon is used as a placeholder

### Requirement: Raise and focus the chosen window
The system SHALL raise and focus a chosen window using the Accessibility API and application activation, bringing it forward and giving it keyboard focus.

#### Scenario: Commit raises and focuses
- **WHEN** a window is committed
- **THEN** it is raised (kAXRaiseAction), set as main/focused, and its application is activated so it has keyboard focus

#### Scenario: Cross-Space commit switches once
- **WHEN** the committed window is on another Space
- **THEN** the Space switch occurs exactly once at commit time, not during scrubbing

### Requirement: Thumbnails shown and refreshed on every overlay showing
The system SHALL display each window's thumbnail every time the overlay is shown — not only the first time — by applying any cached thumbnail immediately on show and refreshing (re-capturing) thumbnails so they stay current across repeated gestures.

#### Scenario: Cached thumbnail shown on repeat gesture
- **WHEN** the overlay is shown again for a window whose thumbnail was captured on an earlier gesture
- **THEN** the cached thumbnail is applied immediately so the card shows the preview (not icon-only)

#### Scenario: Thumbnail refreshed to stay live
- **WHEN** the overlay is shown
- **THEN** the visible windows' thumbnails are re-captured so the preview reflects current window content

#### Scenario: No duplicate concurrent captures
- **WHEN** a capture for a window id is already in flight
- **THEN** a second capture for the same id is not started

#### Scenario: Fallback unchanged when capture unavailable
- **WHEN** Screen Recording is not granted or a capture fails
- **THEN** the card falls back to the app-icon placeholder

### Requirement: Off-Space windows are enumerated
The system SHALL include normal windows that are not on the current Space — windows on other desktop Spaces, native-fullscreen Spaces, and windows (or Spaces) that existed before the app launched — using the private CoreGraphicsServices per-Space enumeration, correlated to Accessibility elements.

#### Scenario: Window on another desktop Space is listed
- **WHEN** a normal window exists on a desktop Space other than the current one
- **THEN** it appears in the switcher list

#### Scenario: Native-fullscreen window is listed
- **WHEN** an app is in native fullscreen (its own Space)
- **THEN** its window appears in the switcher list

#### Scenario: Window created before launch is listed
- **WHEN** a window or fullscreen Space was created before the app started
- **THEN** it still appears in the switcher list (acquired via remote-token brute force, not a window-created observer)

#### Scenario: Minimized still excluded; current Space unchanged
- **WHEN** the list is built
- **THEN** minimized windows are excluded and the set/order of current-Space windows is unchanged from before this change

### Requirement: Raise an off-Space window with a single Space switch
The system SHALL raise and key-focus a chosen off-Space window, causing exactly one Space switch, and only at commit (never during scrubbing). Current-Space windows SHALL continue to raise without any Space switch.

#### Scenario: Commit to off-Space window switches once and focuses
- **WHEN** the user commits to a window on another Space
- **THEN** the system switches to that Space exactly once and the window becomes frontmost with keyboard focus

#### Scenario: Current-Space commit does not switch Spaces
- **WHEN** the user commits to a window on the current Space
- **THEN** the window is raised and focused with no Space switch

#### Scenario: Window closed mid-gesture
- **WHEN** the committed window no longer exists at commit time
- **THEN** the raise is a no-op and the app does not crash

### Requirement: Crash-safe degradation when private Space APIs are unavailable
The system SHALL resolve all private Space/raise symbols at startup and, if any required symbol is missing, SHALL fall back to current-Space-only enumeration and raising — never crashing at launch and never regressing below the prior behavior.

#### Scenario: Missing private symbol degrades, not crashes
- **WHEN** a required private symbol cannot be resolved at startup
- **THEN** off-Space support is disabled, the app launches normally, and enumeration/raising use the current-Space path

#### Scenario: Private APIs available
- **WHEN** all required private symbols resolve
- **THEN** all-Spaces enumeration and off-Space raising are enabled

### Requirement: Off-Space thumbnails and titles degrade gracefully
The system SHALL show off-Space window thumbnails when available, and SHALL fall back to the app-icon placeholder and an app-name title when capture or an Accessibility title is unavailable.

#### Scenario: Off-Space thumbnail when capturable
- **WHEN** an off-Space window can be captured and Screen Recording is granted
- **THEN** its thumbnail is shown

#### Scenario: Off-Space window without resolvable title
- **WHEN** no Accessibility element or window title is available for an off-Space window
- **THEN** the card shows the app icon and the app name as the title

### Requirement: Raising never leaves a focus vacuum
Raising a window SHALL deterministically establish a key window — after a raise, exactly one application SHALL be frontmost with a key window, on the current Space or another Space. The raise SHALL always finish with an application activation fallback so a key window is established even if the SkyLight front/key handshake fails, and SHALL NOT leave a process fronted with no key window.

#### Scenario: Current-Space raise leaves a key window
- **WHEN** a current-Space window is committed
- **THEN** its application becomes frontmost with that window as the key window, and clicks/scroll/keyboard reach it without any Mission Control intervention

#### Scenario: Off-Space raise leaves a key window
- **WHEN** an off-Space window is committed
- **THEN** the Space switches once and its application becomes frontmost with a key window; if the SkyLight key handshake fails, the activation fallback still establishes key state

#### Scenario: No system-wide input freeze after repeated switches
- **WHEN** the user commits many window switches in succession across current- and off-Space targets
- **THEN** the system continues to accept clicks, scroll, and keyboard input after every commit (no focus vacuum)

#### Scenario: Key-window handshake reports failure
- **WHEN** the low-level key-window event posts fail
- **THEN** the raise falls back to Accessibility focus plus application activation rather than leaving no key window

### Requirement: Raising under Stage Manager does not start a focus war
When Stage Manager is enabled, raising a current-Space window SHALL NOT assert per-application focus singletons (the window's `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`). The system SHALL instead raise the chosen window with `kAXRaiseAction` and activate its application, so that committing onto one of two windows of the same application that share the Stage Manager center stage does not start a self-sustaining focus oscillation between them. The focus-vacuum protections (activation fallback and the post-commit watchdog) SHALL remain in effect. When Stage Manager is disabled, the current-Space raise SHALL be unchanged.

#### Scenario: Co-staged same-app windows do not oscillate
- **WHEN** Stage Manager is enabled with app-window grouping and two windows of one application share the center stage, and the user commits to one of them
- **THEN** focus settles on a window of that application and does not oscillate between the two windows (no sustained window-order churn after the commit)

#### Scenario: Chosen window still becomes frontmost under Stage Manager
- **WHEN** a current-Space window is committed while Stage Manager is enabled
- **THEN** the window is raised with `kAXRaiseAction` and its application is activated so it becomes frontmost with keyboard focus, without writing `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`

#### Scenario: Behavior unchanged when Stage Manager is off
- **WHEN** Stage Manager is disabled and a current-Space window is committed
- **THEN** the full Accessibility sequence (`kAXRaiseAction` + `kAXMainAttribute` + the application's `kAXFocusedWindowAttribute`) plus activation runs exactly as before

#### Scenario: Off-Space raise unaffected by Stage Manager
- **WHEN** the committed window is on another Space (regardless of Stage Manager state)
- **THEN** the off-Space SkyLight front/key handshake plus the full Accessibility sequence runs unchanged

#### Scenario: Vacuum safety net retained under Stage Manager
- **WHEN** Stage Manager is enabled and a raise would otherwise leave the frontmost application with no key window
- **THEN** the activation fallback and the +180ms watchdog still establish a key window (no focus vacuum)
