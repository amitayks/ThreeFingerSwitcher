# Project Workspaces (Window/Space Time-Machine) — design exploration

> Status: **explore seed.** No proposal/specs/tasks yet. Promote to `openspec/changes/` when ready.

## Context

Two muscles only this app has: **cross-Space window control** (enumerate + raise across Spaces via the private CGS/SkyLight gauntlet — `WindowService`, `SpaceWindowMover`, `Spaces`) and **focus history** (`FocusLog` ring buffer + `MRUTracker`). The launcher already has **presets** (`LaunchItemKind.preset` — fire an ordered set of items) and can **set window frames via AX** (`LaunchService.setAXFrame`, used today for tiling). And it already has a "capture the front thing" gesture (menu → *Add front app → band*).

"Recall what I copied" and "recall where I was" are the same genre — different streams. This idea is the *place* stream: a **Workspace** = a named, saved set of **windows-per-app with their working context, layout, and target Space**, that opens with one dwell and tears down with another.

The user's scenario: a project uses **Xcode + VS Code (at the project root) + Android Studio + Claude Code in a terminal (at the root) + whatever else**. You configure which windows the group contains and how they're arranged — captured the same way you add a front app to a band. One dwell on the group item **opens them all**, on a chosen (already-existing) Space, **restored to where you left off**. A sibling **"Close group"** item tears the set down at end of day.

## Goals / Non-Goals

**Goals:**
- A **Workspace** launcher item: a named bundle of `{app, working context (dir/document), desired window frame, target Space}` entries.
- **Capture from the live desktop**: "add the front window to workspace W" snapshots the app + its working dir/document + frame + which Space it's on — the muscle-memory twin of "add front app to band."
- **One-dwell open**: launch/raise each member, point it at its working context, place it at its frame, on the target Space — restored to "where we left off" as faithfully as macOS allows.
- **One-dwell close**: gracefully quit/hide the workspace's windows (optionally save first) — "I'm done for today."
- Reuse the existing preset/launch/AX-frame/Space-raise plumbing; a Workspace is a richer preset.

**Non-Goals:**
- **Creating Spaces programmatically** — macOS has no public API for it (the user already knows this). Workspaces target an **existing** Space (the current one, or a user-pinned Space slot), not a freshly-minted one.
- Pixel-perfect app-internal state (scroll position, cursor, unsaved buffers) — out of reach; we restore *which document/dir + window geometry + Space*, and let each app restore its own internals.
- A full session manager for every app on the system — this is **per-project, user-curated** bundles.

## Decisions (proposed)

### Model: a Workspace is a preset that restores context, not just fires items
Extend the launch-items model with a `workspace` (or enrich `preset`): an ordered list of **window specs**:
```
WindowSpec {
  app:        bundleURL
  context:    .directory(URL) | .document(URL) | .none   // the "project root" / open file
  frame:      CGRect?            // desired window position+size (AX)
  space:      .current | .pinned(index) | .none
  launchArgs/opener: how to point the app at `context`  // see adapters
}
Workspace { name, icon, tint, members: [WindowSpec], closeBehavior }
```

### Capture from the current desktop (the killer authoring UX)
"Add front window to workspace W" reads, for the focused window: the owning app (`NSRunningApplication`), the window **frame** (AX), the **Space** it's on (`Spaces`/CGS), and a best-effort **working context** — the app's open document (AX `AXDocument`) or, for dev tools, the project root (e.g. Xcode's open workspace, VS Code's folder, the terminal's `cwd`). This mirrors the existing favorites quick-add, so it's familiar and keyboardless.

### Open = launch/raise + point-at-context + place + Space, reusing existing paths
- **Launch/raise** each member via `LaunchService` (respecting an `AppStrategy`: new window vs. focus existing).
- **Point at context** via per-app **opener adapters**: `code <dir>`, `xed <dir-or-workspace>` (Xcode), Android Studio's `studio <dir>`, Terminal/iTerm `cd <dir>` (or `open -a Terminal <dir>`), generic `open <document>`. Falls back to a plain launch when no adapter fits.
- **Place** each window at its saved `frame` via `setAXFrame` (the tiling code already does this).
- **Space**: place on `.current`, or move to a `.pinned` Space slot via the `SpaceWindowMover` muscle (with its known off-Space limits). No Space is created.

### "Where we left off" = context + geometry + Space, plus the time-machine layer
Two flavors, both useful:
- **Configured workspace** (deterministic): the user-defined `members` — always opens the same way. This is the project-launcher.
- **Snapshot / time-machine** (ambient): periodically (or on demand) snapshot the *current* live arrangement (windows, contexts, frames, Spaces) into a restorable point, sourced from `WindowService` + `FocusLog` + `MRUTracker` — "reopen how my desktop looked 20 minutes ago / before I closed those." The configured workspace can be *seeded* from a snapshot.

### Close group
A `closeGroup` action over a workspace's members: graceful `terminate()` (lets apps prompt to save) or `hide()`, optionally preceded by a "save?" preview. Reuses the app-control actions we already have (quit/hide front app) generalized to a set.

## Risks / Trade-offs

- **No programmatic Space creation** (hard constraint) — workspaces bind to existing Spaces; "open in its own Space" means "the Space you parked it on." Document this loudly; consider a one-time guided "make N Spaces and pin them" setup.
- **App context adapters are per-app and brittle** — Xcode/VS Code/Android Studio/Terminal each need a known opener; unknown apps degrade to plain launch. Ship a small adapter registry, user-extensible (a custom open command per app, like the script items).
- **Window identity across launches** — matching a saved spec to a freshly-opened window (to set its frame) needs polling/AX heuristics (owner pid + title/doc). The launcher already waits-and-raises after new-window; extend that.
- **Frame restore fights the app's own state restoration** — apps may reposition after we place them; re-assert the frame after a short delay (the tiling code already re-asserts position post-resize).
- **Quitting apps on "close group" risks unsaved work** — graceful terminate + an optional confirm; never force-quit by default.
- **Cross-Space move limits** — `SpaceWindowMover` can't always relocate foreign windows (verified on-device); fall back to "go to it" or open on the current Space.

## Open Questions

- **Workspace vs. enriched preset** — new kind, or extend `preset` with per-item context/frame/Space?
- **How much "where we left off"** is realistic per app — just the open dir/doc, or can we capture more (e.g. Xcode's open files via its state)? Where's the cutoff?
- **Snapshot cadence** for the time-machine layer — manual only, periodic, or on focus-change (we already log focus)? Storage/retention like the clipboard store?
- **Pinned-Space UX** — how does the user designate "Space slot 2 is my "Project A" Space" without programmatic Space control?
- **Editing a workspace** — the favorites "small IDE" extended to show/capture/reorder window specs and per-app openers.
- **Tie-in with the AI band** — "open Claude Code with this idea" and "save to project N" reference *projects*; a Workspace is the natural home for a project's identity (root dir, notes, apps).
