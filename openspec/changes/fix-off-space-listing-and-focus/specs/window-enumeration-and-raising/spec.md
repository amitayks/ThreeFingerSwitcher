## MODIFIED Requirements

### Requirement: Off-Space windows are enumerated
The system SHALL include normal windows that are not on the current Space — windows on other desktop Spaces, native-fullscreen Spaces, and windows (or Spaces) that existed before the app launched — using the private CoreGraphicsServices per-Space enumeration. Listing an off-Space window SHALL NOT require a resolvable Accessibility element: when remote-token brute force resolves an element, the system SHALL apply the Accessibility subrole filter as before; when it does not (e.g. Chromium-based apps, whose off-Space windows expose no reachable element), the system SHALL decide switchability from CoreGraphicsServices/CGWindowList metadata (normal window layer, non-zero alpha, and a real on-screen-sized frame) so the window is still listed. Minimized windows SHALL remain excluded, and the set and order of current-Space windows SHALL be unchanged from before this change.

#### Scenario: Window on another desktop Space is listed
- **WHEN** a normal window exists on a desktop Space other than the current one
- **THEN** it appears in the switcher list

#### Scenario: Native-fullscreen window is listed
- **WHEN** an app is in native fullscreen (its own Space)
- **THEN** its window appears in the switcher list

#### Scenario: Off-Space window with no resolvable Accessibility element is still listed
- **WHEN** a normal off-Space window's owning app exposes no Accessibility element reachable by remote-token brute force (e.g. a Chromium-based browser window on another Space)
- **THEN** the window is still listed, with switchability decided by CoreGraphicsServices metadata (layer, alpha, frame) rather than by the Accessibility subrole

#### Scenario: Shadow and companion windows still excluded
- **WHEN** the per-Space enumeration surfaces an invisible companion or shadow window (zero alpha, degenerate frame, or non-normal layer) that has no Accessibility element
- **THEN** the CoreGraphicsServices heuristic rejects it so it does not appear as a duplicate in the switcher list

#### Scenario: Window created before launch is listed
- **WHEN** a window or fullscreen Space was created before the app started
- **THEN** it still appears in the switcher list, whether or not a remote-token element resolves for it

#### Scenario: Minimized still excluded; current Space unchanged
- **WHEN** the list is built
- **THEN** minimized windows are excluded and the set/order of current-Space windows is unchanged from before this change

### Requirement: Raising under Stage Manager does not start a focus war
When Stage Manager is enabled, raising SHALL NOT assert per-application focus singletons (the window's `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`) toward a window that shares a Stage Manager stage with other windows of the same application — on the current Space, or on the destination Space after an off-Space raise. For a current-Space window the system SHALL raise with `kAXRaiseAction` and activate its application. For an off-Space window the system SHALL run the SkyLight front/key handshake, `kAXRaiseAction`, and activation; when the destination application is co-staged (two or more of its windows share the destination stage) the system SHALL establish and hold keyboard focus with a window-specific mechanism rather than the per-application focus singletons, so the raise does not start a self-sustaining focus oscillation. A lone (non-co-staged) target MAY use the per-application focus singletons. The focus-vacuum protections (activation fallback and the post-commit watchdog) SHALL remain in effect. When Stage Manager is disabled, the raise SHALL be unchanged.

#### Scenario: Co-staged same-app windows do not oscillate
- **WHEN** Stage Manager is enabled with app-window grouping and two windows of one application share the center stage, and the user commits to one of them
- **THEN** focus settles on a window of that application and does not oscillate between the two windows (no sustained window-order churn after the commit)

#### Scenario: Chosen window still becomes frontmost under Stage Manager
- **WHEN** a current-Space window is committed while Stage Manager is enabled
- **THEN** the window is raised with `kAXRaiseAction` and its application is activated so it becomes frontmost with keyboard focus, without writing `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`

#### Scenario: Off-Space raise into a co-staged app holds keyboard focus
- **WHEN** the committed window is on another Space and its application has two or more windows that will share the destination Stage Manager stage
- **THEN** the Space switches once, the chosen window becomes frontmost with keyboard focus, and focus is not lost or oscillated after the destination stage settles

#### Scenario: Lone off-Space raise holds keyboard focus
- **WHEN** the committed off-Space window is the only window of its application on the destination stage
- **THEN** the Space switches once and the window becomes frontmost with keyboard focus

#### Scenario: Behavior unchanged when Stage Manager is off
- **WHEN** Stage Manager is disabled and a window is committed
- **THEN** the full Accessibility sequence (`kAXRaiseAction` + `kAXMainAttribute` + the application's `kAXFocusedWindowAttribute`) plus activation runs exactly as before, on both the current-Space and off-Space paths

#### Scenario: Vacuum safety net retained under Stage Manager
- **WHEN** Stage Manager is enabled and a raise would otherwise leave the frontmost application with no key window
- **THEN** the activation fallback and the +180ms watchdog still establish a key window (no focus vacuum)
