## ADDED Requirements

### Requirement: The Files page configures the action menu and lift action

The Hub's **Files page** SHALL let the user configure the Files-band action menu and the drill's lift action. It SHALL provide:

- a **per-type menu editor** (separate for **file** and **folder**) to **add, remove, and reorder** items from the action catalog (the defaults plus the opt-in extras — Reveal in Finder, Add to Favorites, Open in ‹editor›, Copy name);
- a **terminals/editors curation** control listing the **auto-detected** installed tools, each individually enable-able;
- a control to set the Files **lift action** (deliver / open / open-menu), edited through the existing gesture-binding editor used by the other remappable surfaces.

Edits SHALL persist (see *tunable-settings*) and SHALL take effect on the next time the band is shown. The page SHALL keep the existing previewed-section header and its other Files controls unchanged.

#### Scenario: Reordering the file menu persists

- **WHEN** the user reorders the **file** action menu on the Files page
- **THEN** the next time the file action menu opens it reflects the new order, across launches

#### Scenario: Curating terminals controls the menu

- **WHEN** the user disables a detected terminal on the Files page
- **THEN** that terminal no longer appears in the folder action menu

#### Scenario: Setting the lift action

- **WHEN** the user sets the Files lift action to "open"
- **THEN** a lift on a highlighted entry opens it (instead of delivering), and the default can be restored

#### Scenario: File and folder editors are independent

- **WHEN** the user edits the folder menu
- **THEN** the file menu editor and its result are unaffected
