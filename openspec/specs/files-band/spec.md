# files-band Specification

## Purpose
TBD - created by archiving change files-band. Update Purpose after archive.
## Requirements
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

The Files band SHALL open onto a set of **user-configured local root folders** (its entry column). Each root SHALL track the **deepest location** the user last navigated to within it. A **"remember and reopen the last folder" toggle** (default ON) SHALL govern whether that remembered location is *used to land*:

- When the toggle is **ON**, the band SHALL **open displaying** the remembered deepest folder (restored at open, with its ancestor chain reconstructed so ascending walks back up), and **re-entering a root** (descending into it from the roots list) SHALL restore that root's remembered location.
- When the toggle is **OFF**, the band SHALL **open on the roots list**, and descending into a root SHALL land on that root's **top level** — it SHALL NOT jump to the remembered location. The deepest-location *tracking* SHALL continue regardless of the toggle, so turning it back ON restores correctly.

The displayed column and the navigation state SHALL always agree (no visual/state desync): what the band shows on open is exactly where horizontal navigation begins. Navigating fully out (ascending past a root's top level) SHALL return to the roots list. Roots SHALL reference **local** folders only.

#### Scenario: Entry shows the configured roots
- **WHEN** the user lands on the Files band with the remember toggle OFF
- **THEN** the current column lists the configured root folders

#### Scenario: A root remembers where you left off (toggle ON)
- **WHEN** the remember toggle is ON and the user descends several levels inside a root, leaves the band, and later re-enters that root
- **THEN** the navigator restores the folder the user was last in within that root

#### Scenario: Toggle OFF never jumps to the last-visited folder
- **WHEN** the remember toggle is OFF and the user descends into a root from the roots list
- **THEN** the navigator lands on that root's top level, not the previously-visited deeper folder

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

The Files band SHALL remain **local-only** and SHALL NOT read network or iCloud-placeholder locations. Its filesystem mutations SHALL be bounded to **recoverable, non-overwriting** operations — it SHALL never cause **irreversible data loss**. Specifically the band MAY:

- **copy a file into** a folder (Paste after Copy) — **keep-both** on conflict (auto-rename);
- **move a file into** a folder (Paste after **Cut**) — **keep-both** on conflict (auto-rename), relocating the source (not destroying it);
- **move an entry to the Trash** (**Delete**) — recoverable from the Finder Trash.

The band SHALL NOT **permanently delete** (it trashes, never `removeItem`), **overwrite** (every copy/move keeps both on conflict), **rename in place**, or **tag** any file or folder. All navigation, delivery, copy-to-clipboard, and open actions remain non-mutating. These are the only widenings of the original navigate-and-open scope, and each is recoverable.

#### Scenario: Mutations are bounded to copy-in, move-in, and trash

- **WHEN** the user acts in the Files band
- **THEN** the only operations that touch the filesystem are copy-into-folder, move-into-folder (Cut→Paste), and move-to-Trash (Delete)

#### Scenario: No permanent delete or overwrite is exposed

- **WHEN** the user navigates the Files band
- **THEN** no available action permanently deletes (Delete trashes, recoverably), overwrites (copies/moves keep both on conflict), renames in place, or tags any file or folder

#### Scenario: Network and iCloud locations stay out of scope

- **WHEN** the user configures or navigates roots
- **THEN** only local entries are listed; network and iCloud-placeholder locations are not read

### Requirement: Dwell-to-arm gates Files-band resolution

The Files band SHALL arm by **dwell**, like every other launcher surface (mirroring *launcher-overlay → Dwell-to-arm with feedback*). Resting the highlight on a row — in the navigator **or** in any sub-column (the action menu, the Open-With picker, the "Open in ▸" app grid) — for at least the configured dwell-to-arm duration SHALL **arm** that row. Arming SHALL be signalled by the existing best-effort haptic **arm tick** and a visual **charge-ring** that fills over the dwell duration and locks when armed. Moving the highlight — a highlight step, a depth descend/ascend, an async re-list that shifts the highlighted row, or a sub-column move — SHALL **reset the dwell and disarm**. Holding at the trackpad edge (auto-drill / highlight auto-repeat) SHALL re-charge on every step, so it never arms mid-scroll. Adding the `+1` finger SHALL NOT reset the dwell (it does not change the highlighted item); **entering** a sub-column SHALL begin a fresh dwell on its first row.

This **supersedes** the band's prior resolve-on-lift-without-arming behavior, and supersedes the band's "add no new haptics" note **for the arm moment only** — the arm tick is the product's existing single haptic ("moments of arrival"), not a new pattern; no per-scrub, per-descend, or per-commit haptics are added. The dwell duration is the same `dwellToArmDuration` that governs the rest of the launcher (no Files-specific setting).

#### Scenario: Dwell arms the highlighted row

- **WHEN** the highlight rests on a Files row for at least the dwell duration
- **THEN** the row becomes armed, the arm haptic fires (if available), and the charge-ring shows armed

#### Scenario: Charge-ring tracks partial dwell

- **WHEN** the highlight has rested on a row for less than the dwell duration
- **THEN** the charge-ring is partially filled and the row is not armed

#### Scenario: Moving the highlight disarms

- **WHEN** a row is armed and the user steps the highlight, descends/ascends, or scrubs a sub-column to another row
- **THEN** the previous row disarms, its ring empties, and the new row begins its own dwell

#### Scenario: Auto-drill never arms mid-scroll

- **WHEN** the user holds at the trackpad edge and the tree auto-drills (or the highlight auto-repeats)
- **THEN** the dwell re-charges on every step and no row arms until the motion settles

#### Scenario: Adding the +1 finger preserves the arm

- **WHEN** a row is armed and the user adds the `+1` finger without moving the highlight
- **THEN** the row stays armed (the dwell is not reset)

### Requirement: Files lift fires only when armed

A **committing** Files lift SHALL fire **only when the highlighted row is armed**; if no row is armed, lifting SHALL **dismiss the overlay** without acting (mirroring *launcher-overlay → Lift fires only when armed*). This SHALL apply to every committing resolution — the default lift (**deliver** to the captured front app, or **open** when the lift is rebound), the `+1`-finger lift (**open the action menu**), and a **lift that commits a sub-column row** (an action-menu row, an Open-With / app-grid app). A quick scrub-and-lift (no dwell) SHALL therefore never deliver, open, open the menu, or commit a row. The four-finger **discard** (back-out) SHALL **never** be gated by arm — it backs out one level (or dismisses) armed or not, and SHALL NOT terminate a running application (the *Defusable open* rule is unchanged). The arm gate SHALL sit **before** the action fires, so the existing defuse window and observable-failure behavior are unchanged.

#### Scenario: Armed lift acts

- **WHEN** a Files row is armed and the fingers lift
- **THEN** the committing action fires (deliver / open / open-menu / commit the row) and the overlay resolves as before

#### Scenario: Unarmed lift dismisses

- **WHEN** the fingers lift while no Files row is armed
- **THEN** the overlay hides and nothing is delivered, opened, or committed

#### Scenario: Scrub-and-lift never delivers

- **WHEN** the user scrubs onto a file and lifts before the dwell completes
- **THEN** nothing is delivered to the front app and the overlay dismisses

#### Scenario: The +1-finger menu requires an armed row

- **WHEN** the user adds the `+1` finger and lifts on a row that has not armed
- **THEN** the action menu does not open and the overlay dismisses

#### Scenario: Discard is never gated by arm

- **WHEN** the user issues the four-finger discard while no row is armed
- **THEN** the back-out / dismiss happens normally and no running application is terminated

