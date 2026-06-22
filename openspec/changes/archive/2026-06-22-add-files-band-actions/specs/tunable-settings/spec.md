## ADDED Requirements

### Requirement: Persisted Files action-menu and lift settings

The app SHALL persist the Files-band action configuration and SHALL default it to this change's grammar. The persisted settings SHALL include:

- the **per-type action-menu item lists** (file and folder), each an ordered list drawn from the action catalog — defaulting to **file:** Copy as path · Copy · Paste · Open in ▸ and **folder:** Copy as path · Copy · Paste · ‹terminals› · Open in ▸;
- the **Files lift action** — defaulting to **deliver** (with the menu excursion defaulting to the `+1`-finger lift and discard to the four-finger horizontal), stored as part of the Files gesture-binding vocabulary;
- the **curated terminals/editors** allow-list — defaulting to the auto-detected installed set being enabled.

These settings SHALL be included in the app's **reset-to-defaults** semantics and SHALL load to the defaults above when absent or unreadable.

#### Scenario: Defaults reproduce the specified grammar

- **WHEN** the user has never customized the Files action settings
- **THEN** the file and folder menus, the lift action (deliver), and the enabled terminals are exactly the defaults above

#### Scenario: Customizations persist across launches

- **WHEN** the user changes a menu list, the lift action, or the enabled terminals and relaunches
- **THEN** the changes are restored from persistence

#### Scenario: Reset restores defaults

- **WHEN** the user resets settings to defaults
- **THEN** the Files action menus, lift action, and terminal allow-list return to the specified defaults

#### Scenario: Missing or unreadable settings fall back to defaults

- **WHEN** the persisted Files action settings are absent or cannot be decoded
- **THEN** the app loads the specified defaults without error
