# Tasks: window-groups

## 1. Pure foundations (adjacency + store)

- [x] 1.1 `Windows/SnapAdjacency.swift`: pure edge-adjacency test (`adjacent(a:b:)` over CGRects, ε default 12pt, `minSharedExtent` default 60pt, all four orientations, corner-touch excluded by the shared-extent gate)
- [x] 1.2 `SnapAdjacencyTests`: flush edges, margin-gap edges, gap beyond ε, corner touch, shared extent below minimum, vertical (top/bottom) adjacency
- [x] 1.3 `Windows/WindowGroupStore.swift`: pure group store — `dragSettled(window:adjacent:)` (leave-if-detached + merge-with-contacts, dissolve <2), `group(for:)`, `validatedGroups(against:)` (drop absent/minimized/off-Space members; dissolve <2), `clear()`
- [x] 1.4 `WindowGroupStoreTests`: bind, transitive merge, drag-apart removal, rebind onto a new contact, dissolve below two, validation drops closed/minimized/off-Space members, clear

## 2. Snap detection (monitor)

- [x] 2.1 `Dock/GlobalCursorMonitor.swift`: add passive `onLeftDown`/`onLeftUp` callbacks (global+local, never consumed — the right-click pattern)
- [x] 2.2 `Windows/WindowSnapMonitor.swift`: on left-down record the window under the cursor (CGWindowList point hit-test, layer 0, own app excluded) with its frame; on left-up, if that window's frame changed, schedule the cancellable ~0.25s settle read; on settle, scan current on-screen windows for adjacency and call `WindowGroupStore.dragSettled`
- [x] 2.3 Gate the monitor on the opt-in: `setEnabled(_:)` installs/removes the cursor monitor; disabled clears the store

## 3. Layout units (fused clusters)

- [x] 3.1 `SwitcherLayout`: introduce layout units (singleton window / cluster with member indices + natural member offsets + union natural size); unit-aware `solveGrid` (wrap, balance, height solve, and width-fit operate on unit sizes; min-height floor for singletons only); derived expanded `rows` (cluster members consecutive, ordered by (minX, minY)) and per-window `sizes`; keep the old signature building singleton units
- [x] 3.2 `SwitcherGridLayout`: carry the unit rows (+ per-member scaled offsets) for rendering and make the positional-navigation interval helpers unit-aware (unit x + member offset instead of uniform spacing)
- [x] 3.3 Layout tests: no-groups path solves byte-identical to before; a 2-window cluster wraps as one unit with correct member offsets/sizes; cluster flow position = earliest member; expanded row order; interval math over a row containing a cluster
- [x] 3.4 `SwitcherModel.setRows(..., groups:)`: map validated group ids to per-Space indices, build units, keep all published state semantics; model tests for navigation through cluster members (horizontal walk, positional vertical landing onto a member)

## 4. Rendering

- [x] 4.1 `SwitcherView`: render a cluster unit as a fixed-size `ZStack(alignment: .topLeading)` of the SAME card views at their scaled offsets; singleton rendering, highlight, thumbnails, minimized badge untouched

## 5. Commit (group raise)

- [x] 5.1 `WindowService.raiseGroup(mates:selected:)`: front each mate via the peek-style light path (SkyLight handshake + AX raise + kAXMain, no promotion, no watchdog, Stage-Manager fallback), then hardened `raise(selected)` last
- [x] 5.2 `AppCoordinator.raiseCommitted`: when the committed window is in a validated group, collect mate `WindowInfo`s from the current snapshot rows and call `raiseGroup`; otherwise unchanged (both drivers inherit)

## 6. Wiring + setting

- [x] 6.1 `AppSettings.enableWindowGroups` (default false, `showDockPreviews` pattern: persisted, not reset by tunables-reset)
- [x] 6.2 `AppCoordinator`: own the `WindowSnapMonitor` + `WindowGroupStore`; react to the setting (enable/disable + clear); pass `validatedGroups(against: snapshot)` into `overlay.show`/`setRows`
- [x] 6.3 Hub toggle for the setting (next to the Dock-previews / minimized-windows switcher options)

## 7. Verify

- [x] 7.1 `swift build` + full `swift test` green (existing layout/model tests unmodified and passing — the no-groups regression gate)
- [x] 7.2 Re-read both delta specs against the implementation; fix drift (spec or code) before archiving
