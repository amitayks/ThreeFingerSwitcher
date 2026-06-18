## MODIFIED Requirements

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
