## 1. Model & error taxonomy (MLX-free Core)

- [x] 1.1 Add `case claudeProject(folder: URL, claudePath: String? = nil)` to `LaunchItemKind` in `Sources/ThreeFingerSwitcher/Launcher/LaunchItem.swift`, with a doc comment noting it is a persisted, first-class band item (like `.aiCommand`, not synthetic like `.fileEntry`). Keep `claudePath` Optional so the synthesized decoder uses `decodeIfPresent` and pre-feature records still decode (the `.url`/`.action` precedent).
- [x] 1.2 Provide the kind's default appearance: title = folder's `lastPathComponent`, an SF-symbol icon (`sparkles`), and tint — via the testable Core factory `ClaudeLauncher.makeItem(folder:claudePath:)`, used by the editor's add flow; `naturalIcon`/`kindLabel`/`isConsequential` extended for the new kind.
- [x] 1.3 Add a Core `ClaudeLaunchError: LocalizedError` (parallel to `FileActionError`) with cases `claudeNotFound`, `terminalOpenFailed`, `scriptWriteFailed`, each with a clean, human-readable `errorDescription` (no raw OS text) plus opt-in `copyableDetails`. (in `Launcher/ClaudeLaunch.swift`)

## 2. Claude resolution & terminal handoff

- [x] 2.1 Add a `claude` locator (`ClaudeLauncher.resolveClaudePath`) that resolves the absolute path off-main via a login+interactive shell (`zsh -lic 'command -v claude'`) with a watchdog timeout, plus a well-known-install-path backstop; returns `nil` when not found.
- [x] 2.2 Add a `.command` builder (`ClaudeLauncher.commandScript` / `writeCommandFile`) that composes the self-deleting script (`rm -f "$0"` → `cd "<folder>"` → start Claude through a login+interactive shell, by resolved absolute path or `claude`-from-PATH fallback), writes it to a unique temp file, and `chmod +x`s it. The file removes itself before Claude starts (no litter). [Note: even the resolved path runs via the login shell so claude's `env node` shebang finds `node` — see design D2.]
- [x] 2.3 Add the `.claudeProject` branch to `LaunchService.fire(_:inBand:)`: resolve/write off-main, open the `.command` via `NSWorkspace.shared.open` (default handler → no Apple Events / no new permission), and report failures as a non-blocking notification (success needs none — the terminal window is its own feedback).

## 3. Editor — "Claude Project" source (Hub/BandsCanvas)

- [x] 3.1 Add a "Claude Project" immediate-add category to the `SourceCategory`/`SourcePicker` index.
- [x] 3.2 On choosing it, present an `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`), resolve `claude` off-main, and add the item via `ClaudeLauncher.makeItem`. If `claude` can't be found, surface a bounded **inline** banner (never an `NSAlert`).
- [x] 3.3 Add item-panel editing for the kind: show the bound folder and a "Choose…" re-pick (mirroring the `.path` re-pick), re-resolving the `claude` path in the background on change.
- [x] 3.4 Render the kind's icon/tint in the editor grid and the launcher overlay (`kindMarker`) so it appears like any other item.

## 4. Tests (Core, `swift test`)

- [x] 4.1 Codable round-trip for `.claudeProject` (with and without `claudePath`), including decoding a legacy record that strips the `claudePath` key (→ `nil`).
- [x] 4.2 Default title/icon derive from the folder via `makeItem`.
- [x] 4.3 `.command` script content: asserts the `cd` to the folder, the login-shell start of the resolved path (and the `claude`-from-PATH fallback when no path), and the `rm -f "$0"` self-delete; plus `shellQuote` escaping.
- [x] 4.4 `ClaudeLaunchError` cases each produce a clean, non-empty headline with no raw OS text; raw text rides only in `copyableDetails`.

## 6. Configurable command + visible script (follow-up)

- [x] 6.1 Add an optional `command` to `.claudeProject` (`folder:command:claudePath:`), Codable forward-compatible; thread it through `fire`/`launchClaude` and the editor destructures.
- [x] 6.2 Rework `ClaudeLauncher.commandScript` to run, in order: a non-empty custom command as written → the resolved `claudePath` → `claude` from PATH — all through one shell-quoted login-shell `exec`. Skip resolution for a custom command.
- [x] 6.3 Inspector: a Script-style monospaced **Command** editor (default `claude`, normalized so the bare default still uses the resolved binary) plus a read-only **Generated script** disclosure that previews the exact `.command`.
- [x] 6.4 Tests: custom-command script, quote-escaping in a custom command, and a Codable round-trip carrying a command.

## 7. General "Open in Terminal" sibling (keep-both)

- [x] 7.1 New `.terminalCommand(folder:command:)` kind + `TerminalLaunchError`/`TerminalLauncher` (Core, `Launcher/TerminalLaunch.swift`): pure `commandScript` (login-shell run; blank command → interactive shell), `writeCommandFile`, `makeItem`; reuses `ClaudeLauncher.shellQuote`.
- [x] 7.2 `LaunchService.fire` branch → `launchTerminal` (same no-permission `.command` handoff; no resolution/validation).
- [x] 7.3 Editor: "Open in Terminal" immediate-add source (no validation gate) + inspector (folder re-pick, command editor, generated-script disclosure); extended `isConsequential`/`naturalIcon`/`kindLabel`/`kindMarker`.
- [x] 7.4 Tests (`TerminalLaunchTests`): default appearance, command/blank/quote-escaping script, Codable round-trip, error headlines.

## 5. Verification

- [x] 5.1 `swift build` and `swift test` green (891 tests, 0 failures, incl. 16 new across `ClaudeLaunchTests` + `TerminalLaunchTests`).
- [x] 5.2 Compile-verified the app target — `swift build` compiled + linked `ThreeFingerSwitcher` and `GemmaRuntime` (a separate `xcodebuild` is redundant here; all changes are in MLX-free Core).
- [x] 5.3 Synced the change's spec deltas into `openspec/specs/` (created `open-claude-here`, updated `favorites-editor`).
- [ ] 5.4 **(User-run, real build)** `INSTALL=1 ./scripts/build-app.sh`, then author a Claude Project item and confirm a one-tap fire opens the default terminal at the folder running `claude` — agents must not assemble/sign/install the `.app`.
