## Why

When the app owns the three-finger gesture, the user can open Mission Control (MC) and then trigger the window switcher on top of it. Today the switcher overlay renders **behind** the MC windows (it sits at `.popUpMenu`, deliberately low to avoid perturbing focus/Space arbitration), so it's mostly hidden and unusable, and selecting a window leaves MC open.

## What Changes

- While **Mission Control is open**, the switcher overlay SHALL float **above** it (raised window level + Exposé-exempt), so the cards are fully visible. When MC is not open, the overlay keeps its current arbitration-safe configuration unchanged.
- Selecting a window in the switcher **while MC is open** SHALL dismiss Mission Control and then focus the chosen window via the existing robust raise.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `switcher-overlay`: the overlay gains an "above Mission Control" presentation used only while MC is open, and a commit path that dismisses MC before raising the selected window.

## Impact

- **Code:** `OverlayController` (per-show level/collection-behavior toggle), `AppCoordinator` (track MC-open state; configure the overlay accordingly on activate; dismiss MC before raise on commit), `MissionControl` (a `dismiss()` that closes MC without the open/close toggle ambiguity).
- **Risk:** raising the panel level / adding `.stationary` was previously avoided as it can perturb the WindowServer's focus/Space arbitration — mitigated by applying it **only** while MC is open and re-establishing focus through the robust raise (with the overlay already hidden and MC dismissed) on commit.
- **Permissions:** none added.
- **Scope:** Mission Control only (App Exposé is a separate overview; out of scope for now).
