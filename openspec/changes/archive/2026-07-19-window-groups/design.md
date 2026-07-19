# Design: window-groups

## Context

macOS Sequoia's window-to-window magnetic snap leaves no queryable trace: there is no "window snapped" notification and no OS group object. What we CAN observe, with machinery this codebase already trusts, is the *end of a window drag* (passive global mouse monitors — the `GlobalCursorMonitor` pattern, no new permission) and *window frames* (CGWindowList/AX, already in use everywhere). "Snapped together" is therefore **inferred**: a drag ended with two windows' edges flush (within a tolerance that covers both zero-gap and the "tiled windows have margins" setting).

Downstream, the switcher already has everything a group needs to be *presented* and *committed*: a uniform-scale grid solve whose cards are real-proportion rectangles (`SwitcherLayout`), per-window selection/highlight (`SwitcherModel.selectedIndex`), the positional-navigation geometry from `switcher-positional-vertical-nav`, and one shared commit point (`AppCoordinator.raiseCommitted`, used by trackpad and ⌘-Tab alike) on top of `WindowService`'s hardened raise and the `peekRaise` front-without-commit mechanics.

## Goals / Non-Goals

**Goals:**
- Bind on snap, dissolve on detach — the group's meaning is *physical attachment*, never stale invisible state.
- The switcher *shows* the group (fused cluster mirroring the real arrangement) while selection stays per-window.
- Commit raises the whole group; the selected member ends focused. Trackpad and ⌘-Tab inherit it identically.
- Opt-in (`enableWindowGroups`, default off), no new permission, no re-login, runtime-only state.

**Non-Goals:**
- No persistence across app restarts (CGWindowIDs are session-scoped; a restored group could bind the wrong windows).
- No at-snap-time HUD/feedback chip in v1 — the fused cluster in the switcher is the visibility mechanism (a transient "linked" chip is deferred; if added later it must respect the idle-CPU-spin rule).
- No group affordances in the Dock previews, Files band, launcher, or ⌘-Tab *ordering* (the flat reel order is untouched).
- No repositioning windows on commit — raise only, never move/resize.
- Vertical navigation *within* a vertically-stacked cluster is not special-cased: cluster members are consecutive items in their visual row (ordered by real position), so horizontal scrub walks through them; vertical scrub keeps operating on visual rows. (Positional landing still targets individual members from adjacent rows.)

## Decisions

### D1 — Detection is drag-end frame-diff + adjacency scan, not AX observers
On **left-mouse-down**: one CGWindowList hit-test records the window under the cursor (id, frame) — cheap, once per click, and it works for *background* window drags (which a frontmost-app AXObserver would miss). On **left-mouse-up**: re-query that window's frame; if it changed (moved OR resized — macOS snaps both), run the adjacency scan **after a short settle delay** (~0.25s, cancellable): the magnetic snap *animates* the window into its final frame after release, so an immediate read can catch the mid-flight frame. `WindowSnapMonitor` owns its own `GlobalCursorMonitor` instance (gated by the opt-in, like `DockPreviewController.setEnabled`); `GlobalCursorMonitor` gains passive `onLeftDown`/`onLeftUp` callbacks in the exact pattern of its right-click pair (never consumed).

### D2 — Adjacency is pure math with two tunable constants
`SnapAdjacency.adjacent(a:b:)`: edges are adjacent when the facing-edge gap ≤ ε (default 12pt — covers flush 0 and the ~8–10pt tiled-margins gap) AND the shared extent along the touching edge ≥ `minSharedExtent` (default 60pt) — which also excludes corner-touch by construction. All four orientations (left/right/top/bottom). Pure `CGRect` math in one coordinate space (CG top-left global; the monitor never mixes spaces), fully unit-tested. The constants are internal (feel-only, like layout metrics) — not user settings.

### D3 — Intent-driven binding: only the dragged window binds
On a settled drag-end of window W: (1) if W belongs to a group and **no member of that group** is still adjacent to W, W leaves it (a group falling below two members dissolves); (2) for every window X now adjacent to W, merge W's group (or W alone) with X's group (or X alone) — union-find style, so A+B then B+C yields {A,B,C}. Two windows that merely *happen* to sit adjacent never auto-bind — a bind requires the user's drag ending on the contact. `WindowGroupStore` is a pure, unit-testable `[Set<CGWindowID>]` service in `Windows/` (the `MRUTracker` shape).

### D4 — Lifecycle is validated lazily, not observed
Closing, minimizing, or moving a member to another Space removes it — enforced by `validate(against:)` at the store's **consumption points** (switcher snapshot assembly and commit) rather than by extra AX observers: a member is kept only if the live snapshot shows it present, non-minimized, and on the same Space as its group-mates; shrunken groups dissolve. Lazy validation can't leak stale raises (commit validates) and can't render a dead cluster (snapshot validates); between consumptions, stale entries are inert ids in a set.

### D5 — Layout: the solve gains *units*; everything else derives
`SwitcherLayout.solveGrid` gains a unit-aware form. A **unit** is one window (today's card, min-height floor intact) or a **cluster**: members' union rect (from their real AX frames) is the unit's natural size, and each member's natural offset within the union is preserved. The uniform-scale solve, flow-wrap, balancing, and bottom-to-top stacking all operate on unit sizes unchanged; a cluster's members render at `k × frame` inside the `k × union` container at `k × offset` — so the on-screen cluster IS the real arrangement scaled, tiny snap gap included ("fused" without any new spacing constant). Cluster members are exempt from the per-card min-height floor (flooring one member would break the mirrored adjacency); the readability floor applies to the unit. `SwitcherGridLayout` keeps `rows: [[Int]]` (expanded per-window, cluster members consecutive in (minX, minY) order) and `sizes: [CGSize]` so selection, thumbnails, tests, and the ⌘-Tab flat order keep working; it adds the unit rows for rendering and interval math. A unit's flow position is its earliest member's snapshot position. The positional-navigation helpers become unit-aware (intervals from unit x + member offset instead of uniform inter-card spacing).

### D6 — Groups enter the model at `setRows`
The coordinator resolves validated groups at snapshot time and passes them into `SwitcherModel.setRows(..., groups:)`; the model maps ids → per-Space indices and builds the layout units. The model stays pure/synchronous (no store dependency); `SwitcherView` renders a cluster as a fixed-size `ZStack(alignment: .topLeading)` of the *same* card views at scaled offsets — per-member highlight, thumbnails, and the minimized badge are untouched by construction.

### D7 — Commit: mates fronted lightly, selected raised hardened, always last
`WindowService.raiseGroup(mates:selected:)`: each mate is fronted with the front-without-commit mechanics `peekRaise` established — SkyLight `setFront` handshake + AX raise + `kAXMain`, **no** focus-history promotion, **no** watchdog, and the documented Stage-Manager fallback (skip the handshake; plain raise + activate) — then the **selected** member goes through the existing hardened `raise` (promotion + watchdog), last, so final focus and topmost z-order land on it. Group members are same-Space by construction (adjacency implies it; Space-move dissolves), so no cross-Space machinery is involved. `AppCoordinator.raiseCommitted` branches: selected in a validated group → `raiseGroup`; otherwise exactly today's paths. Both drivers inherit it (single commit point).

### D8 — Opt-in setting, Dock-preview precedent
`AppSettings.enableWindowGroups` (default **false**, like `showDockPreviews`): when off, no monitors are installed, snapshots pass no groups, and commit is byte-for-byte today's behavior. Toggling off dissolves nothing silently — it simply stops consuming the store (and stops the monitor); toggling clears the store to avoid resurrecting stale groups.

## Risks / Trade-offs

- [The snap settles after mouse-up; an immediate read binds/misses wrongly] → the 0.25s cancellable settle delay before the adjacency scan (mirrors the Dock-preview `captureDelay` idiom).
- [Accidental binds: any drag ending flush counts, even without "snap intent"] → accepted per the feature definition (the snap IS the gesture); the ε + min-shared-extent gates filter glancing contact, and dragging apart unbinds symmetrically, so a wrong bind is one drag from gone.
- [A dragged window's CGWindowList frame vs members' AX `realFrame` disagree by a hairline] → detection and rendering never mix: adjacency uses CG frames on both sides; cluster geometry uses AX real frames on both sides.
- [Mate fronting under Stage Manager oscillates the stage arbiter] → D7 inherits `peekRaise`'s documented fallback (no SkyLight under Stage Manager).
- [Clusters change wrap results and could surprise layout tests] → the no-groups path builds singleton units producing byte-identical layouts; all existing tests must pass unmodified (this is the regression gate).
- [A very wide cluster exceeds the canvas width] → the solve's width-fit bound already keys off the widest *unit* natural size, so the scale shrinks to fit it (same behavior as one very wide window).
- [Left-mouse monitors fire for every click system-wide] → the down-handler does a single CGWindowList point query and stores two values; the up-handler does nothing unless the recorded window's frame changed. Idle cost is negligible, and the monitor only exists while the opt-in is on.

## Migration Plan

Pure additive runtime feature behind a default-off setting; no data migration. Rollback = toggle off (or revert). Ship in the next stable-signed rebuild.

## Open Questions

None blocking. (Deferred, noted above: at-snap feedback chip; vertical navigation *within* a stacked cluster; group affordances in the Dock preview popup.)
