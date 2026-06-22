## ADDED Requirements

### Requirement: Lift delivers the highlighted entry to the captured front app

The Files band's **default lift resolution** SHALL be to **deliver** the highlighted entry to the **front application captured when the launcher opened** (the overlay is non-activating), never to whichever app is frontmost at the instant of firing. Delivery SHALL write the entry to the pasteboard and synthesize a **paste** into that captured app. Open-to-default SHALL remain available as an action (reached from the action menu), but SHALL NOT be the default lift outcome; the lift action SHALL be user-configurable (a user MAY rebind lift back to open). Delivery SHALL target the **current Space** and SHALL NOT teleport the user to another Space or app.

#### Scenario: Landing on a file delivers it to where you came from

- **WHEN** the user lifts on a highlighted file with the default lift binding
- **THEN** the file is delivered (pasted) into the app that was frontmost when the launcher opened, not into the overlay and not into whatever became frontmost at firing

#### Scenario: Open is still reachable, just not the default lift

- **WHEN** the user wants to open a file in its default app
- **THEN** "Open" is available from the action menu, and the lift binding MAY be set back to open — delivery is the default only

### Requirement: macOS routes the representation per target, with no context detection

Delivery SHALL write **both** representations of the entry in a single pasteboard item: the entry's **file reference** (`fileURL`) **and** its **standardized absolute path** as a string. The app SHALL NOT inspect the front app to decide which form to send; the receiving app SHALL select the representation it understands. A **text destination** (text field, terminal, code editor) SHALL receive the **path string**; a **Finder window** SHALL receive the **file** (copying it into the displayed folder).

#### Scenario: Path lands in a text field

- **WHEN** the captured front app is a terminal or text editor and a file is delivered
- **THEN** the file's absolute path is inserted as text at the cursor

#### Scenario: File lands in a Finder folder

- **WHEN** the captured front app is a Finder window showing a folder and a file is delivered
- **THEN** the file is copied into that folder (Finder consumes the file reference)

#### Scenario: No front-context probing

- **WHEN** any delivery occurs
- **THEN** the same dual-representation item is written for every target; the routing is the receiver's choice, not an app-side detection step

### Requirement: Delivery preserves the user's clipboard

Delivery SHALL **snapshot** the user's current clipboard, write the delivery item, synthesize the paste, and then **restore** the prior clipboard, so that delivering an entry never clobbers what the user had copied. The restore SHALL cover non-text clipboard contents (images, file references) as well as text.

#### Scenario: Clipboard is intact after delivery

- **WHEN** the user has content on the clipboard, delivers a file from the band, and then pastes manually elsewhere
- **THEN** their original clipboard content is what pastes — the delivery did not overwrite it

### Requirement: Delivery into an open or save panel navigates it to the path

WHEN the captured front context is a detected **open/save panel** (a file picker), delivery SHALL **navigate the panel to the entry's path** (drive the panel's go-to-folder path entry) rather than paste a file reference, so the picker lands on that location. Detection SHALL be conservative: if the front context is **not** confidently a file picker, delivery SHALL fall back to the dual-representation pasteboard contract so the common text/Finder cases never misfire.

#### Scenario: A file picker jumps to the delivered path

- **WHEN** an open/save panel is the detected front context and the user delivers a file
- **THEN** the panel navigates to that file's location

#### Scenario: Uncertain detection falls back to the contract

- **WHEN** the front context cannot be confidently identified as a file picker
- **THEN** delivery uses the dual-representation pasteboard paste (path-or-file by receiver), never a misdirected picker action

### Requirement: Delivery is observable, never a false success

Delivery SHALL surface a **bounded, non-blocking** failure (the band's existing failure surface, clean headline, no app-modal alert, no raw error text in a headline) for the parts it **can** observe: there is **no** captured front app, or the pasteboard write fails. The app SHALL NOT claim a confirmed "Done" for the synthesized keystroke itself (which it cannot verify landed) — it reports delivery **attempted** and never fabricates a confirmation it cannot obtain. A delivery that fails an observable step SHALL leave the navigator in a state from which the user can retry or discard.

#### Scenario: No front app surfaces a bounded failure

- **WHEN** there is no captured front application to deliver into
- **THEN** the navigator shows a clean, bounded message and offers retry or discard, rather than silently doing nothing or claiming success

#### Scenario: The keystroke is not falsely confirmed

- **WHEN** a paste is synthesized into a front app that has no text target
- **THEN** the app does not display a confirmed "Done" for the keystroke (it cannot observe the landing), and it never shows a false success
