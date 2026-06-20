## ADDED Requirements

### Requirement: Choose-folder-at-launch item variant

The launcher SHALL provide a choose-folder-at-launch variant of BOTH the Open-Claude item and the Open-in-Terminal item. Unlike the folder-bound items (whose folder is fixed at setup), a choose-folder-at-launch item SHALL NOT bind a folder at setup; instead, each time it is fired it SHALL present a native folder chooser and launch into the folder the user selects, otherwise behaving identically to its fixed sibling — the same command, the same Claude executable resolution (for the Claude variant), the same no-new-permission terminal handoff, and the same bounded, non-blocking failure surfacing.

The chooser SHALL open at the folder most recently chosen for that item (its remembered last folder), or at the user's home folder when none has been chosen yet. Selecting a folder SHALL launch into it AND SHALL persist that folder as the item's remembered last folder, so the next trigger opens the chooser there. Canceling the chooser SHALL abort the launch, SHALL NOT be surfaced as an error, and SHALL NOT change the remembered folder.

Authoring SHALL mirror the fixed siblings minus the setup folder: a choose-folder-at-launch item SHALL be added without choosing a folder (only its command, defaulting as the fixed sibling does), and its inspector SHALL edit the command and SHALL display the remembered last folder with a control to clear it (returning to "open the chooser at the home folder").

#### Scenario: Folder is chosen each time the item fires
- **WHEN** a choose-folder-at-launch Claude (or Terminal) item is fired
- **THEN** a native folder chooser is presented, and on selecting a folder the terminal opens at that folder and runs the item's command exactly as the fixed sibling would

#### Scenario: Chooser opens at the last-used folder
- **WHEN** the item has been fired into a folder before and is fired again
- **THEN** the folder chooser opens at that last-used folder
- **AND** when the item has never been fired into a folder, the chooser opens at the user's home folder

#### Scenario: Selecting a folder remembers it for next time
- **WHEN** a folder is selected from the chooser
- **THEN** the launch proceeds into that folder AND that folder becomes the item's remembered last folder used the next time it fires

#### Scenario: Canceling aborts without error
- **WHEN** the folder chooser is canceled with no folder selected
- **THEN** nothing is launched, no error is surfaced, and the remembered last folder is unchanged

#### Scenario: Added without a setup folder; command editable
- **WHEN** a choose-folder-at-launch item is created from the configuration Hub
- **THEN** it is added without prompting for a folder, with the default command of its fixed sibling
- **AND** its inspector edits the command and shows the remembered last folder with a control to clear it

#### Scenario: No new permission
- **WHEN** a choose-folder-at-launch item launches into the selected folder
- **THEN** it uses the same self-deleting `.command` handoff as the fixed items and requires no new permission (no Apple Events)
