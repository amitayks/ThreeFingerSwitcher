## Context

Items are fired through `LaunchService.fire(_:inBand:)`, which switches on `LaunchItemKind`. The existing `.script` kind runs **headless** (`Process` → `/bin/zsh -c`, no TTY, minimal PATH). Claude Code (`claude`) is an interactive TUI: it needs a real terminal window *and* the user's full shell PATH, so it cannot run under the script runner.

Decisions from exploration fixed the shape: the folder is **fixed per item** (chosen at setup, not mid-gesture), the feature is **Claude-specific**, and it opens **whatever terminal is the user's default**. Hard constraints from the project: MLX-free Core (`swift build`/`swift test`), **no new permission** (the app's stated ethos), the error→message convention (bounded, non-blocking; no `NSAlert`; no raw error text in headlines), and forward-compatible Codable for the `Favorites` record.

## Goals / Non-Goals

**Goals:**
- One-tap launch of `claude` in a new default-terminal window at a configured folder.
- Zero new permission (no Apple Events / Automation prompt).
- Works regardless of how `claude` was installed (npm-global, native installer, nvm/fnm, homebrew).
- A first-class, persisted, Hub-authored item that moves between bands like any other.
- An **editable command** (default `claude`) configured in the inspector like a `.script` body — supporting flags / setup lines (e.g. `claude --resume`) — with the full generated launch script shown read-only for transparency.

**Non-Goals:**
- A trigger-time folder picker (explicitly rejected — "fixed per item").
- Owning or choosing a specific terminal app, or driving it via AppleScript.
- A general "run any command in a terminal" kind (scope is Claude-specific; the model leaves a seam).
- A *structured* UI for individual `claude` flags / MCP config (you type the raw command line — the wrapper that's managed is the cd + no-permission terminal handoff + self-delete, not the command).
- Confirming that `claude` actually started inside the terminal (that outcome is visible to the user in the terminal itself).

## Decisions

### D1 — Terminal handoff via a temp `.command`, not AppleScript
Write an executable, **self-deleting** temp `.command` file and open it with `NSWorkspace.shared.open`. macOS routes it to the user's **default** `.command` handler (their terminal), and this needs **no Apple Events / Automation permission**.
- *Why not AppleScript `do script`?* More controllable, but adds a one-time "control Terminal" permission prompt and is Terminal.app/iTerm-specific — both violate the chosen "default terminal, no new permission" path.
- *Why not `open -a Terminal <folder>`?* Opens a terminal at the folder but cannot inject the `claude` command.
- The script self-deletes with `rm -f "$0"` *before* starting `claude` (the shell has already read the file), so nothing is left on disk.

```zsh
#!/bin/zsh
rm -f "$0"
cd "<folder>" || exit 1
exec "<resolved-claude-or-fallback>"
```

### D2 — Claude resolution: bake absolute path at setup, run it through a login shell
At setup, resolve `claude` via a login+interactive shell (`zsh -lic 'command -v claude'`), and if found **store the absolute path** on the item (which also lets the Hub validate immediately, and as a backstop probes well-known install dirs). At launch, **both** paths start Claude through a login+interactive shell (`zsh -lic`): when a path is stored it is `exec`'d by absolute path (passed as `$1`), otherwise `claude` is taken from PATH.
- *Why route the resolved path through a shell too (not `exec <path>` directly)?* Claude's own launcher is `#!/usr/bin/env node`, so it needs `node` on PATH — a bare `#!/bin/zsh` script doesn't have it, and an npm-installed `claude` would fail. The login shell supplies `node`'s PATH; passing the resolved path as `$1` still runs the exact validated binary (and works even if `claude` itself isn't on PATH).
- *Why login **and** interactive (`-lic`)?* `-l` sources `.zprofile`/`.zlogin` (homebrew), `-i` sources `.zshrc` (nvm/fnm); together they cover the common install layouts.
- *Why bake the path at all if we still use a shell?* It validates at setup (don't add a non-working item) and runs the exact binary; the no-path fallback re-resolves `claude` from PATH at launch, covering a stale stored path.

### D3 — Folder at setup; trigger is fire-and-forget
Mirrors `.path`: the folder URL is captured when the item is authored; firing performs the handoff with no modal. This reverses the original "prompt at trigger" sketch, per the "fixed per item" choice.

### D4 — Model: a dedicated kind carrying the folder + optional resolved path
Add `case claudeProject(folder: URL, claudePath: String? = nil)` to `LaunchItemKind`. `claudePath` is **Optional** so the synthesized decoder uses `decodeIfPresent` and any record written before it existed still decodes (the `.url`/`.action` precedent).
- *Why not extend `.script`?* A hand-authored body is exactly the fragility a first-class kind removes (clean editor, folder picker, setup-time validation, a real icon/title).
- *Why not a general `.terminal(command:dir:)`?* Out of scope (Claude-specific), but this is the natural future generalization — the resolved-path/command seam is left deliberately narrow, not closed.

### D5 — Editor: immediate-add "Claude Project" source
Add a source category that, like **Files & Folders**, immediately prompts for a folder (`NSOpenPanel`, `canChooseDirectories = true`, `canChooseFiles = false`) and adds the item titled with the folder's last path component; the folder is editable afterward in the item panel. Reuses the existing `choosePath()` pattern in `BandsCanvas`.

### D6 — Errors: a dedicated Core taxonomy, surfaced bounded + non-blocking
A new Core `LocalizedError` (parallel to `FileActionError`), e.g. `ClaudeLaunchError { claudeNotFound, terminalOpenFailed, scriptWriteFailed }`. Setup-time `claudeNotFound` surfaces **inline** in the Hub item panel; runtime `terminalOpenFailed`/`scriptWriteFailed` surface as a **non-blocking notification** (mirroring `.script`). Never an `NSAlert`; never raw OS error text in a headline.

### D7 — Editable command + read-only generated-script preview
The model carries an optional `command` (nil/empty ⇒ default bare `claude`); the inspector edits it in a monospaced editor like a `.script` body and shows the full generated `.command` read-only. The command builder runs a non-empty command **as written** through the login shell, and the default through the resolved `claudePath`. The friendly placeholder `claude` is normalized to nil on storage so the default path still uses the resolved binary.
- *Why expose the command but keep the wrapper managed?* The value of this kind over `.script` is the no-permission terminal handoff (cd + default-terminal `.command` + self-delete + node-on-PATH login shell). So the *command* is editable (what varies), while the wrapper is generated and merely shown — editing the folder is via the picker, not raw text, which is safer.
- *Why a read-only preview rather than a fully-editable script body?* A fully-editable body would desync from the structured `folder`/`command` fields and re-create `.script`; the preview gives full transparency without that ambiguity.

## Risks / Trade-offs

- **`claude` not on PATH inside the spawned terminal** → bake the absolute path at setup; interactive-shell fallback; clean setup-time validation error. (The single biggest correctness risk of the no-permission route.)
- **User's default `.command` handler isn't a terminal** (rare, user remapped it) → document; the handoff still "succeeds" from the app's view. A future explicit terminal-picker could remove the ambiguity.
- **Baked absolute path goes stale** (uninstall/move) → the interactive-shell fallback re-resolves; `claude` updates in place, so low risk.
- **Temp `.command` litter / concurrent-launch race** → a unique temp file per launch that self-deletes (`rm -f "$0"`).
- **No knowledge of in-terminal success** → acceptable; a missing `claude` is visible in the terminal; the app reports only the handoff result.
- **Window stays open after `claude` exits** ("[Process completed]") → acceptable v1 default; not configured.

## Migration Plan

Purely additive: a new enum case, a new `fire` branch, a new editor source, and new optional fields that decode on existing records. No data migration. **Forward note:** once shipped and authored, the enum case must remain decodable — removing it would break decode of saved `Favorites`, so treat the kind as additive-only after release.

## Open Questions

- Offer "keep terminal open vs close on exit"? (v1 leaves it open.)
- Re-validate the baked `claude` path on every edit, or only at add time?
