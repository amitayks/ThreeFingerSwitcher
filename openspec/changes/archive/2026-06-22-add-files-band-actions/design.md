## Context

Everything this change needs already exists as a seam; the work is wiring, not new infrastructure.

- **The front app is captured and stable.** The launcher overlay is **non-activating**, and both `LaunchService` and `SelectionService` already inject `frontAppProvider: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }`, captured at open-time and filtered against `getpid()`. So "deliver to the app I came from" has a well-defined, already-wired target — no focus juggling.
- **Paste-into-front-app is solved.** `SelectionService.paste(_:into:)` does the safe round-trip: snapshot the user's clipboard → write → re-assert front-app activation → synthesize **⌘V** (`CGEvent` key `0x09`, `postToPid`) → restore the clipboard. `LaunchService.writeToPasteboard` already writes **multiple representations** to one `NSPasteboardItem` (string + fileURL + image + color fallbacks).
- **The drill is a column navigator with depth (X) + highlight (Y) + lift-to-commit.** The Open-With picker is already a scrubbable column rendered in `FilesBandView` (single sliding `OpenWithRowHighlight`, navigated by `filesPickerMove`, resolved on lift). An action menu is *the same shape*.
- **The binding foundation just landed.** `add-gesture-previews-and-bindings` added a pure, Codable `GestureBindings` with a Files-drill vocabulary (`{lift, plusOneFingerLift, fourFingerHorizontal}` → `{open, openWith, discard}`), persisted in `AppSettings`, edited via `HubBindingPicker`. This change **extends that vocabulary** rather than inventing a binding system.
- **"Open a tool at a path" exists.** The `open-claude-here` capability already opens a CLI/editor rooted at a directory — the seam the ‹terminals› / ‹editors› items reuse.

The single genuinely new primitive is **one bounded file write** (Paste-into = copy a file *into* a folder). Everything else is reuse.

## Goals / Non-Goals

**Goals:**
- Lift **delivers** the highlighted entry to the captured front app, in the form that context wants — path-as-text where text is expected, the file object where Finder is, with the user's clipboard preserved.
- The `+1`-finger excursion opens a **scrubbable, lift-to-commit action menu** over **both files and folders**, riding the existing drill grammar (no new gesture primitive).
- The default menus are **exactly** the user's lists (file: copy-as-path/copy/paste/open-in; folder: + terminals); contents and order are **user-configurable per type** from the Hub.
- "Open in ▸" is the **app-drawer-style grid** of capable apps (file) / folder-openers (folder), 2-D scrubbable, lift-to-open — generalizing today's vertical Open-With list.
- Errors map into the existing `FileActionError` taxonomy, surfaced **bounded + non-blocking**; a delivery/copy that didn't land is observable, never a false "done."
- Pure model + representation builder + keep-both rename in MLX-free Core, `swift test`-able.

**Non-Goals:**
- Any mutation beyond the **single bounded copy-in** (Paste-into). No move/rename/delete/trash/tag/duplicate. Paste-into **only copies in** and **keeps both** on conflict — it never overwrites.
- Network / iCloud-placeholder locations (unchanged from v1 scope).
- Non-file pasteboard content as a Paste-into **source** — v1 copies in **file URLs** only (image/text-as-file deferred).
- A new gesture primitive. The menu is summoned by the **existing** `+1`-finger excursion; no literal "tap" detector is built (the `+1`-finger lift is the gesture the user already performs and refers to as a third-finger tap).
- Remapping activation finger-counts; new haptics; new permissions.

## Decisions

**1. Delivery is the macOS paste contract, not context-detection.**
On lift, build **one** `NSPasteboardItem` carrying both the file's `.fileURL` **and** its standardized POSIX path as `.string`, write it, and synthesize ⌘V into the captured front app (reusing `SelectionService.paste`'s activate→key→restore round-trip, generalized to take a pasteboard item rather than a bare string). The receiving app picks the representation it understands — **zero detection**:
  - text field / terminal / editor → consumes `.string` → the **path** lands;
  - Finder window → consumes `.fileURL` → the **file copies in**.
The user's clipboard is snapshotted and restored around the synthetic paste, so delivery never clobbers what they had copied.
  *Alternative considered (AX-routed delivery — inspect the focused element and choose path-vs-file explicitly):* rejected for the two common targets — it is fragile (per-app AX quirks) and the pasteboard contract already routes them correctly. AX routing is only needed for the open/save-panel case (Decision 7).

**2. Lift = deliver (new default); open moves into the menu; both are rebindable.**
The Files-drill `lift` action defaults to **deliver**. Open-to-default (file→default app, folder→Finder window) is **not removed** — it becomes a menu item and remains the `open` action in the binding vocabulary, so a user can rebind `lift` back to `open`. `filesOpen()` in `AppCoordinator` splits: the lift path calls `filesDeliver()`; the menu's "Open" row calls the existing open. The defusable-hold and captured-front-app targeting carry over to both.
  *Why:* this is the whole "make it useful" thesis — the band stops duplicating Finder and starts *inserting into where you were*. Keeping `open` one finger-step away (and rebindable) means nothing is lost.

**3. The action menu is another drill column — no new interaction primitive.**
Summoned by the `+1`-finger excursion (today's Open-With trigger, repointed `filesOpenWith` → `filesOpenMenu`). It is a scrubbable column over the navigator: highlight (Y) scrubs items, **lift commits** the highlighted item, the four-finger discard backs out (mirroring the picker's `exitFilesPicker` + `rearmDrill`). "Open in ▸" descends (the drill's depth/X) into a sub-column — the app grid. So Open-With is no longer a *direct* excursion; it is the menu's "Open in ▸" item, now reachable on folders too. **Any handler that leaves the navigator open re-arms the drill** (`rearmDrill`) — the documented Files landmine.

**4. The item catalog is a pure, per-type, ordered model.**
A pure Core `FilesActionMenu`: a catalog of `FilesAction` cases, plus two ordered lists (file, folder) defaulting **exactly** to the user's spec:
  - file: `copyAsPath, copy, pasteInto, openIn`
  - folder: `copyAsPath, copy, pasteInto, openInTerminals, openIn`
  Catalog also includes opt-in extras (`revealInFinder, addToFavorites, openInEditor, copyName`) that are **available but not default**. The model resolves, for a given `FileEntry`, the concrete visible rows (e.g. `openInTerminals` expands to one row per installed terminal; `pasteInto` hides if the pasteboard holds no file). Pure → unit-tested.

**5. Item effects map to existing seams.**
  - **Copy as path** → build a text `ClipboardEntry` (the standardized absolute path) → `ClipboardStore.insert` (lands in clipboard **history**) + write to the live pasteboard, with `ClipboardMonitor.suppressSelfWrite` so the monitor doesn't double-capture.
  - **Copy** → write the entry's `.fileURL` to the pasteboard (the *object*); the real byte copy happens when the user pastes in Finder. Optionally also history-insert a `.file` entry.
  - **Paste into** → Decision 6.
  - **Open in ▸** → the app grid (Decision 8).
  - **‹terminals› / Open in ‹editor›** → reuse the `open-claude-here` "open tool rooted at a directory" seam; the available tools are auto-detected (bundle-id probe via `NSWorkspace.urlForApplication(withBundleIdentifier:)`) and user-curated (Decision 9). A file's "open in terminal/editor" targets its **containing** folder.
  - **Reveal in Finder** → select-in-Finder (`activateFileViewerSelecting`). **Add to Favorites** → insert a real `LaunchItem` into `FavoritesStore` (bridges the band back into the launcher). **Copy name** → `lastPathComponent` to pasteboard.

**6. Paste-into is the one bounded write: copy-in, keep-both, never overwrite.**
Target = the highlighted **folder** (for a highlighted **file**, its **containing** folder). Source = the current pasteboard's **file URLs** (v1). Implementation: `FileManager.copyItem`, and on name conflict **auto-rename** (`name copy`, `name copy 2`, …) so it **never overwrites or moves** the source. Failures map at the boundary into a new `FileActionError` case (`pasteFailed`) and surface as the existing **bounded, non-blocking** card with Retry/Dismiss. The keep-both name resolver is pure → unit-tested.
  *Alternative considered (front Finder + ⌘V, let Finder handle conflicts):* rejected as default — it pops a Finder window (heavier, leaves the band) and performs a *real* app switch; the in-band silent copy keeps the interaction where the user is. (Finder-paste remains available implicitly: "Copy" + open the folder.)
  *This is the only place the `files-band` "non-destructive" scope is widened — and only to a copy-in.*

**7. Open/save-panel delivery is a documented follow-on, AX-gated.**
A focused `NSOpenPanel`/`NSSavePanel` ignores a file paste, so delivery into a file picker needs the **⌘⇧G → type path → Return** idiom (or a synthetic drop). v1 ships the two clean cases (text + Finder) via Decision 1; the picker case is specified but gated behind detecting a front open/save panel (AX `AXSheet` / known subroles) so it never misfires into the common cases. If detection is uncertain, delivery falls back to the pasteboard contract (Decision 1).

**8. "Open in ▸" is a 2-D scrubbable app grid (the app-drawer look).**
Generalize `OpenWithEntries`/the picker from a vertical list to a grid laid out app-drawer-style; the drill already produces X **and** Y steps, so the grid is scrubbed in both axes and **lift opens** with the highlighted app. Candidates: a **file** → `NSWorkspace.urlsForApplications(toOpen:)` (today's path, default app marked); a **folder** → Finder + the curated editors/terminals (a folder has no LaunchServices openers, which is exactly why the menu was empty on folders before). Stays **pure-trackpad** (no keypress, no key-window flip — the Files-band invariant).

**9. Customization extends the binding model + a small persisted config.**
  - **Lift action** (`deliver` / `open` / `openMenu`) joins the `GestureBindings` Files vocabulary (new `deliver`, `openMenu` cases); defaults: `lift → deliver`, `+1-finger → openMenu`, `four-finger → discard`. Edited via the existing `HubBindingPicker`.
  - **Menu contents/order** persist in `AppSettings` as two ordered `[FilesAction]` lists (file, folder), defaulting to Decision 4; edited in `HubFilesPage` (add/remove/reorder from the catalog).
  - **Terminals/editors**: auto-detected set, with a user-curated allow-list persisted in `AppSettings`.
  All new settings are included in reset semantics and default to the behavior above.

**10. Delivery/copy observability — honest about the limit.**
A copy-in or history-insert has a checkable result → `.failed` on error (existing card). A **synthesized ⌘V** cannot be confirmed to have *landed* in the front app (same limitation as the AI band's auto-paste): the band reports delivery **attempted**, and surfaces `.failed` only on the parts it *can* observe (no front app, pasteboard write failed, target rejected the activation). We do **not** fake a "Done" for the keystroke itself, and we do **not** invent a confirmation we can't get.

## Risks / Trade-offs

- **Delivery into a target with no text field silently no-ops** (⌘V rings the bell). Mitigated by Decision 10 (observe what we can; never false "Done"); accepted as the same bound the AI auto-paste already lives with.
- **Paste-into is the first write the band performs** → keep it copy-in + keep-both (never overwrite/move), file-URLs only, boundary-mapped errors, and unit-test the rename resolver; the `files-band` scope delta is narrow and explicit.
- **`+1`-finger now opens a menu instead of going straight to Open-With** → a behavior change for current users; Open-With is one step in (the menu's "Open in ▸"), and the change is the point (a richer menu on folders too). Defaults keep Open-With reachable.
- **Menu-as-column depth collides with folder-descend depth** → the menu is a modal sub-state of the drill (like the Open-With picker today): while open, depth/highlight scrub the **menu/grid**, not the folder tree; discard backs out one level; re-arm on every level (the documented landmine).
- **Cross-change coupling** to `add-gesture-previews-and-bindings` (the binding vocabulary) → that change is 26/27; this one extends, not reopens, it. Spec deltas here avoid `gesture-bindings` (not yet archived) and target only archived capabilities + the two new ones.

## Open Questions (tuning, not design)

- **App-grid sizing / columns** inside the overlay — pick a sensible default grid shape and tune in run-verify; no paper-derivable value.
- **Which bundle-ids seed the auto-detected terminals/editors** list (Terminal, iTerm, Warp, Ghostty, kitty, Alacritty, WezTerm, Hyper; VS Code, Cursor, Sublime, Zed, …) — start from a conservative known list, let the user add others.
- **Whether "Copy" also history-inserts a `.file` entry** by default, or only writes the pasteboard — decide in run-verify against clipboard-history noise.
