## ADDED Requirements

### Requirement: Favorites editor window
The system SHALL provide a dedicated favorites editor window, reachable from the status menu, that edits the context bands and their items. Edits SHALL persist immediately and be reflected in the launcher on its next activation.

#### Scenario: Open the editor from the menu
- **WHEN** the user selects the favorites entry from the status menu
- **THEN** the favorites editor window opens

#### Scenario: Edits take effect
- **WHEN** the user adds, removes, or reorders an item and then activates the launcher
- **THEN** the launcher reflects the change

### Requirement: Source items by type via a browsing sidebar
The editor SHALL provide a sidebar that lists item-source categories by type (applications, shortcuts, paths, presets, scripts) and, when a category is opened, presents a scrollable browseable list of candidates of that type. Selecting a candidate SHALL add it to the currently targeted context band. The sidebar SHALL provide a way to return from a category list to the category index.

#### Scenario: Browse applications
- **WHEN** the user opens the Applications category in the sidebar
- **THEN** the sidebar presents a scrollable list of installed applications

#### Scenario: Selecting a candidate adds it
- **WHEN** the user selects an application from the browse list
- **THEN** that application is added as an item to the currently targeted context band

#### Scenario: Return to category index
- **WHEN** the user is in a category's browse list and chooses back
- **THEN** the sidebar returns to the category index

### Requirement: Arrange items by context band on the canvas
The editor canvas SHALL present the context bands as the user will swipe them, allowing: reordering items within a band by drag, reordering bands by drag, removing an item, creating a new band, and choosing which band is the active add target. The canvas SHALL be the same structure the launcher navigates.

#### Scenario: Reorder within a band
- **WHEN** the user drags an item to a new position within its band
- **THEN** the stored order updates to match

#### Scenario: Reorder bands
- **WHEN** the user drags a band to a new position
- **THEN** the stored band order updates to match

#### Scenario: Remove an item
- **WHEN** the user removes an item from a band
- **THEN** the item no longer appears in that band

#### Scenario: Active target band
- **WHEN** the user selects a band as the add target and then picks a sourced item
- **THEN** the item is added to that band

### Requirement: Manual entry and per-item / per-band appearance
The editor SHALL allow manually entering url, path, and script items with a custom short name, icon, and color. The editor SHALL allow setting a name, icon, and color per item and per band, and a default app strategy per band.

#### Scenario: Add a manual script
- **WHEN** the user adds a script manually with a short name, icon, and color
- **THEN** a script item with that appearance is added to the targeted band

#### Scenario: Set a band default strategy
- **WHEN** the user sets a band's default app strategy
- **THEN** app items in that band without an explicit override use that strategy

#### Scenario: Recolor a band
- **WHEN** the user changes a band's color
- **THEN** the launcher renders that band and its indicator in the new color
