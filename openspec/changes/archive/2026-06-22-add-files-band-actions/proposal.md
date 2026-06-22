## Why

The Files band today is "another way to open files" — which Finder and Spotlight already do. Its one differentiated move (the `+1`-finger Open-With picker) is **empty on folders** (`openWithCandidates` returns `[]` for directories) and thin on files, and a lift just *opens*. But the band sits one flick away from whatever you were doing — a terminal, a Finder window, an editor, a file-open dialog — and the overlay is **non-activating**, so the app you came from is still right there, focus intact and **already captured** (`frontAppProvider` → `NSWorkspace.frontmostApplication`). That captured context is the unlock: the band should **deliver** the item you land on back into the app you came from, in the form that place wants — a **path** into a text field, the **file** into a Finder folder, a destination into an open/save panel. And the extra-finger gesture you already reach for (today's "Open With" trigger — the move the user thinks of as a third-finger tap) should summon a real, **customizable action menu** that works on **folders too**, not just a bare app list.

This turns the Files band from a redundant opener into the thing nothing else is: a trackpad-native, contextual **file-inserter** for the app you came from.

## What Changes

- **Lift delivers the highlighted item to the captured front app — the new default resolution.** The item is written to the pasteboard in **two representations at once** — the file's `.fileURL` **and** its POSIX path `.string` — then a paste is synthesized into the captured front app (reusing `SelectionService.paste`). macOS's paste contract routes it with **no context-detection**: a text field / terminal / editor takes the path string; a Finder window takes the file and copies it in. The user's own clipboard is **snapshotted and restored** around the synthetic paste. Open-to-default is **not removed** — it moves into the action menu, and the lift action is **user-configurable** (a user can rebind lift back to open).
- **The `+1`-finger excursion opens a real action menu** over **both files and folders** (today it goes straight to a files-only Open-With list). The menu is a scrubbable, **lift-to-commit drill column** — it rides the existing odometer depth/highlight + lift grammar, so there is **no new gesture primitive**. Default contents:
  - **File:** Copy as path · Copy · Paste · Open in ▸
  - **Folder:** Copy as path · Copy · Paste · ‹installed terminals…› · Open in ▸
- **Menu item effects:**
  - **Copy as path** → writes the absolute path into the **clipboard history** (`ClipboardStore.insert`) and the live pasteboard.
  - **Copy** → writes the file/folder **object** (`.fileURL`) to the pasteboard; a later paste-in-Finder performs the real copy.
  - **Paste** → copies the current pasteboard's file(s) **into** the highlighted folder (for a highlighted file: into its **containing** folder) — a **bounded, keep-both** copy-in.
  - **‹terminals›** → opens the folder as the working directory in each **installed** terminal (auto-detected; user-curated).
  - **Open in ▸** → a scrubbable **app grid** (the "app drawer" look the user asked for) of the apps that can open the item (file) or open the folder (Finder/editors), generalizing today's vertical Open-With list; lift opens with the highlighted app.
- **Customizable.** The menu's contents and order are user-configurable **per type** (file vs folder) from the Hub Files page, chosen from a catalog: the defaults above plus opt-in extras — **Reveal in Finder**, **Add to Favorites**, **Open in ‹editor›**, **Copy name**. Which terminals/editors appear is auto-detected and curatable. The Files **lift** action (deliver / open / open-menu) is configurable, **extending the just-built `GestureBindings` Files vocabulary**.
- **No new permission, no gesture relocation, no re-login.** Reuses the captured front-app context, `SelectionService.paste`, `LaunchService.writeToPasteboard`, `ClipboardStore`, the `open-claude-here` "open a tool at a path" plumbing, and the odometer drill. The single net-new mutation is one bounded copy-in (Paste).

## Capabilities

### New Capabilities

- `files-contextual-delivery`: lift delivers the highlighted entry to the **captured** front app via a dual-representation pasteboard write (`.fileURL` + path `.string`) + a synthesized, clipboard-preserving paste; macOS routes the representation per target (path into text, file into Finder); a delivery that lands nowhere is surfaced as observable (never a false "done"); plus the open/save-panel navigation case.
- `files-action-menu`: the `+1`-finger, scrubbable, **lift-to-commit** action menu over a file or folder — its drill-column interaction, the item catalog and effects (Copy as path, Copy, Paste-into, ‹terminals›, Open-in app grid, and the opt-in extras), the file-vs-folder default sets, and the user-configurable contents/order.

### Modified Capabilities

- `files-band`: the drill **resolution grammar** — lift defaults to **deliver** (was open); the `+1`-finger excursion opens the **action menu** (Open-With folds in as the menu's "Open in ▸"); open-to-default and Open-With stay reachable **inside** the menu; the **local-only / non-destructive** scope gains exactly **one** bounded copy-in (Paste-into) — still never moving, renaming, deleting, trashing, or overwriting.
- `configuration-hub`: the Files page gains controls to configure the action-menu contents/order per type, curate the terminals/editors, and set the Files lift action.
- `tunable-settings`: new persisted settings — the per-type menu item lists/order, the Files lift action, and the selected terminals/editors.

## Impact

- **Code (MLX-free Core + app):**
  - **Delivery:** a new files-delivery path that builds a dual-representation pasteboard write (reusing `LaunchService.writeToPasteboard`'s multi-rep + `SelectionService.paste`'s snapshot→set→⌘V→restore) and routes through the existing **captured front-app** seam; `filesOpen()` in `AppCoordinator` splits into deliver (default lift) vs the in-menu open/Open-With.
  - **Action menu:** a new `FilesActionMenu` model (pure Core: the per-type item lists + the catalog + ordering) and an overlay column in `FilesBandView` modeled on the existing Open-With picker (single sliding highlight, scrubbable, lift-to-commit); the `+1`-finger excursion in the Files drill repoints from `filesOpenWith` to `filesOpenMenu`.
  - **Item effects:** Copy-as-path/Copy via `ClipboardStore.insert` + pasteboard; Paste-into via a new bounded `FileManager.copyItem` (keep-both rename) mapped into `FileActionError`; terminals/editors via the `open-claude-here` "open tool at path" seam; Open-in app grid generalizing `OpenWithEntry`/the picker to 2-D scrub.
  - **Customization:** extends `GestureBindings`' Files vocabulary (new `deliver` / `openMenu` actions) and adds persisted menu-config + terminal-selection to `AppSettings`; Hub Files page (`HubFilesPage.swift`) gains the editors.
- **Reuse, not rebuild:** the captured `frontAppProvider`, `SelectionService.paste`, `LaunchService.writeToPasteboard`, `ClipboardStore`, `OpenWithEntries`/`FileOpenService`, `FileActionError`, the odometer drill + lift-to-commit grammar, and the Hub's existing binding-editor machinery.
- **Depends on `add-gesture-previews-and-bindings`** (in-progress, 26/27) for the `GestureBindings` Files vocabulary this change extends; the spec deltas here target only already-archived capabilities (`files-band`, `configuration-hub`, `tunable-settings`) plus the two new ones, so they validate independently.
- **MLX-free Core:** the action-menu model, the per-type item lists/catalog, the delivery representation builder, and the keep-both rename are pure and `swift test`-able; the live paste/copy-in, app grid, and terminal launch need the real app (compile-verify via `xcodebuild`, run-verify by the user).
- **Out of scope:** move/rename/delete/trash/tag (Paste-into is the only write, and it only **copies in**, keep-both); network/iCloud locations; non-file pasteboard content as Paste-into source (file URLs only in v1); haptics; any new permission.
