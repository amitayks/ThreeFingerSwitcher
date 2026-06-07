## ADDED Requirements

### Requirement: Switcher floats above an open Mission Control
When the switcher is triggered while Mission Control is open (opened by the app's gesture ownership), the overlay SHALL be presented above Mission Control so all cards are fully visible. This elevated presentation (raised window level, Exposé-exempt) SHALL be used **only** while Mission Control is open; when it is not, the overlay SHALL keep its normal arbitration-safe presentation so focus/Space behavior is unchanged.

#### Scenario: Overlay is visible over Mission Control
- **WHEN** Mission Control is open and the user triggers the switcher
- **THEN** the switcher cards render above the Mission Control windows, not behind them

#### Scenario: Normal presentation when Mission Control is closed
- **WHEN** the switcher is triggered without Mission Control open
- **THEN** the overlay uses its normal level/behavior and focus/Space handling is unchanged

### Requirement: Selecting while Mission Control is open dismisses it and focuses the window
When a window is committed in the switcher while Mission Control is open, the system SHALL dismiss Mission Control and then focus the selected window via the robust raise. Dismissal SHALL never itself open Mission Control if it was already closed.

#### Scenario: Commit closes Mission Control and focuses the window
- **WHEN** the user selects a window in the switcher while Mission Control is open
- **THEN** Mission Control closes and the selected window is raised and focused

#### Scenario: Stale state does not reopen Mission Control
- **WHEN** a commit's dismiss runs but Mission Control is no longer open
- **THEN** Mission Control is not opened, and the selected window is still raised and focused
