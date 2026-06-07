## ADDED Requirements

### Requirement: Screenshot actions support a save-to-clipboard destination

The **Screenshot — Selection** and **Screenshot — Full Screen** actions SHALL support an optional, per-item "save to clipboard" destination, performed natively and **without any new permission**. When the option is **off** (the default), the action SHALL retain its current behavior — synthesize the native file-capture shortcut (⇧⌘4 for selection, ⇧⌘3 for full screen), which writes a file to the user's screenshot location. When the option is **on**, the action SHALL synthesize the native capture-to-clipboard shortcut (⌃⇧⌘4 for selection, ⌃⇧⌘3 for full screen) by adding the Control modifier to the same base shortcut, so the capture goes **only** to the clipboard and no screenshot file is written.

The option SHALL apply only to the Selection and Full Screen actions. The **Screenshot — Tools** action (⇧⌘5) SHALL NOT support the option, because the system screenshot toolbar carries its own "Save to" destination menu; it SHALL continue to open the toolbar unmodified.

#### Scenario: Default keeps the file capture

- **WHEN** a Screenshot — Selection or Screenshot — Full Screen action with the save-to-clipboard option off is fired
- **THEN** the system synthesizes the unmodified ⇧⌘4 / ⇧⌘3 shortcut and the capture is written to a file exactly as before

#### Scenario: Toggle on captures to the clipboard only

- **WHEN** a Screenshot — Selection (or Screenshot — Full Screen) action with the save-to-clipboard option on is fired
- **THEN** the system synthesizes ⌃⇧⌘4 (or ⌃⇧⌘3), the capture is placed on the clipboard, and no screenshot file is written to the Desktop

#### Scenario: Tools action ignores the option

- **WHEN** the Screenshot — Tools action is fired
- **THEN** it opens the system screenshot toolbar via the unmodified ⇧⌘5, regardless of any clipboard setting, and lets the toolbar's own destination menu decide where the capture goes

#### Scenario: No new permission

- **WHEN** a screenshot action is fired with the save-to-clipboard option on
- **THEN** the capture uses only the Accessibility/HID path the screenshot actions already use (the OS performs the capture) and requests no additional permission

### Requirement: Screenshot clipboard destination is editable per item

The launcher editor SHALL let the user toggle "save to clipboard" on a Screenshot — Selection or Screenshot — Full Screen action item from the item inspector, and SHALL NOT offer the toggle for any other action (including Screenshot — Tools). The setting SHALL persist with the item. Existing saved items (which predate this option) SHALL load unchanged with the option off, with no schema-version bump and no loss of the item.

#### Scenario: Configure a screenshot action in the inspector

- **WHEN** the user selects a Screenshot — Selection or Screenshot — Full Screen action item in the editor
- **THEN** the inspector offers a "save to clipboard" toggle whose state is saved to the item

#### Scenario: Toggle is not offered for other actions

- **WHEN** the user selects a Screenshot — Tools action, or any non-screenshot action, in the editor
- **THEN** no save-to-clipboard toggle is shown for that item

#### Scenario: Older favorites load without the option

- **WHEN** favorites saved before this option are loaded
- **THEN** every `.action` item decodes successfully with the save-to-clipboard option off, and the favorites are not reset to defaults
