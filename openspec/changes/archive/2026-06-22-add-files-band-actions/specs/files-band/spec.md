## MODIFIED Requirements

### Requirement: Open a file or folder in the current Space

Opening a highlighted entry SHALL open it for real: a **file** opens in its default application, a **folder** opens as a real Finder window. Open is an **action reached from the action menu** (and is the action a user MAY rebind the lift to); it is **no longer the default lift resolution** — the default lift **delivers** the entry to the captured front app (see *files-contextual-delivery*). The opened window SHALL appear on the **current Space** (it SHALL NOT teleport the user to another Space or app), and the open SHALL target the **front application captured when the launcher opened**, never whichever app is frontmost at the instant of firing (the overlay is non-activating). A failed open SHALL surface as an observable failure (see *Failures are observable, never silent*), never a silent false success.

#### Scenario: Opening a file launches its default app on the current Space

- **WHEN** the user commits "Open" on a highlighted file
- **THEN** the file opens in its default application and the resulting window appears on the current Space

#### Scenario: Opening a folder opens a Finder window

- **WHEN** the user commits "Open" on a highlighted folder
- **THEN** that folder opens as a Finder window on the current Space

#### Scenario: Open targets the captured front app, not this overlay

- **WHEN** an open is committed from the non-activating overlay
- **THEN** the action targets the app that was frontmost when the launcher opened, not the overlay

#### Scenario: Open is not the default lift

- **WHEN** the user lifts on a highlighted entry with the default lift binding
- **THEN** the entry is delivered to the captured front app (not opened); Open is performed only when chosen from the action menu or when lift is explicitly rebound to open

### Requirement: Open With the relevant applications

The Files band SHALL offer **Open With** as the **"Open in ▸"** item of the action menu, reachable for **both files and folders**. For a **file** it SHALL list **only the applications capable of opening that file** (not the full installed-apps list), with the file's **default application indicated**; for a **folder** it SHALL list folder-openers (Finder plus the curated editors/terminals). The candidate list SHALL be presented as a **scrubbable grid** (the app-drawer presentation) navigated by trackpad in both axes and resolved on lift. Choosing an application SHALL open the entry with that application, on the current Space, targeting the captured front-app context. The file's relevant-apps list SHALL be derived from the system's association of applications to that file and SHALL be computed **on demand**.

#### Scenario: Open-With lists only capable apps for a file

- **WHEN** the user opens "Open in ▸" on a highlighted file
- **THEN** the presented grid contains only applications that can open that file, with the default app indicated

#### Scenario: Choosing an app opens the file with it

- **WHEN** the user highlights an application in the grid and lifts
- **THEN** the file opens with the chosen application on the current Space

#### Scenario: Open-With is now offered for folders too

- **WHEN** the highlighted entry is a folder
- **THEN** "Open in ▸" is offered and lists folder-openers (Finder and the curated editors/terminals), rather than being absent

### Requirement: Local-only, non-destructive scope

The Files band SHALL remain **local-only** and SHALL NOT read network or iCloud-placeholder locations. The band SHALL perform **exactly one** mutating operation — the action menu's **Paste-into**, which **copies** a file from the pasteboard **into** a folder, **keeping both** on conflict (auto-rename). It SHALL NOT **move, rename, delete, trash, overwrite, or tag** any file or folder. All other navigation, delivery, copy-to-clipboard, and open actions are non-mutating. The single copy-in is the only widening of the original navigate-and-open scope.

#### Scenario: The only mutation is a keep-both copy-in

- **WHEN** the user navigates and acts in the Files band
- **THEN** the only operation that writes to disk is Paste-into, which copies a file into a folder and keeps both on conflict

#### Scenario: No move, delete, rename, or overwrite is exposed

- **WHEN** the user navigates the Files band
- **THEN** no available action moves, renames, deletes, trashes, overwrites, or tags any file or folder

#### Scenario: Network and iCloud locations stay out of scope

- **WHEN** the user configures or navigates roots
- **THEN** only local entries are listed; network and iCloud-placeholder locations are not read
