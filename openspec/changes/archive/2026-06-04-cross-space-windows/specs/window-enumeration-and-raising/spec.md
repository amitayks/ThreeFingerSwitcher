## ADDED Requirements

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
