## Why

The three-finger switcher is a *trackpad-flow* way to reach windows; it does nothing for the *mouse-flow* moment when your hand is already on the mouse reaching for the Dock. macOS shows no window previews on Dock hover, so picking among an app's several windows means clicking the icon, watching every window surface, then hunting. Borrowing the same Windows-taskbar inspiration that started this app, hovering a Dock icon should fan out that app's windows **on the current Space**, let you peek the live content of any one, and click to bring it forward.

## What Changes

- **New: Dock-hover window previews (opt-in, default off; `showDockPreviews`).** Hovering a Dock app tile pops a row of that app's window thumbnails — including **minimized** windows — for windows **on the current Space only**. Apps with no windows on the current Space show nothing (no empty popup).
- **New: live peek by fronting the real window.** Hovering a tab brings the **real window to the front** so it shows its true, updating content at its actual position/size; leaving without a click **restores** the previously-front window. (macOS won't render fresh pixels for an off-screen window, so fronting the real window — not an in-popup projection — is the only path to a true live preview; this reverses the original "project, never raise" decision after testing.) Tabs themselves carry best-effort thumbnails with the switcher's last-good-frame safety.
- **New: click-to-commit.** Clicking a tab raises that window permanently (de-minimizing first if it was minimized), via the existing raise path, and skips the restore. A peek otherwise leaves the desktop as it was.
- **New: Dock geometry awareness.** Tile frames, Dock orientation (bottom/left/right), the display the Dock is on, auto-hide reveal, and magnification are read from the Accessibility tree so the popup anchors correctly and follows magnified tiles.
- **No new permission, no gesture relocation, no re-login.** Reuses the already-granted Accessibility (read Dock tiles + raise) and Screen Recording (thumbnails) permissions; it reads on demand like the Files band.
- This is the app's **first cursor-first, mouse-interactive surface** — a deliberate split from the trackpad-gesture, no-keypress identity of every other overlay.

## Capabilities

### New Capabilities
- `dock-hover-detection`: Reads the Dock's Accessibility tree to map tiles → (app pid, screen frame), tracks the cursor, handles Dock orientation / display / auto-hide / magnification, and emits a "hovered app at anchor rect" signal (with enter/leave + dismiss lifecycle). Owns the opt-in toggle.
- `dock-preview-overlay`: The mouse-interactive popup that renders the app's current-Space window row (normal + minimized), peeks the hovered window by fronting the real window (restoring the prior one on leave), and commits the clicked window. Skips apps with no current-Space windows.

### Modified Capabilities
- `window-enumeration-and-raising`: Add an **app-scoped, current-Space enumeration that includes minimized windows** (the switcher's all-Spaces, minimized-excluded enumeration is unchanged), and **un-minimize-then-raise on commit** of a minimized window.

## Impact

- **New code:** `Sources/ThreeFingerSwitcher/Dock/` (the Dock AX reader + cursor watcher), a new mouse-interactive overlay controller + SwiftUI row view under `Overlay/`, and a settings flag in `Settings/AppSettings.swift` surfaced on the Configuration Hub.
- **Reused (no behavior change):** `Windows/ThumbnailService.swift` (cached row + `liveCapture` peek), `Windows/WindowService.swift` (`snapshot()` + `raise()`), `Overlay/OverlayController.swift` (`SwitcherPanel` infra).
- **Permissions:** none added — Accessibility + Screen Recording already required and granted.
- **MLX-free Core:** all new logic stays in `ThreeFingerSwitcherCore` (verifiable under `swift build`/`swift test`); only cursor/Dock-AX glue that touches AppKit lives at the app boundary, mirroring the player/files seams.
