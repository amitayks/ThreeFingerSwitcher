## MODIFIED Requirements

### Requirement: Off-Space windows are enumerated
The system SHALL include normal windows that are not on the current Space — windows on other desktop Spaces, native-fullscreen Spaces, and windows (or Spaces) that existed before the app launched — using the private CoreGraphicsServices per-Space enumeration. Listing an off-Space window SHALL NOT require a *live* Accessibility element. The system SHALL obtain an element, in order, from: (a) remote-token brute force, (b) a persistent cache populated while the window was reachable (on its application's activation, or a prior snapshot) — a cached element stays valid across Spaces; and when no element is available at all (e.g. a Chromium window never yet focused), the system SHALL decide switchability from CoreGraphicsServices/CGWindowList metadata (normal window layer, non-zero alpha, and a real on-screen-sized frame). Minimized windows SHALL remain excluded, and the set and order of current-Space windows SHALL be unchanged from before this change.

#### Scenario: Window on another desktop Space is listed
- **WHEN** a normal window exists on a desktop Space other than the current one
- **THEN** it appears in the switcher list

#### Scenario: Native-fullscreen window is listed
- **WHEN** an app is in native fullscreen (its own Space)
- **THEN** its window appears in the switcher list

#### Scenario: Off-Space window with no resolvable Accessibility element is still listed
- **WHEN** a normal off-Space window's owning app exposes no Accessibility element reachable by remote-token brute force and none is cached (e.g. a Chromium-based browser window never focused this session)
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

### Requirement: Raise an off-Space window with a single Space switch
The system SHALL raise and key-focus a chosen off-Space window, causing exactly one Space switch, and only at commit (never during scrubbing). Current-Space windows SHALL continue to raise without any Space switch. The Space switch is driven by `kAXRaiseAction` on the window's Accessibility element. For a window whose element a fresh remote-token brute force cannot resolve (e.g. a Chromium window), the system SHALL raise it via an element captured in the persistent cache while the window was reachable; a cached element stays valid across Spaces and `kAXRaiseAction` on it performs the Space switch. The system SHALL NOT attempt a direct Space switch via private CoreGraphicsServices Space APIs — those are gated to the window server's privileged Dock connection and are inert for an unentitled process. When no element is available for a no-AX off-Space window, the raise SHALL front the owning application without switching Spaces and SHALL NOT crash.

#### Scenario: Commit to off-Space window switches once and focuses
- **WHEN** the user commits to a window on another Space that has a (live or cached) Accessibility element
- **THEN** the system switches to that Space exactly once and the window becomes frontmost with keyboard focus

#### Scenario: No-AX off-Space window navigates via its cached element
- **WHEN** the committed off-Space window exposes no Accessibility element reachable by remote-token brute force, but its element was cached earlier (its app was activated or it was enumerated on a visible Space)
- **THEN** `kAXRaiseAction` on the cached element switches to the window's Space and gives it keyboard focus

#### Scenario: No-AX window never seen on a visible Space
- **WHEN** the committed off-Space window has no live and no cached Accessibility element (a Chromium window that has been off-Space since before launch and never focused)
- **THEN** the raise fronts the owning application without switching Spaces, and does not crash (a documented limitation)

#### Scenario: Current-Space commit does not switch Spaces
- **WHEN** the user commits to a window on the current Space
- **THEN** the window is raised and focused with no Space switch

#### Scenario: Window closed mid-gesture
- **WHEN** the committed window no longer exists at commit time
- **THEN** the raise is a no-op and the app does not crash

### Requirement: Raising under Stage Manager does not start a focus war
When Stage Manager is enabled, raising a current-Space window SHALL NOT assert the per-application focus singletons (the window's `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`) — those make WindowManager's stage-front arbiter oscillate between windows of one application that share the center stage. It SHALL instead raise with `kAXRaiseAction` and activate the application. For an off-Space raise, WindowManager additionally grabs frontmost — leaving the application with no key window (a focus vacuum) — within roughly half a second after the Space switch settles; the system SHALL detect this and re-front the target window via a bounded, polling hold-guard, so keyboard focus is restored without user intervention and without a sustained window-order storm. The focus-vacuum protections (activation fallback and the post-commit watchdog) SHALL remain in effect. When Stage Manager is disabled, the raise SHALL be unchanged.

#### Scenario: Co-staged same-app windows do not oscillate
- **WHEN** Stage Manager is enabled with app-window grouping and two windows of one application share the center stage, and the user commits to one of them
- **THEN** focus settles on a window of that application and does not oscillate between the two windows (no sustained window-order churn after the commit)

#### Scenario: Chosen window still becomes frontmost under Stage Manager
- **WHEN** a current-Space window is committed while Stage Manager is enabled
- **THEN** the window is raised with `kAXRaiseAction` and its application is activated so it becomes frontmost with keyboard focus, without writing `kAXMainAttribute` or the application's `kAXFocusedWindowAttribute`

#### Scenario: Off-Space focus is restored after WindowManager steals it
- **WHEN** an off-Space window is committed while Stage Manager is enabled and WindowManager grabs frontmost (leaving no key window) shortly after the Space switch
- **THEN** the polling hold-guard re-fronts the target window so it regains keyboard focus within a fraction of a second, with no sustained reorder storm

#### Scenario: Behavior unchanged when Stage Manager is off
- **WHEN** Stage Manager is disabled and a window is committed
- **THEN** the full Accessibility sequence (`kAXRaiseAction` + `kAXMainAttribute` + the application's `kAXFocusedWindowAttribute`) plus activation runs exactly as before, and no hold-guard is needed (WindowManager does not steal frontmost)

#### Scenario: Vacuum safety net retained under Stage Manager
- **WHEN** Stage Manager is enabled and a raise would otherwise leave the frontmost application with no key window
- **THEN** the activation fallback and the +180ms watchdog still establish a key window (no focus vacuum)
