## Why

The launcher's "Open Claude Here" and "Open in Terminal" items each bind a single folder chosen at setup — perfect for a fixed project, but you often want to fire the *same* action at a *different* folder each time without creating a separate item per folder. Add a variant that asks for the folder at trigger time (a native folder chooser) and remembers the last one you picked, so repeated use defaults back to where you were.

## What Changes

- **Two new choose-folder-at-launch variants** — a sibling of Open-Claude and of Open-in-Terminal — that, when fired, present a native "Choose Folder" dialog instead of using a baked-in folder, then launch into the selected folder exactly as the fixed siblings do.
- **The chooser opens at the last folder used** by that item (or the home folder the first time). Selecting a folder launches there **and remembers it** as the item's new default; **canceling aborts** (no launch, no change, not an error).
- **Authoring mirrors the fixed siblings, minus the setup folder:** new Hub add-sources create the variants with only a command (defaulting like the fixed siblings); the inspector edits the command and shows the remembered folder with a control to clear it (back to "ask from home").
- Reuses the existing **no-new-permission** `.command` terminal handoff, the Claude executable resolution, and the bounded/non-blocking error surfacing.

## Capabilities

### Modified Capabilities

- `open-claude-here`: adds a choose-folder-at-launch variant of both the Claude and the Terminal item — a fire-time native folder chooser defaulting to the item's last-used folder, the chosen folder remembered for next time, authored without a setup folder. The existing fixed-folder items are unchanged.

## Impact

- **Code:** `Launcher/LaunchItem.swift` (two new `LaunchItemKind` cases carrying `lastFolder: URL?` + command/claudePath), `Launcher/LaunchService.swift` (fire → `NSOpenPanel` at `lastFolder` → reuse `launchClaude`/`launchTerminal` → persist via a new injected closure), `App/AppCoordinator.swift` (wire the persist closure to `FavoritesStore.updateItem`), `Hub/BandsCanvas.swift` (add-sources + inspector), reusing `ClaudeLauncher`/`TerminalLauncher`.
- **Behavior:** no new permission (same self-deleting `.command` handoff); MLX-free Core, verified under `swift build` / `swift test`. The fire-time panel briefly activates the accessory app so the dialog comes forward.
- **Migration:** none — these are new kinds; existing items decode and behave unchanged.
