## MODIFIED Requirements

### Requirement: Favorites editor window
The system SHALL provide a band/item editing canvas as the Hub's **Bands** page (not a separate window), reachable from the status menu and from the Hub sidebar, that edits the context bands and their items. Edits SHALL persist immediately and be reflected in the launcher on its next activation.

#### Scenario: Open the editor from the menu
- **WHEN** the user selects the favorites entry from the status menu
- **THEN** the Hub opens on its Bands page

#### Scenario: Edits take effect
- **WHEN** the user adds, removes, or reorders an item and then activates the launcher
- **THEN** the launcher reflects the change

### Requirement: Source items by type via a browsing sidebar
The Bands page SHALL provide a source picker that lists item-source categories by type (applications, shortcuts, paths, presets, scripts, **AI command**) and, when a category is opened, presents a scrollable browseable list of candidates of that type. Selecting a candidate SHALL add it to the currently targeted context band. The picker SHALL provide a way to return from a category list to the category index.

#### Scenario: Browse applications
- **WHEN** the user opens the Applications category in the source picker
- **THEN** the picker presents a scrollable list of installed applications

#### Scenario: Selecting a candidate adds it
- **WHEN** the user selects an application from the browse list
- **THEN** that application is added as an item to the currently targeted context band

#### Scenario: Add an AI command from the source picker
- **WHEN** the user chooses the AI command source
- **THEN** a new AI-command item is added to the currently targeted band and selected for inline editing

#### Scenario: Return to category index
- **WHEN** the user is in a category's browse list and chooses back
- **THEN** the picker returns to the category index

## ADDED Requirements

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
