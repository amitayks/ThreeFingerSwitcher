# favorites-editor Specification

## Purpose

Define the band/item editing canvas — the Hub's **Bands** page — that browses and sources launch items by type (including AI commands), arranges them into context bands on a canvas, and configures per-item and per-band appearance and strategy, with edits persisting immediately to the launcher.

## Requirements

### Requirement: Favorites editor window
The system SHALL provide a band/item editing canvas as the Hub's **Bands** page (not a separate window), reachable from the status menu and from the Hub sidebar, that edits the context bands and their items. Edits SHALL persist immediately and be reflected in the launcher on its next activation.

#### Scenario: Open the editor from the menu
- **WHEN** the user selects the favorites entry from the status menu
- **THEN** the Hub opens on its Bands page

#### Scenario: Edits take effect
- **WHEN** the user adds, removes, or reorders an item and then activates the launcher
- **THEN** the launcher reflects the change

### Requirement: Source items by type via a browsing sidebar
The Bands page SHALL provide a source picker that lists item-source categories by type (applications, shortcuts, paths, URLs, presets, scripts, **AI command**, **Claude Project**, **Open in Terminal**). The source picker SHALL appear inline under the expanded band in the bands column — the expanded band is the add target — and everything chosen SHALL be added directly into that band. Browse-style categories (applications, shortcuts, actions, AI command, presets) SHALL open a scrollable browseable list of candidates; selecting a candidate SHALL add it to the currently targeted context band. Immediate-add categories — **URLs**, **Scripts**, **Files & Folders**, **Claude Project**, and **Open in Terminal** — SHALL add an item directly rather than presenting a fill-in-first form: choosing URLs or Scripts SHALL add a blank item of that kind; choosing Files & Folders SHALL prompt for a path and then add the item; choosing Claude Project or Open in Terminal SHALL prompt for a folder and then add the item. In all cases the value-bearing fields (a link's URL/open-with/window, a script's body, a file's path, a Claude Project's folder and command, an Open-in-Terminal item's folder and command) SHALL be edited in the item panel after adding — not in the source picker. The newly added item SHALL be selected, and the editor SHALL place the keyboard focus on its first relevant field (the URL field for a link, the body for a script, the name for a file) for fast entry. The picker SHALL provide a way to return from a browse list to the category index.

#### Scenario: Browse applications
- **WHEN** the user opens the Applications category in the source picker
- **THEN** the picker presents a scrollable list of installed applications

#### Scenario: Selecting a candidate adds it
- **WHEN** the user selects an application from the browse list
- **THEN** that application is added as an item to the currently targeted context band

#### Scenario: Adding a link is immediate and edited in the panel
- **WHEN** the user chooses the URLs source
- **THEN** a blank link item is added to the targeted band, selected, and the item panel opens with the cursor in the URL field
- **AND** the link's URL, open-with app, and new-window preference are edited in that panel, not in the source picker

#### Scenario: Adding a script or file follows the same add-then-edit flow
- **WHEN** the user chooses the Scripts source, or the Files & Folders source and picks a path
- **THEN** the item is added and selected, and its body (script) or name (file) is focused in the item panel for editing

#### Scenario: Add an AI command from the source picker
- **WHEN** the user chooses the AI command source
- **THEN** a new AI-command item is added to the currently targeted band and selected for inline editing

#### Scenario: Add a Claude Project from the source picker
- **WHEN** the user chooses the Claude Project source and picks a folder
- **THEN** a Claude Project item bound to that folder is added to the currently targeted band, titled with the folder name, and selected — with its folder editable in the item panel

#### Scenario: Add an Open-in-Terminal item from the source picker
- **WHEN** the user chooses the Open in Terminal source and picks a folder
- **THEN** an Open-in-Terminal item bound to that folder is added to the currently targeted band, titled with the folder name, and selected — with its folder and command editable in the item panel

#### Scenario: Return to category index
- **WHEN** the user is in a category's browse list and chooses back
- **THEN** the picker returns to the category index

### Requirement: Author and edit AI commands inline as band items
The Bands page SHALL let the user author and edit an AI command **inline**, as a band item, exposing every field of the command model — name, icon, tint, input source, prompt template (with token insertion), output target (and, for task/send-to targets, the task kind / destination), model selector, and confirm-before-run. Editing an AI-command item SHALL persist immediately into the Favorites record, and the command SHALL be movable between bands like any other item. There SHALL be no separate AI-command editor window or sheet.

#### Scenario: Edit an AI command in the item inspector
- **WHEN** the user selects an AI-command item on the Bands page
- **THEN** the inspector shows its full editable fields (name, icon, tint, input, prompt template, output, model, confirm-before-run)

#### Scenario: AI command edits persist into Favorites
- **WHEN** the user changes an AI command's prompt template or output target on the Bands page
- **THEN** the change is saved into the Favorites record immediately and used on the next firing

#### Scenario: An AI command moves between bands
- **WHEN** the user moves an AI-command item from one band to another
- **THEN** the command now belongs to the destination band and appears there in the launcher

#### Scenario: No separate AI command editor
- **WHEN** the user wants to edit AI commands
- **THEN** they do so on the Bands page, and no standalone AI-command editor window or sheet exists

### Requirement: Arrange items by context band on the canvas
The editor canvas SHALL present the context bands as the user will swipe them, allowing: reordering items within a band by drag, reordering bands by drag, removing an item, creating a new band, and choosing which band is the active add target. The canvas SHALL be the same structure the launcher navigates. The canvas SHALL use two columns: a merged **bands column** and an always-visible **items column**. The bands column SHALL list the bands; clicking a band SHALL select it (its items appear in the items column) AND expose that band's source picker inline under its row, while the selected band's settings (icon, color, default app strategy) SHALL be pinned at the bottom of the same column. Re-clicking the selected band SHALL deselect it entirely — no band highlighted, its sources and settings hidden, and the items column showing its empty/placeholder state — the same clean state as first opening the Hub (no band SHALL be auto-selected on open). Clicking another band SHALL switch the selection and expose that band's sources. While a band is selected, the items column SHALL show its items grid (and the selected item's editor) — the items are not hidden behind a disclosure.

#### Scenario: Reorder within a band
- **WHEN** the user drags an item to a new position within its band
- **THEN** the stored order updates to match

#### Scenario: Reorder bands
- **WHEN** the user drags a band to a new position
- **THEN** the stored band order updates to match

#### Scenario: Clicking a band exposes its sources inline; items stay visible
- **WHEN** the user clicks a band in the bands column
- **THEN** that band's source picker appears inline under its row, its settings appear pinned at the bottom of the column, and its items appear in the always-visible items column

#### Scenario: Re-clicking the selected band deselects it
- **WHEN** the user clicks the currently selected band
- **THEN** the band is deselected (nothing highlighted), its sources and settings hide, and the items column returns to its empty state — matching first-open

#### Scenario: Nothing is selected on first open
- **WHEN** the Hub's Bands page is first opened
- **THEN** no band is highlighted and no band's sources or settings are shown

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
