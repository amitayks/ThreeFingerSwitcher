# per-app-keyboard-language Specification

## Purpose
TBD - created by archiving change per-app-keyboard-language. Update Purpose after archive.
## Requirements
### Requirement: Opt-in, off by default
The per-app keyboard language feature SHALL be disabled by default and SHALL only operate while the user has enabled it. While disabled, the system SHALL NOT read or change the keyboard input source, SHALL NOT register any activation or input-source observers, and SHALL NOT modify the persisted per-app memory.

#### Scenario: Disabled by default does nothing
- **WHEN** the app launches and the feature has never been enabled
- **THEN** the keyboard input source is never read or changed, and switching between apps does not affect the keyboard language

#### Scenario: Disabling stops all activity
- **WHEN** the user turns the feature off
- **THEN** the system stops observing app activations and input-source changes and makes no further reads or writes to the input source

#### Scenario: Enabling starts observing without retroactive change
- **WHEN** the user turns the feature on
- **THEN** the system begins observing app activations and input-source changes, but does not change the current input source until the next app activation

### Requirement: Per-app memory keyed by bundle identifier
The system SHALL remember the keyboard input source associated with an application, keyed by the application's bundle identifier, as the durable unit of memory. The remembered source SHALL be a concrete input-source identifier (e.g. `com.apple.keylayout.Hebrew`), not a language code. An application that has no bundle identifier SHALL be ignored by the feature (neither learned nor applied).

#### Scenario: Memory is per application, not per window
- **WHEN** an application with multiple windows has a remembered input source
- **THEN** the same remembered source applies to the application regardless of which of its windows is focused

#### Scenario: Application without a bundle identifier is ignored
- **WHEN** a frontmost process exposes no bundle identifier
- **THEN** the system neither records nor applies an input source for it, and takes no other action

### Requirement: Auto-learn the input source per app from the user's usage
While the feature is enabled, the system SHALL remember, for each application, the input source that was in use when focus last left that application — the last source the user used while it was frontmost. This memory SHALL be captured automatically (the system reads the application's current source as focus moves away from it); this implicit capture SHALL be the only way per-app memory is written, and there SHALL be no separate per-app override editor. An application's remembered source SHALL be independent of input-source changes the user makes in other applications, and the system SHALL NOT record its own programmatic source changes as an application's choice.

#### Scenario: The source used in an app is remembered
- **WHEN** the feature is enabled, the user uses Hebrew while WhatsApp is frontmost, and then switches focus to another application
- **THEN** Hebrew becomes WhatsApp's remembered input source

#### Scenario: Last source used wins
- **WHEN** the user switches to English while WhatsApp is still frontmost and then leaves WhatsApp
- **THEN** English (the last source used while WhatsApp was frontmost) replaces Hebrew as WhatsApp's remembered input source

#### Scenario: An app's memory is unaffected by activity in other apps
- **WHEN** an app A has Hebrew remembered, and the user then switches to app B, changes B's input source to English, and switches back to A
- **THEN** A is restored to Hebrew — A's remembered source is independent of the input-source changes made in B

### Requirement: Auto-apply the remembered source on app activation
While the feature is enabled, when an application becomes frontmost the system SHALL select that application's remembered input source. The system MAY skip the call when the remembered source already equals the current source.

#### Scenario: Returning to a known app restores its language
- **WHEN** the feature is enabled, WhatsApp's remembered source is English, and the user activates WhatsApp
- **THEN** the keyboard input source is set to English

#### Scenario: No redundant switch
- **WHEN** an app becomes frontmost and the current input source already equals its remembered source
- **THEN** the system does not perform a redundant selection

### Requirement: Global default for apps with no memory
The system SHALL allow the user to choose a single global default input source, selected from the user's enabled input sources. While the feature is enabled, when an application that has no remembered source becomes frontmost, the system SHALL select the global default. If no global default has been chosen, the system SHALL leave the current input source unchanged for such applications and begin learning from the next user change. An application is treated as "unseen" whenever it has no entry in per-app memory, including applications first encountered after the app launched.

#### Scenario: Unseen app gets the global default
- **WHEN** the global default is English and the user activates an application the system has no memory for
- **THEN** the keyboard input source is set to English

#### Scenario: No global default leaves unseen apps unchanged
- **WHEN** no global default has been chosen and the user activates an application the system has no memory for
- **THEN** the input source is left unchanged, and a subsequent user change for that app is learned normally

#### Scenario: Global default does not override learned memory
- **WHEN** an application already has a remembered source that differs from the global default
- **THEN** activating that application selects its remembered source, not the global default

### Requirement: Memory survives both the target app quitting and our relaunch
Per-app memory SHALL be persisted durably so that it survives the target application quitting and relaunching, and survives ThreeFingerSwitcher itself quitting and relaunching. Persistence SHALL be versioned to allow forward migration.

#### Scenario: Survives the target app quitting
- **WHEN** an app with a remembered source quits and is later relaunched
- **THEN** activating it restores the previously remembered source

#### Scenario: Survives our own relaunch
- **WHEN** ThreeFingerSwitcher quits and relaunches with the feature still enabled
- **THEN** previously remembered per-app sources are still applied on activation

### Requirement: Failure to select a source is silent and non-disruptive
If selecting an input source fails (for example, a remembered or default source has since been disabled in System Settings), the system SHALL keep the current input source, SHALL NOT surface a modal or blocking error, and SHALL continue operating for other applications. Such failures MAY be logged but SHALL NOT be presented as user-facing alerts.

#### Scenario: Disabled source fails gracefully
- **WHEN** an app's remembered source has been disabled in System Settings and the app becomes frontmost
- **THEN** the current input source is left unchanged, no alert is shown, and the feature keeps working for other apps

### Requirement: Hub configuration surface
The configuration Hub SHALL expose a "Keyboard Language" page providing exactly two controls: a toggle to enable or disable the feature, and a picker for the global default input source populated from the user's enabled input sources. The feature SHALL also be represented as an opt-in feature row in the Hub Overview consistent with other opt-in features.

#### Scenario: Hub page exposes the two controls
- **WHEN** the user opens the Keyboard Language page in the Hub
- **THEN** an enable toggle and a global-default source picker (listing enabled input sources) are shown

#### Scenario: Toggling the Hub enable control gates the feature
- **WHEN** the user toggles the enable control off
- **THEN** the feature stops observing and changing the input source as specified by the opt-in requirement

