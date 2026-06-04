## Why

Two off-Space defects remain under Stage Manager (macOS 26 Tahoe, the project's target environment), and verification showed they are **one root tension wearing two masks**: the cross-Space code asks listing and raising to be as authoritative as the current-Space path, and neither can be. Listing **over-trusts Accessibility** (Chromium windows on another Space have no reachable AX element, so they vanish from the switcher — Bug A). Raising **over-forces focus** (the per-app focus singletons that hold key for a lone window start a war with WindowManager's stage arbiter when the destination app is co-staged, so focus lands then is ripped back — Bug B, the same defect as the already-fixed current-Space oscillation, now reachable off-Space). The working tree is also currently **regressed** (singletons skipped on the off-Space path), which loses focus for *every* off-Space window.

## What Changes

- **Stopgap revert (un-regress).** Restore the off-Space path to write the per-app focus singletons (`stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled`) so lone off-Space windows hold key again. This is a transitional baseline, not the Bug B cure — the singletons are the very thing that loses co-staged targets.
- **Bug A — list off-Space windows without requiring an AX element.** Stop dropping an off-Space window just because remote-token brute force found no `AXUIElement` for it. Off-Space raise already needs no AX element (it uses the SkyLight `wid`+`psn` path), so listing must not require one either. Replace the AX-subrole gate, for the no-element case, with a CoreGraphicsServices metadata heuristic (layer, alpha, bounds) that admits real Chromium windows while still rejecting the shadow/companion windows that `options=7` surfaces.
- **Confirmation gate (the mid-point decision).** A single on-device experiment that decides Bug B's course: capture `log stream --predicate 'process == "WindowManager"'` while committing to a co-staged off-Space app (Terminal). It answers one question — does a **window-specific, post-Space-switch-settle** key re-assert hold focus *without* restarting the ~12/sec oscillation? The outcome forks the remaining work.
- **Bug B — hold key for an off-Space raise into a co-staged app without the singleton war.** Branch on co-staging: a lone off-Space target keeps the singleton path (it works); a co-staged target (≥2 of the app's windows on the destination Space) holds key with a **window-specific** mechanism instead of the per-app singletons. The gate decides whether that is a clean one-shot post-settle re-assert (preferred) or a watchdog-driven re-assert that tolerates a brief flicker (fallback).

## Capabilities

### New Capabilities
<!-- None — this change refines existing window-enumeration-and-raising behavior. -->

### Modified Capabilities
- `window-enumeration-and-raising`: (1) **Off-Space windows are enumerated** — an off-Space window SHALL be listed even when no Accessibility element resolves for it, using a CGS metadata heuristic in place of the AX-subrole gate for that case. (2) **Raising under Stage Manager does not start a focus war** — the existing "off-Space raise unaffected by Stage Manager" scenario changes: an off-Space raise into a co-staged app under Stage Manager SHALL hold keyboard focus without asserting the per-app focus singletons that start the oscillation.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/Windows/WindowService.swift` (`snapshot()` listing gate; `focusSequence()` raise paths and the `stageManagerSafe` condition; the off-Space probe block in `diagnosticReport()`), `Sources/ThreeFingerSwitcher/Windows/AXPrivate.swift` (`bruteForceWindows` remains, no longer load-bearing for listing). No new private symbols, dependencies, or permissions.
- **Behavior:** current-Space listing and raising unchanged; Stage-Manager-off behavior unchanged; crash-safe degradation when private symbols are missing unchanged.
- **Process gate:** Bug B implementation is blocked on the mid-point on-device capture; the change is structured so the stopgap and Bug A ship first and Bug B's mechanism is proven before its fix lands.
