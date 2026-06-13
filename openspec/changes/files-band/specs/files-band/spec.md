## ADDED Requirements

### Requirement: Opt-in Files band injected into the launcher

The app SHALL provide a **Files band** as an opt-in (default **off**) that, when enabled, is injected into the four-finger launcher as a **synthetic band** — appended at launcher-open time like the Clipboard band and **never persisted** into the authored favorites. Enabling the Files band SHALL NOT relocate any native gesture, SHALL NOT require a re-login, and SHALL NOT request any new permission; it reads the local filesystem on demand. The opt-in SHALL take effect immediately (no `is…Effective` gate): toggling it on injects the band on the next launcher open, toggling it off removes it.

#### Scenario: Disabled by default
- **WHEN** the app is first run with no prior configuration
- **THEN** the Files band is absent from the launcher and no filesystem is read

#### Scenario: Enabling injects the band immediately
- **WHEN** the user turns the Files band opt-in on
- **THEN** the next time the launcher opens, the Files band appears as a band, with no re-login and no new permission prompt

#### Scenario: The band is never written into authored favorites
- **WHEN** the Files band is enabled and shown
- **THEN** it is appended at launcher-open time and is not saved into the user's authored bands store

### Requirement: Configured roots with remembered locations

The Files band SHALL open onto a set of **user-configured local root folders** (its entry column). Each root SHALL remember the **deepest location** the user last navigated to within it, and re-entering that root SHALL restore that location. Navigating fully out (ascending past a root's top level) SHALL return to the roots list. Roots SHALL reference **local** folders only.

#### Scenario: Entry shows the configured roots
- **WHEN** the user lands on the Files band
- **THEN** the current column lists the configured root folders

#### Scenario: A root remembers where you left off
- **WHEN** the user descends several levels inside a root, leaves the band, and later re-enters that root
- **THEN** the navigator restores the folder the user was last in within that root

#### Scenario: Backing out returns to the roots list
- **WHEN** the user ascends from a root's top level
- **THEN** the current column returns to the roots list

### Requirement: On-demand local directory listing

The Files band SHALL list a folder's contents by reading the **live local filesystem on demand** (no background indexing, no recording, no persisted file cache). Listing SHALL be performed **off the main thread** so navigation never blocks the UI, and SHALL request only the resource values it needs (is-directory, modification date, regular-file). Each listed entry SHALL carry a **stable identity derived from its absolute path** so repeated listings and live directory changes do not cause the selection highlight to strobe or jump. Entries SHALL be ordered by a configurable **sort order**. Network and iCloud-placeholder locations are out of scope; only local entries are listed.

#### Scenario: Folder contents are read live
- **WHEN** the user descends into a folder
- **THEN** that folder's current local contents are listed, reflecting the filesystem at that moment

#### Scenario: Listing does not block the UI
- **WHEN** a large folder is opened
- **THEN** the navigator remains responsive while its contents load

#### Scenario: Stable identity prevents strobing
- **WHEN** a folder is re-listed (on re-entry, or because a file changed on disk)
- **THEN** entries keep stable identities by path and the highlight does not flicker or jump

### Requirement: Column navigation model

The Files band SHALL maintain a **navigation stack**: an ordered list of **ancestor folders**, a **current folder** whose entries are listed, and a **highlighted entry** within it. Descending into a highlighted folder SHALL push the prior current folder onto the ancestors and make the highlighted folder current; ascending SHALL pop the deepest ancestor back to current. The highlighted entry's **preview target** SHALL be the entry itself — a file previews itself, a folder previews its own contents — so descending into a folder is equivalent to promoting that folder's preview to the current column.

#### Scenario: Descend pushes an ancestor and makes the child current
- **WHEN** a folder is highlighted and the user descends
- **THEN** the prior current folder becomes the deepest ancestor and the highlighted folder becomes the current folder

#### Scenario: Ascend pops back to the parent
- **WHEN** the user ascends
- **THEN** the deepest ancestor becomes the current folder again and the prior current folder is dropped

#### Scenario: Highlighting a file targets the file for preview
- **WHEN** a file entry is highlighted
- **THEN** the preview target is that file

#### Scenario: Highlighting a folder targets its contents for preview
- **WHEN** a folder entry is highlighted
- **THEN** the preview target is that folder's contents, which descending would promote to the current column

### Requirement: Open a file or folder in the current Space

Committing the **default open** of a highlighted entry SHALL open it for real: a **file** opens in its default application, a **folder** opens as a real Finder window. The opened window SHALL appear on the **current Space** (it SHALL NOT teleport the user to another Space or app), and the open SHALL target the **front application captured when the launcher opened**, never whichever app is frontmost at the instant of firing (the overlay is non-activating). A failed open SHALL surface as an observable failure (see *Failures are observable, never silent*), never a silent false success.

#### Scenario: Opening a file launches its default app on the current Space
- **WHEN** the user commits the default open on a highlighted file
- **THEN** the file opens in its default application and the resulting window appears on the current Space

#### Scenario: Opening a folder opens a Finder window
- **WHEN** the user commits the default open on a highlighted folder
- **THEN** that folder opens as a Finder window on the current Space

#### Scenario: Open targets the captured front app, not this overlay
- **WHEN** an open is committed from the non-activating overlay
- **THEN** the action targets the app that was frontmost when the launcher opened, not the overlay

### Requirement: Open With the relevant applications

The Files band SHALL offer an **Open-With** action for the highlighted **file** that lists **only the applications capable of opening that file** (not the full installed-apps list), with the file's **default application indicated**. Choosing an application SHALL open the file with that application, on the current Space, targeting the captured front-app context. The relevant-apps list SHALL be derived from the system's association of applications to that file and SHALL be computed **on demand** for the highlighted file.

#### Scenario: Open-With lists only capable apps
- **WHEN** the user invokes Open-With on a highlighted file
- **THEN** the presented list contains only applications that can open that file, with the default app indicated

#### Scenario: Choosing an app opens the file with it
- **WHEN** the user selects an application from the Open-With list and commits
- **THEN** the file opens with the chosen application on the current Space

#### Scenario: Open-With is offered for files, not folders
- **WHEN** the highlighted entry is a folder
- **THEN** the Open-With action is not offered for it (its default open is a Finder window)

### Requirement: Defusable open

A committed open SHALL be **defusable** until it actually launches: it SHALL be held (briefly, or pending an explicit commit) so that a **discard** issued before it fires **cancels it and opens nothing**. Defusing SHALL **never terminate an already-running application** — it only prevents a not-yet-fired open. Once the target has actually been opened, a later discard SHALL NOT attempt to kill it.

#### Scenario: Discard before launch opens nothing
- **WHEN** the user commits an open and then discards before the open has fired
- **THEN** nothing is opened and the navigator resolves with no side effect

#### Scenario: Defusing never kills a running app
- **WHEN** the user discards an open whose target application was already running
- **THEN** the running application is left untouched (defuse cancels only the pending open)

### Requirement: Failures are observable, never silent

All Files-band side effects (directory listing, open, Open-With) SHALL map any underlying filesystem or workspace error into the app's shared error taxonomy **at the layer boundary**, and SHALL surface a failure as a **bounded, non-blocking** state carrying a clean headline — never an app-modal alert, never raw error text in a headline, and never a false "opened" when the side effect did not land. A failed open SHALL leave the navigator in an observable failed state from which the user can retry or discard.

#### Scenario: A failed open surfaces a clean, bounded message
- **WHEN** an open fails (for example the file was removed, or no application can open it)
- **THEN** the navigator shows a clean, bounded failure message (not raw error text, not an app-modal alert) and offers retry or discard

#### Scenario: A listing error does not crash or hang
- **WHEN** a folder cannot be read (for example permission denied)
- **THEN** the navigator surfaces a bounded message in place and remains responsive

### Requirement: Local-only, non-destructive scope

The Files band v1 SHALL be **navigation and open only**: it SHALL NOT move, rename, delete, trash, copy, or tag files, and SHALL NOT read network or iCloud-placeholder locations. These are explicit non-goals; the navigator never mutates the filesystem.

#### Scenario: No destructive operations are exposed
- **WHEN** the user navigates the Files band
- **THEN** no available action moves, renames, deletes, or otherwise mutates any file or folder
