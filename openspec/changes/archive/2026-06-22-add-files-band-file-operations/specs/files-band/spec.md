## MODIFIED Requirements

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
