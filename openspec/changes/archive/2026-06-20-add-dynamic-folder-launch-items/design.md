## Context

The fixed-folder items bake `folder` into `.claudeProject` / `.terminalCommand`, and `LaunchService.fire` is explicitly "fire-and-forget, no mid-gesture picker." The new variant inverts exactly one axis — *where the folder comes from* — while keeping everything else (the command, the Claude executable resolution, the self-deleting `.command` handoff, the `ClaudeLaunchError` / `TerminalLaunchError` taxonomy). `LaunchService` is built with injected closures and currently only *reads* favorites (`favoritesProvider`); `fire(_:inBand:)` already carries `band.id`, and `FavoritesStore.updateItem(itemID, inBand: bandID, _:)` is the write path.

## Decisions

### D1 — New kinds, not a flag on the existing ones
Add `.claudeProjectPrompt(lastFolder: URL?, command: String? = nil, claudePath: String? = nil)` and `.terminalCommandPrompt(lastFolder: URL?, command: String)`. `lastFolder` is the remembered default (nil = none yet → chooser opens at home).
- *Why:* new cases keep the existing kinds' "no mid-gesture picker" guarantee and decode-safety intact, and let the add / edit / fire paths branch cleanly — matching the user's "another action type."
- *Rejected:* making `folder` optional on the existing kinds (nil = prompt) — muddies their semantics and the precedent-set `decodeIfPresent` decoders.

### D2 — Fire-time chooser, then reuse the fixed launch path
On fire, a prompt kind runs an `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`, `directoryURL = lastFolder ?? home`); on `.OK` with a url it calls the SAME `launchClaude` / `launchTerminal` the fixed kinds use (folder = chosen), so the `.command` handoff, Claude resolution, and error surfacing are shared verbatim. A cancel returns without launching or mutating anything — not an error. The accessory app is briefly activated (`NSApp.activate`) so the panel comes forward and is interactive (the overlay has already ordered out by fire time).

### D3 — Remember the last folder via an injected persist closure
Add `onPromptedFolderChosen: (_ itemID: UUID, _ bandID: UUID, _ folder: URL) -> Void` to `LaunchService` (mirrors the `onAICommand` DI), called after a successful pick. `AppCoordinator` wires it to `FavoritesStore.updateItem(itemID, inBand: bandID) { $0.kind = <same kind with lastFolder = folder> }`. `fire` already has `band.id`, so no lookup is needed; `LaunchService` stays decoupled and the persist is a capturing closure in tests.
- *Rejected:* a side `UserDefaults` last-folder map keyed by item id — diverges from the item record and complicates reset/export; the item is the single source of truth.

### D4 — Authoring mirrors the fixed siblings, minus the setup folder
New immediate-add Hub sources create the variant with `lastFolder: nil` + the fixed sibling's default command (the Claude variant resolves `claudePath` at setup as today). The inspector edits the command exactly like the fixed sibling and shows the remembered `lastFolder` read-only with a **Clear** (→ nil, re-asks from home). No setup folder picker — that is the whole point.

## Risks / Trade-offs

- **Accessory-app modal panel front/interactive** → `NSApp.activate(ignoringOtherApps:)` before `runModal`; the app returns to accessory behavior on dismiss.
- **Writing the favorites record on every fire** → a single-field rewrite via the existing `updateItem`, gated by user action frequency; negligible.
- **A `lastFolder` that no longer exists** → `NSOpenPanel` falls back gracefully when `directoryURL` is missing; the pure start-directory resolver returns it regardless and the panel decides.

## Open Questions

- Exact case names (`claudeProjectPrompt` vs `claudeProjectChooseFolder`) — provisional.
- Whether the inspector's "Clear" is enough, or a "use home each time" explicit toggle is wanted — default is remember-last + Clear, no toggle.
