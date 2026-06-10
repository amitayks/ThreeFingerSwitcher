## 1. Synthetic Hub entry (pure, testable)

- [x] 1.1 Add `HubSwitcherEntry` (Core, MLX-free): `make(...)` builds the synthetic Hub `WindowInfo` (id = window number, pid = self, no AX element, no thumbnail, title "<appName> Hub") only when the Hub is visible, with Space placement (copy a co-resident snapshot window's Space-row; else the captured Hub Space; else the current Space). `isHub(selectedID:hubWindowNumber:)` answers the commit decision.
- [x] 1.2 Verify: `swift build` compiles the new file.

## 2. Wire into the coordinator

- [x] 2.1 Capture the Hub's Space (`hubSpaceID`) when `showHub` presents the window (current Space after `present`).
- [x] 2.2 Inject the Hub entry in `gestureDidActivate` after `windowService.snapshot()` (only when `hubWindow?.isVisible == true`); group as usual. Do NOT relax the self-PID filter in `WindowService`.
- [x] 2.3 Commit branch in `gestureDidCommit`: if the selected id is the Hub's window number, `present(hubWindow)` (focus our own window; dismiss Mission Control first if open) and return — never the cross-Space SkyLight raise.
- [x] 2.4 Exclude the Hub id from `prefetchCurrentRow`'s thumbnail seed + prefetch (no self-capture).
- [x] 2.5 Confirm no `setActivationPolicy` / `.canJoinAllSpaces` / `.moveToActiveSpace` is added (accessory mode + on-its-Space behavior preserved).

## 3. Tests

- [x] 3.1 `HubSwitcherEntryTests`: inclusion gate (visible-only), synthetic fields/title/icon, Space placement (co-resident copy / Hub-Space fallback current-vs-not / current-Space fallback), commit decision (`isHub`), and end-to-end grouping into the Hub's Space-row via `SpaceGrouping`.
- [x] 3.2 Verify: `swift test` (all pass) + `xcodebuild` compile-verify (`** BUILD SUCCEEDED **`).

## 4. Spec

- [x] 4.1 Author the `switcher-overlay` delta (ADDED requirements: Hub card while open / only the Hub / icon-only no self-capture / stays on its Space + commit focuses Hub / accessory mode preserved).
- [x] 4.2 After verification, fold the delta into `openspec/specs/switcher-overlay/spec.md` and archive the change.
