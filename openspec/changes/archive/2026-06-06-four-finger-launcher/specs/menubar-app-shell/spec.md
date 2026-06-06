## ADDED Requirements

### Requirement: Favorites editor and quick-add entry points
The status menu SHALL offer an entry that opens the favorites editor, and an entry that adds the frontmost application to a chosen context band without opening the editor. The quick-add entry SHALL add the app to the favorites store and have it appear in the launcher on its next activation.

#### Scenario: Favorites entry opens the editor
- **WHEN** the user selects the favorites entry from the status menu
- **THEN** the favorites editor window opens

#### Scenario: Quick-add adds the front app
- **WHEN** the user chooses to add the frontmost app to a context band from the status menu
- **THEN** that app is added as an item to the chosen band and appears in the launcher on next activation
