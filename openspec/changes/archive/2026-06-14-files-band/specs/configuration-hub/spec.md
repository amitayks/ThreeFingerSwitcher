## ADDED Requirements

### Requirement: Files page hosts roots, appearance, and behavior

The Hub SHALL provide a **Files** page (reachable from the grouped sidebar) that hosts the Files band's configuration: the **roots editor** (add / remove / reorder the local root folders that form the band's entry column), the **appearance** controls (column width / density, tint, and an icon-vs-preview choice), and the **behavior** controls (entry **sort order**, the default-open action, and which metadata a row shows). The page SHALL include the Files band **opt-in** master toggle. All controls SHALL **persist** their values (live-applied, like the other feature pages) and SHALL use the shared **Liquid Glass** presentation consistent with the rest of the Hub. The roots editor SHALL accept **local folders only**.

#### Scenario: The Files page is reachable and toggles the band
- **WHEN** the user opens the Hub and selects the Files page
- **THEN** the page shows the Files opt-in toggle plus the roots, appearance, and behavior controls

#### Scenario: Editing roots updates the entry column
- **WHEN** the user adds, removes, or reorders a root on the Files page
- **THEN** the Files band's entry column reflects the change on the next launcher open

#### Scenario: Appearance and behavior changes persist and live-apply
- **WHEN** the user changes column density, tint, sort order, or the default-open action
- **THEN** the change persists across launches and applies to the Files band

#### Scenario: Only local folders can be added as roots
- **WHEN** the user attempts to add a root
- **THEN** only local folders are accepted (network / iCloud-placeholder locations are rejected)
