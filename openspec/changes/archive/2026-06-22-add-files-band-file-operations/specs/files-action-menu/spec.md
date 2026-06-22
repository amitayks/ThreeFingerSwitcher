## ADDED Requirements

### Requirement: Cut moves on the next Paste

The action menu SHALL offer a **Cut** action for a highlighted file or folder. Choosing Cut SHALL write the entry's file reference to the pasteboard and **mark it as cut** (recording the pasteboard's state at that moment). The menu's **Paste** action SHALL then be **dual-mode**: when the live pasteboard is **still that cut**, Paste SHALL **move** the marked entry into the target folder (a highlighted folder, or a highlighted file's containing folder); otherwise Paste SHALL **copy** as before. Both modes SHALL **keep both** on a name conflict (auto-rename) and SHALL NEVER overwrite. A completed move SHALL clear the cut mark. An intervening **Copy** (or any other pasteboard write) SHALL **supersede** the cut, so a subsequent Paste copies rather than moves. Cut SHALL be a default action for **both** files and folders.

#### Scenario: Cut then Paste moves the entry

- **WHEN** the user commits Cut on an entry, then commits Paste over another folder while the pasteboard is unchanged
- **THEN** the entry is **moved** into that folder (removed from its original location), keeping both names on conflict, and the cut mark is cleared

#### Scenario: Copy then Paste still copies

- **WHEN** the user commits Copy on an entry, then commits Paste over a folder
- **THEN** the entry is **copied** into that folder (the original stays), keeping both names on conflict

#### Scenario: A Copy between Cut and Paste supersedes the cut

- **WHEN** the user commits Cut, then commits Copy on a different entry, then commits Paste
- **THEN** Paste **copies** the most recently copied entry (the earlier cut no longer moves)

### Requirement: Delete moves to the Trash

The action menu SHALL offer a **Delete** action for a highlighted file or folder that moves it to the **Trash** (recoverable from Finder). It SHALL NOT permanently remove the entry. A failed delete SHALL surface as the existing **bounded, non-blocking** failure row (a clean headline + opt-in copyable details + Retry/Dismiss), never an app-modal alert and never raw error text in the headline. Delete SHALL be a default action for **both** files and folders, and SHALL be committed by the same **dwell-armed lift** as every other menu row (the deliberate rest-to-arm is the confirmation — there is no separate confirmation dialog).

#### Scenario: Delete trashes the entry

- **WHEN** the user commits Delete on a highlighted entry
- **THEN** the entry is moved to the Trash (recoverable) and is not permanently removed

#### Scenario: A failed delete is observable, never silent

- **WHEN** a Delete cannot complete (e.g. permission denied)
- **THEN** a bounded, non-blocking failure row appears with a clean headline and Retry — never an alert, never raw error text

#### Scenario: Delete requires the dwell-arm

- **WHEN** the user scrubs onto Delete and lifts before the row has armed
- **THEN** nothing is deleted and the overlay dismisses (the dwell-arm is the deliberate confirm)

### Requirement: The action menu and its Open-With grid fit their content

The action menu **and** its "Open in ▸" Open-With grid SHALL each size to their content — **width** derived from the widest row label (bounded to a sensible minimum and maximum) and **height** derived from the row count (header + rows + padding, bounded by a safety cap) — rather than rendering at a fixed size with empty space. A label too long for the maximum width SHALL truncate within it. The single sliding selection highlight SHALL continue to span the popup's width.

#### Scenario: A short popup is compact

- **WHEN** the action menu shows a few short rows (e.g. Copy · Cut · Delete), or the Open-With grid lists a couple of apps
- **THEN** the popup is sized to fit those rows in both dimensions, not padded out to a fixed width/height

#### Scenario: A long label stays bounded

- **WHEN** a row label is longer than the popup's maximum width
- **THEN** the label truncates within the bounded width rather than overflowing

#### Scenario: Height tracks the row count

- **WHEN** a popup has few rows
- **THEN** its height is just the header plus those rows (no empty vertical space), expanding with more rows up to the safety cap
