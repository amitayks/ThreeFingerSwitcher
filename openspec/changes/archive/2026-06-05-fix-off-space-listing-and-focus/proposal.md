## Why

Two off-Space defects remain under Stage Manager (macOS 26 Tahoe, the project's target environment), and both come from the cross-Space code leaning on Accessibility in ways an off-Space Chromium window won't support. **Bug A — listing & raising over-trust Accessibility:** a Chromium window on another Space exposes no AX element reachable by remote-token brute force, so it both vanishes from the switcher *and* (once listed) can't be navigated to, because the Space switch is driven by `kAXRaiseAction` on an element it doesn't expose. **Bug B — off-Space focus is stolen:** committing to a window on another Space switches Spaces, but WindowManager (the Stage Manager daemon) grabs frontmost ~300 ms later, leaving the app with no key window — focus lands then is ripped away. The working tree is also currently **regressed** (focus singletons skipped on the off-Space path), which loses focus for *every* off-Space window.

## What Changes

- **Un-regress the off-Space path.** Restore `stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled` so the off-Space path writes the per-app focus singletons again (current-Space keeps skipping them — the archived oscillation fix).
- **Bug A — list off-Space windows without requiring an AX element.** Stop dropping an off-Space window just because remote-token brute force found no `AXUIElement`. For the no-element case, decide switchability from a CoreGraphicsServices metadata heuristic — `alpha > 0 && min(width, height) ≥ 130` — which admits real Chromium windows while rejecting the sliver/toolbar/zero-alpha junk that `options=7` surfaces.
- **Bug A — raise (navigate to) a no-AX off-Space window.** Listing isn't enough: with no AX element there's no `kAXRaiseAction` to switch Spaces, and a direct Space switch is impossible (the WindowServer gates it to Dock.app). Adopt the AltTab/HyperSwitch strategy — a **persistent element cache** keyed by CGWindowID, seeded when an app activates or is snapshotted; a cached element stays valid across Spaces, so `kAXRaise` on it navigates to the window. (A window off-Space since before launch and never focused remains unreachable — the documented AltTab limit.)
- **Bug B — hold off-Space focus against WindowManager's steal.** A **bounded polling hold-guard** (off-Space + Stage Manager only) polls every ~60 ms and re-fronts the target the instant WindowManager grabs frontmost (≈ one-frame flash), covering the occasional late re-steal, capped to avoid thrash. (Investigation ruled out the initial "co-staging singleton war" hypothesis — the steal hits every off-Space raise, lone or co-staged.)
- **Remove the dead direct-Space-switch attempt.** `CGSManagedDisplaySetCurrentSpace` resolves but is inert for an unentitled, SIP-on process on Tahoe; removed entirely rather than left as a misleading no-op.

## Capabilities

### New Capabilities
<!-- None — this change refines existing window-enumeration-and-raising behavior. -->

### Modified Capabilities
- `window-enumeration-and-raising`: (1) **Off-Space windows are enumerated** — an off-Space window SHALL be listed even when no live Accessibility element resolves, via a cached element or a CGS metadata heuristic. (2) **Raise an off-Space window with a single Space switch** — a window with no live AX element (Chromium) SHALL be raised via a cached element; no direct Space-switch private API is used. (3) **Raising under Stage Manager does not start a focus war** — off-Space focus is restored by a polling hold-guard after WindowManager grabs frontmost post-Space-switch (the off-Space scenarios are rewritten around this real mechanism, not co-staging).

## Impact

- **Code:** `WindowService.swift` (`snapshot()` listing gate + persistent `elementCache` seeded on app activation and snapshot; `focusSequence()` raise paths and `stageManagerSafe`; the polling hold-guard `offSpaceHoldTick`). Supporting: `FocusLog.swift` (a hold-guard log phase). Removed: the dead `CGSManagedDisplaySetCurrentSpace` symbol and `WindowInfo.displayID` / `SpaceModel.displayForSpace` plumbing, and the temporary diagnostic probe/trace scaffolding. No new private symbols, dependencies, or permissions.
- **Behavior:** current-Space listing and raising unchanged; Stage-Manager-off behavior unchanged; crash-safe degradation when private symbols are missing unchanged.
