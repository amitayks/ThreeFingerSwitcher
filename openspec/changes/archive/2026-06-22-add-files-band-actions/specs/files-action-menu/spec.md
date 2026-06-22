## ADDED Requirements

### Requirement: An action menu over the highlighted file or folder

The Files band SHALL offer an **action menu** for the highlighted entry, summoned by the configured **menu excursion** (default: the **`+1`-finger lift**). The menu SHALL be offered for **both files and folders** (today's Open-With trigger is files-only; the menu replaces it and works on folders too). The menu SHALL be a **scrubbable, lift-to-commit** surface that rides the existing drill grammar: while it is open, **highlight (vertical) scrubs the menu items**, **lift commits** the highlighted item, and the **four-finger discard backs out** of the menu (returning to folder navigation) without resolving. Entering the menu and backing out of it SHALL **re-arm the drill** so navigation never goes inert.

#### Scenario: The menu opens on a folder

- **WHEN** a folder is highlighted and the user performs the menu excursion
- **THEN** an action menu for that folder appears (it is no longer empty on folders)

#### Scenario: The menu opens on a file

- **WHEN** a file is highlighted and the user performs the menu excursion
- **THEN** an action menu for that file appears

#### Scenario: Scrub and commit

- **WHEN** the menu is open
- **THEN** vertical scrubbing moves the highlighted item and a lift commits the highlighted item

#### Scenario: Discard backs out of the menu

- **WHEN** the menu is open and the user performs the four-finger discard
- **THEN** the menu closes, no item is committed, folder navigation resumes, and the drill is re-armed

### Requirement: Default menu contents per entry type

The action menu's **default** contents SHALL be, in order:

- **File:** Copy as path · Copy · Paste · Open in ▸
- **Folder:** Copy as path · Copy · Paste · ‹installed terminals…› · Open in ▸

The ‹installed terminals…› group SHALL appear for **folders** and expand to one row per installed, enabled terminal. Items whose preconditions are unmet SHALL be hidden (for example, **Paste** SHALL be hidden when the pasteboard holds no file reference). The default lists SHALL be exactly these; any deviation is a user customization (see *configuration-hub* / *tunable-settings*).

#### Scenario: Folder default menu lists terminals

- **WHEN** the default menu opens on a folder and at least one terminal is installed and enabled
- **THEN** the menu shows Copy as path, Copy, Paste, a row per installed terminal, and Open in ▸ in that order

#### Scenario: File default menu omits terminals

- **WHEN** the default menu opens on a file
- **THEN** the menu shows Copy as path, Copy, Paste, and Open in ▸ — with no terminals group

#### Scenario: Paste hides without a file on the clipboard

- **WHEN** the menu opens and the pasteboard holds no file reference
- **THEN** the Paste item is not shown

### Requirement: Copy as path writes the path to clipboard history

The **Copy as path** item SHALL write the entry's **standardized absolute path** as text into the **clipboard history** (the persisted clipboard store) **and** the live pasteboard, so the path is both pasteable now and recallable from the Clipboard band. The history insert SHALL NOT be double-captured as a separate live-pasteboard event (self-write suppression).

#### Scenario: Path is on the clipboard and in history

- **WHEN** the user commits Copy as path on an entry
- **THEN** the entry's absolute path is on the live pasteboard and recorded once in clipboard history

### Requirement: Copy writes the file or folder object to the pasteboard

The **Copy** item SHALL write the entry's **file reference** to the pasteboard (the object, not its path text), so that a subsequent paste in Finder performs the real file/folder copy. Copy SHALL apply to both files and folders.

#### Scenario: Copy then paste-in-Finder copies the object

- **WHEN** the user commits Copy on a file or folder and later pastes in a Finder window
- **THEN** the actual file or folder is copied there (the pasteboard carried the object, not just a path string)

### Requirement: Paste copies the clipboard's file into the target folder (bounded, keep-both)

The **Paste** item SHALL copy the **file reference(s)** currently on the pasteboard **into** the target folder. The target SHALL be the highlighted **folder**, or — for a highlighted **file** — that file's **containing** folder. On a name conflict the copy SHALL **keep both** by auto-renaming the incoming copy (it SHALL NOT overwrite, move, or delete anything). Paste SHALL operate on **file URLs only** in this version; other pasteboard content SHALL NOT be pasted. A failed paste SHALL map at the boundary into the band's error taxonomy and surface as a **bounded, non-blocking** card with retry/dismiss — never an app-modal alert, never raw error text in a headline, and never a false success.

#### Scenario: Paste copies into the folder

- **WHEN** the pasteboard holds a file and the user commits Paste on a highlighted folder
- **THEN** that file is copied into the folder

#### Scenario: Paste into a file targets its parent

- **WHEN** the pasteboard holds a file and the user commits Paste on a highlighted file
- **THEN** the file is copied into that highlighted file's containing folder

#### Scenario: Conflicts keep both, never overwrite

- **WHEN** a paste target already contains an item with the same name
- **THEN** the incoming copy is auto-renamed (keep both); nothing is overwritten, moved, or deleted

#### Scenario: A failed paste surfaces a bounded message

- **WHEN** a paste cannot complete (for example permission denied or the source was removed)
- **THEN** the navigator shows a clean, bounded failure with retry/dismiss and nothing is silently dropped

### Requirement: Open in presents a scrubbable app grid

The **Open in ▸** item SHALL present a **scrubbable grid** of applications (the app-drawer presentation), navigated by the trackpad in **both axes** and **resolved on lift** (the highlighted app opens the entry). For a **file**, the grid SHALL list the applications capable of opening that file, with the default app indicated (today's Open-With set). For a **folder**, the grid SHALL list folder-openers (Finder plus the curated editors/terminals). The grid SHALL remain **pure-trackpad** — no keypress, and the overlay SHALL NOT become key/main for it.

#### Scenario: Open in for a file lists capable apps as a grid

- **WHEN** the user opens "Open in ▸" on a file
- **THEN** a scrubbable grid of the apps that can open that file appears, the default indicated, and a lift opens the file with the highlighted app

#### Scenario: Open in for a folder lists folder-openers

- **WHEN** the user opens "Open in ▸" on a folder
- **THEN** the grid lists Finder and the curated editors/terminals (a folder has no default-app list of its own)

#### Scenario: The grid takes no keypresses

- **WHEN** the app grid is open
- **THEN** it is navigated and resolved entirely by trackpad; the overlay never becomes key/main to capture keys

### Requirement: Open in a terminal opens the folder as the working directory

An installed-terminal item (and an "Open in ‹editor›" item) SHALL open the **folder** rooted as that tool's **working directory**. For a highlighted **file**, the tool SHALL open the file's **containing** folder. The set of offered terminals/editors SHALL be **auto-detected** from installed applications and **user-curated**.

#### Scenario: Open folder in a terminal sets CWD

- **WHEN** the user commits an installed-terminal item on a folder
- **THEN** that terminal opens with the folder as its working directory

#### Scenario: Terminal on a file uses its parent folder

- **WHEN** the user commits a terminal item on a highlighted file
- **THEN** the terminal opens rooted at the file's containing folder

### Requirement: The menu contents and order are user-configurable per type

The action menu SHALL draw from a **catalog** of actions — the per-type defaults plus opt-in extras: **Reveal in Finder**, **Add to Favorites** (insert the entry as a launcher favorite), **Open in ‹editor›**, and **Copy name**. The user SHALL be able to **add, remove, and reorder** items **independently per type** (file vs folder). Removing an item SHALL never remove a load-bearing safety (discard/back-out is always available). The configured menus SHALL persist (see *tunable-settings*).

#### Scenario: User adds an extra and reorders

- **WHEN** the user adds "Add to Favorites" to the file menu and moves it to the top
- **THEN** the file action menu shows it first, persistently across launches

#### Scenario: File and folder menus are configured independently

- **WHEN** the user customizes the folder menu
- **THEN** the file menu is unaffected, and vice versa

#### Scenario: Add to Favorites bridges into the launcher

- **WHEN** the user commits "Add to Favorites" on an entry
- **THEN** that file or folder is inserted as a launcher favorite item
