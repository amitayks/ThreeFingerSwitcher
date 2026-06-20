## 1. Model — two new kinds

- [x] 1.1 `LaunchItem.swift`: added `.claudeProjectPrompt(lastFolder: URL?, command: String? = nil, claudePath: String? = nil)` and `.terminalCommandPrompt(lastFolder: URL?, command: String = "")`; documented the choose-at-launch + remember-last contract; both `isConsequential` like their fixed siblings.
- [x] 1.2 Codable round-trips (incl. all-nil) and a legacy decode-without-`lastFolder` test in `LaunchItemTests`.

## 2. Fire — chooser + launch + remember

- [x] 2.1 Pure `LaunchService.promptStartDirectory(lastFolder:home:)` (lastFolder ?? home), `nonisolated` + unit-tested.
- [x] 2.2 `LaunchService.fire`: the two prompt arms run `promptFolderThenLaunch` — `NSApp.activate`, `NSOpenPanel(canChooseDirectories, canChooseFiles=false, directoryURL=…)`, `runModal`; on `.OK` reuse the existing `launchClaude`/`launchTerminal`; cancel = no-op.
- [x] 2.3 Injected `onPromptedFolderChosen: (UUID, UUID, URL) -> Void` (default no-op), called after a successful pick with `item.id`, `band.id`, chosen folder.

## 3. Persist — wire the write-back

- [x] 3.1 Pure `LaunchItemKind.withLastFolder(_:)` rewrites a prompt kind's `lastFolder` (preserving command/claudePath; no-op for non-prompt kinds); unit-tested.
- [x] 3.2 `AppCoordinator`: wired `onPromptedFolderChosen` to `favoritesStore.updateItem(itemID, inBand: bandID) { $0.kind = $0.kind.withLastFolder(folder) }`.

## 4. Authoring — add sources + inspector

- [x] 4.1 `BandsCanvas`: two new immediate-add sources (`claudeProjectPrompt` / `terminalPrompt`, no setup folder) + factories `ClaudeLauncher.makePromptItem` / `TerminalLauncher.makePromptItem`; the Claude variant resolves `claudePath` at setup like the fixed one.
- [x] 4.2 Inspector: `claudePromptEditor` / `terminalPromptEditor` edit the command like the fixed siblings and show the remembered `lastFolder` with a **Clear** (→ nil) via `promptFolderRow`.

## 5. Errors, specs, verify

- [x] 5.1 Reused `ClaudeLaunchError` / `TerminalLaunchError`; a cancel surfaces nothing (not an error).
- [x] 5.2 `swift build --target ThreeFingerSwitcherCore` && `swift test` green (907 tests, +4 new).
- [ ] 5.3 In-app: fire a Claude-prompt item → chooser opens at last folder (home first time) → pick → Claude opens there → re-fire defaults to that folder; same for Terminal; cancel is a clean no-op. _(Needs the signed app.)_
- [ ] 5.4 `openspec validate add-dynamic-folder-launch-items --strict`; sync the `open-claude-here` delta; archive. _(After 5.3 confirms in-app.)_
