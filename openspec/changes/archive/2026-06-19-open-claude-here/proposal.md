## Why

The launcher is a developer's trackpad, but there is no fast way to drop into a Claude Code session in a project folder. The existing `.script` kind can't fill the gap: it runs **headless** (`Process` → `/bin/zsh -c`, no TTY, minimal PATH), and `claude` is an interactive TUI that needs a real terminal and the user's full shell PATH. A one-tap, folder-bound "open Claude here" item closes that gap using a terminal handoff that needs **no new permission**.

## What Changes

- **New launch-item kind** — a *Claude Project* item bound to a single folder, chosen once at setup (not mid-gesture). Firing it is plain one-tap, fire-and-forget: it opens the user's **default terminal** at that folder and starts `claude`.
- **No new permission.** The handoff writes a self-deleting, executable temp `.command` file and opens it via the system default handler (`NSWorkspace.open`) — so it honors "whatever terminal is my default" and **avoids the Apple Events / Automation prompt** that scripting Terminal.app would trigger. The app keeps its no-new-permission streak.
- **Robust `claude` resolution.** Resolve the absolute `claude` path at setup when possible and bake it onto the item; otherwise fall back to an interactive-login-shell wrapper so installs behind nvm/fnm/homebrew still work. Surface a clear, bounded setup-time error if `claude` can't be found.
- **New editor source — "Claude Project."** The Hub Bands page gains an immediate-add source: choosing it prompts for a folder (native `NSOpenPanel`) and adds the item (titled with the folder name); the folder is editable afterward in the item panel, like a `.path` item.
- **Configurable command + visible script.** The inspector exposes the command run after `cd` (default `claude`), editable like a `.script` body (e.g. `claude --resume`), and shows the exact generated `.command` script read-only — so the under-the-hood behavior is both visible and configurable while the no-permission terminal wrapper stays managed.
- **General "Open in Terminal" sibling.** Alongside Claude Project, a second immediate-add source/kind (`.terminalCommand`) opens the default terminal at a folder and runs any command (e.g. `npm run dev`; blank = just open a shell there). No binary resolution or validation — the command runs through a login shell so PATH resolves. Shares the same no-permission `.command` handoff and the editable-command + generated-script inspector.
- Errors map at the boundary into a small Core `LocalizedError` taxonomy and surface **bounded and non-blocking** (no `NSAlert`, no raw error text in a headline), per the project convention.

## Capabilities

### New Capabilities
- `open-claude-here`: a folder-bound launch item that opens the user's default terminal at the folder and starts Claude Code, via a no-new-permission temp-`.command` handoff, with robust `claude`-path resolution and bounded error surfacing.

### Modified Capabilities
- `favorites-editor`: add a "Claude Project" source category to the Bands-page source picker — an immediate-add source that prompts for a folder and adds the item, with the folder editable in the item panel.

## Impact

- **Model** — `Sources/ThreeFingerSwitcher/Launcher/LaunchItem.swift`: one new `LaunchItemKind` case carrying the folder `URL` (plus an optional resolved `claude` path), Codable like the existing kinds.
- **Fire** — `Sources/ThreeFingerSwitcher/Launcher/LaunchService.swift`: a new `fire` branch that writes + opens the `.command`, resolves `claude`, and reports success/failure (notification, mirroring `.script`).
- **Editor** — `Sources/ThreeFingerSwitcher/Hub/BandsCanvas.swift`: new source category, folder picker (reusing the existing `choosePath()` pattern), and item-panel editing of the folder.
- **Errors** — a new Core `LocalizedError` taxonomy (parallel to `FileActionError`) for claude-not-found / terminal-open / script-write failures.
- **No new permission, no new dependency.** All MLX-free Core, so it verifies under `swift build` / `swift test`.
