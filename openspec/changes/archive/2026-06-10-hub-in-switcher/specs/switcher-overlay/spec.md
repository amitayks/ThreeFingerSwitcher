## ADDED Requirements

### Requirement: Configuration Hub appears as a switcher card while open
While the configuration Hub window is open (visible), the switcher SHALL include a single synthetic card for the Hub so the user can scrub back to it, even though the app remains an accessory (`LSUIElement`) app with no Dock icon and no Cmd-Tab entry. The Hub card SHALL be injected on purpose and SHALL be the **only** window of the app that appears — the general self-PID exclusion that keeps the app's own overlay panels out of the switcher SHALL remain in force, so no other window of the app (the overlay panels) ever leaks in. When the Hub is not open, no Hub card SHALL appear. The app SHALL NOT change its activation policy to achieve this (no Dock icon, no Cmd-Tab entry are introduced).

#### Scenario: Hub card present while open
- **WHEN** the Hub window is open (visible) and the switcher is triggered
- **THEN** the switcher shows exactly one card for the Hub, titled with the app name followed by " Hub"
- **AND** no other window belonging to the app appears as a card

#### Scenario: No Hub card when closed
- **WHEN** the Hub window is not open (not visible) and the switcher is triggered
- **THEN** no card for the Hub appears, and the app's overlay panels still do not appear

#### Scenario: Accessory mode preserved
- **WHEN** the Hub card is shown or committed
- **THEN** the app's activation policy is unchanged — it remains an accessory app with no Dock icon and no Cmd-Tab entry

### Requirement: Hub card is icon-only with no self-capture
The Hub switcher card SHALL be icon-only: it carries no Accessibility element and no captured thumbnail, and the switcher SHALL render the app icon (its existing no-thumbnail fallback) for it. The Hub window's id SHALL be excluded from the thumbnail seed and prefetch, so no ScreenCaptureKit capture of the app's own window is ever attempted.

#### Scenario: App icon shown, no thumbnail
- **WHEN** the Hub card is rendered
- **THEN** it shows the app icon (no live thumbnail) and a title of the app name followed by " Hub"

#### Scenario: No self-capture is attempted
- **WHEN** the switcher seeds or prefetches thumbnails for the current Space-row that contains the Hub card
- **THEN** the Hub window's id is excluded from both the seed and the prefetch, so no ScreenCaptureKit capture of the app's own window is attempted

### Requirement: Hub card stays on its opened Space and committing focuses the Hub
The Hub window SHALL remain on the Space it was opened on (it SHALL NOT be made to join all Spaces or move to the active Space). The Hub card SHALL appear on the Space-row for the Space the Hub was opened on. Committing the Hub card SHALL focus the real Hub window — bringing the app forward and making the Hub key and front via the app's own-window focus path — switching to the Hub's Space first if it is on a different Space than the active one, exactly as raising any other off-Space window does. Because the focused window is the app's own, the commit SHALL NOT depend on the Accessibility-gated cross-Space raise used for foreign windows.

#### Scenario: Card lands in the Hub's Space-row
- **WHEN** the Hub was opened on a given Space and the switcher is shown with windows across multiple Spaces
- **THEN** the Hub card appears in the Space-row for the Space the Hub was opened on

#### Scenario: Committing focuses the Hub on the current Space
- **WHEN** the Hub card is committed and the Hub is on the currently active Space
- **THEN** the app comes forward and the Hub window becomes key and front

#### Scenario: Committing switches to the Hub's Space when it is elsewhere
- **WHEN** the Hub card is committed and the Hub is on a different Space than the active one
- **THEN** the system switches to the Hub's Space and the Hub window becomes key and front, like raising any other off-Space window
