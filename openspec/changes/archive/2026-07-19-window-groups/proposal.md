# Proposal: window-groups

## Why

macOS (Sequoia+) magnetically snaps a dragged window flush against another window's edge — but the OS remembers nothing about it: the two windows the user deliberately arranged side by side are strangers to every switcher. Raising one buries the other, and re-surfacing the pair means two separate switches. Windows 11 solved this with Snap Groups (snapped windows appear as a group in Alt-Tab). This change brings that to the switcher: windows that were snapped together become a **group** — rendered *snapped together* in the switcher grid so the pairing is visible, individually highlightable, and raised **as a unit** on commit with the selected member focused.

## What Changes

- **Snap-to-bind detection**: the moment a window drag (or resize) ends with the window's edge flush against another current-Space window (tolerating both a zero gap and the "tiled windows have margins" gap; requiring a minimum shared extent along the touching edge — a corner touch never binds), the two windows are bound into a group. Binding merges groups (A+B then B+C yields one group of three). Detection is a passive global left-mouse down/up monitor (the `GlobalCursorMonitor` precedent) plus a frame-diff adjacency scan — **no new permission**.
- **Physical-attachment lifecycle**: a group means "these windows are attached." Dragging a member away from all of its group-mates removes it; closing, minimizing, or moving a member to another Space removes it too (validated lazily against live window state). A group below two members dissolves. Nothing persists across app restarts (runtime-only, keyed by `CGWindowID`).
- **Snapped presentation in the switcher grid**: a group renders as a **fused cluster** — its member cards placed at their real relative arrangement (same shared uniform scale, adjacent edges nearly touching), so users *see* the windows are grouped — while the moving highlight and selection stay **individual** (each member card is its own selectable item). The flow-wrap treats the cluster as one unit.
- **Group commit**: committing a grouped window (trackpad lift or ⌘-Tab release — the shared `raiseCommitted` path) raises **every** group member, front-most z-order, with the **selected** member receiving focus (mates raised via a light no-watchdog variant first, the selected member last through the existing hardened raise).
- **Opt-in, default off** (`enableWindowGroups`): no monitors installed when off, no gesture relocation, no re-login, no new permission (reuses granted Accessibility).

## Capabilities

### New Capabilities

- `window-groups`: snap-to-bind detection, the group store and its physical-attachment lifecycle, and the group commit (raise-all-focus-selected).

### Modified Capabilities

- `switcher-overlay`: the grid-rendering requirement changes to lay out grouped windows as a fused cluster (one flow-wrap unit, members at real relative offsets) while per-member highlight/selection and navigation stay individual.

## Impact

- **Code** (all MLX-free Core; verified by `swift build` / `swift test`):
  - New `Sources/ThreeFingerSwitcher/Windows/WindowGroupStore.swift` — pure group store (bind/merge/remove/validate; unit-tested).
  - New `Sources/ThreeFingerSwitcher/Windows/SnapAdjacency.swift` — pure edge-adjacency math (ε + minimum shared extent; unit-tested).
  - New `Sources/ThreeFingerSwitcher/Windows/WindowSnapMonitor.swift` — the drag-end detector: left-mouse down/up monitors, before/after frame diff (CGWindowList), adjacency scan, store updates.
  - `Dock/GlobalCursorMonitor.swift` — gains passive left-mouse down/up callbacks (same pattern as the existing right-click monitor).
  - `Overlay/SwitcherLayout.swift` + `SwitcherModel.swift` — the solve gains layout *units* (singleton window or cluster with member offsets); positional-navigation intervals become unit-aware.
  - `Overlay/SwitcherView.swift` — renders a cluster as a fixed-size container with member cards at scaled offsets; per-member highlight unchanged.
  - `App/AppCoordinator.swift` — `raiseCommitted` raises the whole group (selected focused); wires the monitor + setting.
  - `Windows/WindowService.swift` — a light mate-raise variant (no watchdog, no focus promotion) + a group-raise sequence.
  - `Settings/AppSettings.swift` + Hub — the `enableWindowGroups` opt-in toggle (default off, like `showDockPreviews`).
- **No new permissions** (passive monitors need none; frames come from CGWindowList/AX already in use). No persistence. Dock previews and the Files/launcher surfaces are untouched.
- **Specs**: new `window-groups` capability spec; delta on `switcher-overlay`.
