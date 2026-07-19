# Refine window filtering: real windows in, phantom frames out

## Why

The relaxed window gate (`includeNonStandardWindows`) filters by a single scalar — both dimensions of the AX frame must clear 100pt — calibrated once against the Android emulator's side-toolbar. That one number is asked to do two contradictory jobs and fails both in the field:

- **A real window is dropped.** The Finder copy-progress window (a titled, close-buttoned window shorter than 100pt) never appears in the switcher. Worse, the relaxed gate *replaces* the subrole check instead of adding to it, so a standard-subrole window under 100pt is dropped in relaxed mode even though strict mode would list it — turning the "include more windows" opt-in into a filter that *removes* windows.
- **Phantom duplicates flood in.** The AirDrop send popup exposes four identical Finder-owned window objects per actual window; all clear 100pt, so the switcher shows four identical cards.

No value of the scalar fixes both: lower it and more duplicates come in, raise it and more real windows drop. Size is a proxy for identity, and a bad one. The guiding model (user's call): like Windows' Alt-Tab, **every real window gets listed; only phantom/empty frames macOS conjures get dropped** — and when the heuristics are wrong for an app, the user can see why and override per app.

## What Changes

- **A pure `WindowFilter` in Core** replaces the inline `isSwitchable` role/subrole/size checks: it takes a `WindowCandidate` (role, subrole, title, AX size, has-close-button, minimized) plus a `WindowFilterPolicy` and returns a verdict with a drop *reason*. Strict mode's verdicts are unchanged. Pure and unit-tested.
- **Relaxed mode becomes three-tier** (subrole allowlist + real-window discriminators):
  - *Known-real* subroles (standard window, dialog, system dialog) are always listed — relaxation can now only ever ADD windows over strict, never drop one (fixes the Finder progress window).
  - *Known-junk* subroles (floating / system-floating palettes) are always dropped.
  - *Unknown/missing* subroles are listed when the window looks real — non-empty title OR window chrome (a close button) OR the legacy ≥100pt size — and dropped as phantom otherwise (the emulator toolbar: untitled, chromeless, 61pt — still dropped).
  - A degenerate floor (min side < 40pt) drops zero/sliver frames in relaxed mode regardless.
- **Geometry dedup:** same app + same normalized title + same integral AX frame + same minimized state ⇒ one card, keeping the frontmost (lowest z; stable-id order where z is unavailable). Kills the 4× AirDrop duplicates in every enumeration (switcher snapshot, legacy snapshot, Dock preview).
- **Per-app rules:** a persisted `[appKey: rule]` dictionary (key = bundle ID, falling back to executable name) with rules `include` (list every window-role element of the app; skips junk heuristics AND dedup), `strict` (standard subrole only regardless of the global toggle), `exclude` (list nothing from this app). Default: follow the global policy.
- **A Window Inspector on the Hub Switcher page:** an on-demand (button/appear-refreshed, never polling — the idle-CPU landmine) snapshot of every current-Space window candidate per app, showing title, size, subrole, and the verdict (Listed / drop reason / deduplicated), with a per-app rule picker inline. Converts "why isn't my window there?" from a diagnostic-file exercise into a visible, user-controllable surface.

## Capabilities

### Modified Capabilities

- `window-enumeration-and-raising`: new requirement for the switchability filter — three-tier relaxed gate, monotonic-over-strict guarantee, phantom-duplicate dedup, per-app rules.
- `tunable-settings`: new requirement — persisted per-app window-listing rules; reset-to-defaults clears them.
- `configuration-hub`: new requirement — the Window Inspector section on the Switcher page.

## Impact

- **Code:** new `Windows/WindowFilter.swift` (pure filter + dedup + rule types); `Windows/WindowService.swift` (`isSwitchable`/`isPreviewable` route through the filter; dedup in `snapshot()`, `legacySnapshot()`, `currentSpaceWindows(forApp:)`; `inspectorSnapshot()`); `Settings/AppSettings.swift` (`windowAppRules` persisted); `Hub/HubView.swift` (+`inspectWindows` provider), `App/AppCoordinator.swift` (wire it), `Hub/HubFeaturePages.swift` (inspector section); tests.
- **Behavior:** strict-mode users see identical listings except phantom duplicates disappear. Relaxed-mode users gain small real windows (progress windows) and lose junk. `minimizeAllWindows` inherits the gate unchanged (an excluded app is invisible to the feature, so it is not minimized — consistent, never strands a window).
- All MLX-free Core — verified under `swift build` / `swift test`. No new permission, no gesture relocation, no re-login. Live verification of the AirDrop/Finder cases needs the user's signed build.
