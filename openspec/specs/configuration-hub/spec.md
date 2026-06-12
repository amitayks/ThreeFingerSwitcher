# configuration-hub Specification

## Purpose

Define the single, unified configuration **Hub** window that is the only surface for configuring every feature: an Overview landing page of master toggles, grouped-sidebar navigation (Content → Bands; Features → Switcher/Launcher/Clipboard/AI; System → Setup/General), per-feature pages that preserve all tunables and persistence, a Setup page for permissions and native-gesture opt-ins, a Bands page that edits only authored bands, and a Liquid-Glass/material presentation consistent with the runtime overlays. All former configuration surfaces (Settings, Favorites editor, Setup/Onboarding, AI-command editor) fold into this one window.

## Requirements

### Requirement: Unified configuration Hub window
The system SHALL provide a single configuration **Hub** window that is the only surface for configuring every feature. Opening any configuration entry point (from the status menu or from in-app deep links) SHALL open this one window — there SHALL be no separate Settings, Favorites, Setup, or AI-command-editor window or sheet. The Hub SHALL be a single reusable window: re-opening it SHALL bring the existing window forward rather than creating another, and its frame SHALL persist across launches.

The one exception is the **First Touch wizard**: a transient first-run/replay window that is an onboarding performance, not a configuration surface. Every preference the wizard writes SHALL be the same persisted preference the Hub owns, and the wizard SHALL NOT host any configuration capability beyond its onboarding steps — the Hub remains the only place to configure the app.

#### Scenario: One window for all configuration
- **WHEN** the user opens configuration from the status menu
- **THEN** the Hub window opens, and no separate Settings, Favorites, Setup, or AI-command window exists

#### Scenario: Re-opening reuses the same window
- **WHEN** the Hub is already open and the user triggers it again
- **THEN** the existing Hub window is brought to the front (a second window is not created)

#### Scenario: Window frame persists
- **WHEN** the user resizes or moves the Hub and relaunches the app
- **THEN** the Hub reopens at its last position and size

#### Scenario: The wizard is not a configuration surface
- **WHEN** the First Touch wizard toggles a feature or opt-in
- **THEN** it writes the identical persisted preference as the corresponding Hub page, and any further configuration of that feature happens in the Hub

### Requirement: Overview landing page with feature master toggles
The Hub SHALL present an **Overview** landing page that shows every feature's master enable toggle at a glance — the window switcher, Space-row switching, the four-finger launcher, clipboard history, and AI commands — and SHALL let the user turn each feature on or off directly from this page. Each feature row SHALL deep-link to that feature's detail page. Toggling a feature on the Overview SHALL write the same persisted preference as toggling it on its detail page.

#### Scenario: All master toggles visible at a glance
- **WHEN** the user opens the Hub on the Overview page
- **THEN** the on/off state of the switcher, Space-row switching, launcher, clipboard, and AI features is shown together

#### Scenario: Toggle from the Overview
- **WHEN** the user flips a feature's toggle on the Overview page
- **THEN** the feature's persisted enable preference changes identically to flipping it on the feature's detail page

#### Scenario: Deep-link to a feature page
- **WHEN** the user follows a feature row's disclosure from the Overview
- **THEN** the Hub navigates to that feature's detail page

### Requirement: Grouped sidebar navigation
The Hub SHALL organize its pages in a sidebar grouped as: an **Overview** entry; a **Content** group containing **Bands**; a **Features** group containing **Switcher**, **Launcher**, **Clipboard**, and **AI**; and a **System** group containing **Setup** and **General**. The sidebar SHALL be a compact icon-only rail (each destination shown as its icon, with its name as a tooltip, the groups separated by dividers) to conserve horizontal space, and SHALL tint the selected destination. The sidebar SHALL provide a button to expand it to show icon + label and collapse it back to icons, transitioning smoothly (animated). Each destination's full row (not merely its glyph) SHALL be the click target. Selecting a sidebar entry SHALL show that page in the detail area. A disabled feature SHALL keep its page reachable (its controls shown disabled) so it can be re-enabled. Space-row switching is a sub-feature of the Switcher and SHALL appear as sections on the **Switcher** page (Space-row switching and Fixed order) rather than as its own sidebar destination.

#### Scenario: Sidebar groups
- **WHEN** the user opens the Hub
- **THEN** the sidebar shows Overview, a Content group with Bands, a Features group with Switcher/Launcher/Clipboard/AI, and a System group with Setup/General, as a compact icon-only rail with names as tooltips
- **AND** Space-row switching appears as sections on the Switcher page, not as its own sidebar entry

#### Scenario: Disabled feature page still reachable
- **WHEN** a feature is turned off
- **THEN** its sidebar page remains selectable and shows its controls in a disabled state rather than disappearing

### Requirement: Feature pages preserve all tunables and persistence
Every tunable and control that existed in the former Settings window SHALL be present on the corresponding Hub feature page, reading and writing the **same** persisted preferences with the **same** keys, defaults, and reset-to-defaults semantics (including the opt-in preferences that are deliberately excluded from reset). No setting SHALL be lost, renamed, or given a new default by the move into the Hub.

#### Scenario: A relocated tunable keeps its value
- **WHEN** a tunable that was set in the former Settings window is read on its new Hub feature page after upgrade
- **THEN** it shows the previously persisted value

#### Scenario: Reset semantics are unchanged
- **WHEN** the user resets to defaults from the Hub
- **THEN** the same tunables reset and the same opt-in preferences (gesture relocations, clipboard and AI opt-ins, excluded apps, selected model) are preserved exactly as before

### Requirement: Setup page hosts permissions and native-gesture opt-ins
The Hub SHALL provide a **Setup** page that hosts the permissions status and guidance and the native-gesture opt-ins for ongoing (post-onboarding) use. The configuration entry point for permissions and setup SHALL be this page. The Setup page SHALL also offer the First Touch wizard entry: **Resume the welcome tour** while first-run onboarding is incomplete, and **Replay the welcome tour** after completion.

#### Scenario: Setup is the ongoing surface
- **WHEN** the user opens setup or permissions after onboarding is complete
- **THEN** the Hub's Setup page is shown

#### Scenario: Resume or replay the tour from Setup
- **WHEN** the user opens the Setup page
- **THEN** a resume entry is offered if onboarding is incomplete, or a replay entry if it is complete

### Requirement: Bands page edits only authored bands
The Hub SHALL provide a **Bands** page that is the single surface for arranging launcher content. The Bands page SHALL edit only **authored** bands (the user's favorites bands, which now include AI-command items). It SHALL NOT present **live** bands — bands whose items are auto-populated rather than authored, such as the clipboard band — for item-level editing; such features are configured on their own feature page and projected into the launcher at runtime.

#### Scenario: Authored bands are editable on the Bands page
- **WHEN** the user opens the Bands page
- **THEN** the user's favorites bands and their items (including AI commands) are shown and editable

#### Scenario: The clipboard live band is not edited on the Bands page
- **WHEN** the user opens the Bands page with clipboard history enabled
- **THEN** the clipboard band's entries are not listed for authoring there (clipboard is configured on the Clipboard feature page)

### Requirement: Liquid Glass presentation consistent with the overlays
The Hub SHALL adopt the same Liquid Glass / material visual language used by the runtime overlays (the glass/material treatment used by the launcher, switcher, and clipboard overlays), so the configuration window and the runtime overlays read as one app. Where the glass material is unavailable on the running OS, the Hub SHALL fall back gracefully exactly as the overlays do.

#### Scenario: Hub matches the overlay material language
- **WHEN** the Hub is shown on a system that supports the glass material
- **THEN** it uses the same glass/material treatment as the launcher and switcher overlays

#### Scenario: Graceful fallback below the glass material
- **WHEN** the Hub is shown on a system that does not support the glass material
- **THEN** it renders with the same graceful fallback the overlays use, without error

### Requirement: General page Danger zone
The Hub's **General** page SHALL provide a "Danger zone" section with selective, explicit reset controls:

- Four opt-in toggles, all default off, each gating one deletion category: **App data & settings** (the app's preferences domain, Application Support data excluding the AI model weights, and saved window state), **Caches**, **AI models** (the on-disk weights, with the AI opt-in turned off first), and **Permissions** (a TCC reset for every service the app can hold).
- A destructive **Clear selected** action that SHALL be disabled while no category is selected and SHALL require an explicit confirmation enumerating exactly what will happen before anything is deleted.
- WHEN App data & settings is selected and any native-gesture/Spaces backup exists, the relocations SHALL be restored FIRST (and the confirmation SHALL say so) — the wipe must never delete the backups while leaving the system relocated.
- WHEN App data & settings or Permissions was cleared, the app SHALL relaunch itself so the fresh process reads the cleared state (a data wipe re-enters first-run onboarding); cache/model-only clears SHALL report a non-blocking summary and stay running.
- A **Restore native gestures** action that restores every app-made gesture and Spaces relocation from its absent-aware backup, turns the corresponding opt-ins off, and states that a re-login finishes the trackpad changes.

#### Scenario: Nothing selected, nothing clearable
- **WHEN** the Danger zone is shown with no category toggled on
- **THEN** the Clear action is disabled and nothing is deleted

#### Scenario: Selective clear honors the selection
- **WHEN** the user selects only Caches and AI models and confirms
- **THEN** only the cache directories and the model weights are removed (the AI opt-in turning off first), preferences and permissions are untouched, and the app keeps running with a summary

#### Scenario: Data wipe restores gestures first
- **WHEN** App data & settings is selected while a trackpad relocation backup exists and the user confirms
- **THEN** the relocations are restored from their backups before any deletion, and the app relaunches into first-run onboarding

#### Scenario: Permissions reset
- **WHEN** the Permissions category is selected and confirmed
- **THEN** every TCC service the app can hold is reset for the app's bundle id and the app relaunches

#### Scenario: Restore-all gestures
- **WHEN** the user invokes Restore native gestures with backups present
- **THEN** the trackpad keys and Spaces setting return to their exact backed-up values (deleting previously-absent keys), the opt-ins turn off, and the user is told a re-login completes the trackpad changes
