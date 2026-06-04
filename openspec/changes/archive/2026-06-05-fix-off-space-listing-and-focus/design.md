## Context

This change is grounded in two on-device confirmations already in hand and one still to capture. The live probe in `/tmp/tfs-cross-space-diag.txt` confirms **Bug A**: every off-Space window shows `axWin=0` (kAXWindowsAttribute is structurally current-Space-only), and Chromium windows show `brute=0` (the remote-token sweep, axId `0..<1000`, never resolves them) — e.g. `wid 16682 pid 1237 space 146 brute=0 axWin=0 'New Tab'` and two Chrome-Remote-Desktop windows. Those rows are dropped at the listing gate `guard let el = element, isSwitchable(el)` (`WindowService.swift:167`); every off-Space window that *survived* had `brute=1`.

A multi-agent trace of the seven archived changes confirmed the **Bug B** mechanism and reframed it: off-Space focus loss is the *same defect* as the already-fixed current-Space oscillation — asserting the per-app focus singletons (`kAXMain` + the app's `kAXFocusedWindow`) toward a Stage-Manager co-staged window makes WindowManager's stage-front arbiter fight back. Enumeration is passive (it only reads); the SkyLight handshake is window-specific and exonerated (it is kept un-gated under Stage Manager). `cross-space-windows` did not *create* the focus-stealing mechanism — it gave the pre-existing singleton defect a new surface (co-staged off-Space apps). The singletons entered the live raise path in `fix-focus-vacuum-on-raise`.

Current state: the working tree is **regressed** — `WindowService.swift:271` reads `let stageManagerSafe = StageManager.isEnabled`, which skips the singletons on *both* paths and loses focus for every off-Space window. Constraints from the project: never crash, never regress below current-Space behavior, degrade cleanly when private symbols are missing, and — per hard-won discipline — **confirm the mechanism on-device before shipping a fix** (two prior wrong turns came from guessing).

## Goals / Non-Goals

**Goals:**
- Un-regress: lone off-Space windows hold keyboard focus again (stopgap).
- List Chromium (and any no-AX-element) off-Space windows in the switcher (Bug A).
- Hold keyboard focus for an off-Space raise into a co-staged app, without starting the WindowManager oscillation (Bug B).
- Decide Bug B's exact mechanism from a single, well-defined on-device capture rather than by guessing.

**Non-Goals:**
- Changing current-Space listing or raising, or Stage-Manager-off behavior (byte-for-byte unchanged).
- Curing an already-stuck WindowManager oscillation from inside the app (it is daemon-owned; we prevent triggering).
- Widening or replacing the enumeration source, or touching thumbnails, the gesture, or the grid. (A lightweight persistent element cache — a simplified AXObserver-registry idea — WAS added for the no-AX raise; see Resolution.)
- Making Chromium expose AX elements off-Space (out of our control; we route around the need).

## Decisions

### D0 — Stopgap revert first (un-regress, transitional)
Restore `WindowService.swift:271` to `let stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled`: current-Space under Stage Manager skips the singletons (the archived oscillation fix — kept), and the off-Space path writes them again so lone off-Space windows hold key. This is explicitly a **baseline, not the Bug B cure** — the same singletons are what lose a co-staged target. Ship it first so the tree is never regressed while Bug A and Bug B land. *Alternative — jump straight to the Bug B fix:* rejected; it couples un-regressing to an unproven mechanism and violates confirm-before-ship.

### D1 — List off-Space windows without requiring an AX element (Bug A)
At the listing gate, stop hard-requiring an element. When `bruteForceWindows`/`currentSpaceElements` resolve an element, keep `isSwitchable(el)` (preserves today's precise filtering for the windows that resolve). When no element resolves *and* the window is off-Space, decide switchability from CGS/CGWindowList metadata already in `CGMeta`: `layer == 0` (already filtered) **and** `alpha > 0` **and** a real on-screen-sized frame. A nil-element off-Space `WindowInfo` is already raisable — `WindowInfo.axElement` is `Optional`, the off-Space raise uses `pid`+`wid` via SkyLight, the AX raise is `if let el`, and `resolveElement()` re-attempts brute force at commit. So only the listing filter blocks Chromium; loosening it for the no-element case is sufficient.

The exact heuristic thresholds (min frame size; whether a name/alpha test is needed to reject shadow duplicates) are **probe-derived, not guessed** — see D2 step 1. *Alternatives:* (a) widen the brute-force range past `1000` — rejected: a guess, blows the 100 ms/app budget, and Chromium may not expose elements by remote token at any id; (b) union `kAXWindowsAttribute` — rejected and already failed: it is current-Space-only (`axWin=0` for all off-Space rows) and blocks the main thread.

### D2 — The confirmation gate (mid-point; forks the remaining work)
Two captures, then one decision:

1. **Bug A heuristic probe (before D1 lands).** Extend the existing off-Space probe block in `diagnosticReport()` to also print `alpha`, `bounds`, and `name` for each `brute=0` layer-0 regular-app off-Space window. Capture from a Space where Chrome's *main* window is off-Space. Confirm the separating line between real Chromium windows and shadow/companion junk, then set D1's thresholds from the data.

2. **Bug B mechanism capture (the pivot).** After D0, reproduce a commit to a co-staged off-Space app (Terminal) and capture `log stream --predicate 'process == "WindowManager"'` plus the focus log. This answers exactly one question: **does a window-specific, post-Space-switch-settle key re-assert hold focus *without* a sustained reorder storm?**
   - **Outcome PASS** → adopt D3a (clean one-shot window-specific re-assert).
   - **Outcome FAIL** (re-assert doesn't hold, or still oscillates) → adopt D3b (watchdog-driven re-assert tolerating a brief flicker).
   - Oscillation signature: sustained `Model window order changed` at ~12/sec; healthy is ≤ a few transient reorders that settle.

### D3 — Hold key for a co-staged off-Space raise (Bug B; gated by D2 step 2)
Branch on co-staging, which we can compute from data already gathered: count the target app's `layer == 0` windows placed on the destination Space in the per-Space enumeration (`spaceForWindow` + `meta`).
- **Lone target (1 window on destination stage):** keep the singleton path from D0 — it holds key and has no sibling to fight.
- **Co-staged target (≥2):** do **not** write the per-app singletons. Establish key with a window-specific mechanism:
  - **D3a (preferred, if D2 PASS):** re-run the window-specific `makeKeyWindow(psn, wid)` once after the destination stage settles (a short delay, or piggy-backed on the existing watchdog tick). Window-specific ⇒ no per-app war; post-settle ⇒ not stomped by re-staging.
  - **D3b (fallback, if D2 FAIL):** let the watchdog detect the lost key and re-assert window-specifically up to the existing recovery bound, accepting one brief flicker rather than a clean single shot.
*Alternative — decompose the singleton* (write only one of `kAXMain` / app `kAXFocusedWindow`): held in reserve; cheaper to test than to design around, but only if D3a/D3b both disappoint.

### D4 — Co-staging detection from the enumeration we already have
Reuse the per-Space window→pid placement built in `snapshot()` to count an app's windows on a given Space; no new private calls. The count is captured into the `WindowInfo` (or recomputed at commit) so `focusSequence` can branch without a second enumeration.

## Risks / Trade-offs

- **CGS heuristic re-admits shadow/companion windows** (the thing the AX subrole filter used to drop) → Mitigation: keep the AX filter whenever an element resolves; for the no-element case use probe-derived thresholds (alpha/frame) and, if needed, de-duplicate by `(pid, bounds)` so a shadow that duplicates a real window is dropped.
- **Window-specific post-settle re-assert may not survive WindowManager re-staging** → This is exactly what D2 step 2 measures; D3b is the pre-planned fallback, so a FAIL does not strand the change.
- **Co-staging count from CGS may be imprecise** (hidden/minimized members) → Count only `layer == 0` windows on the destination Space; err toward treating a target as co-staged (the window-specific hold is safe for lone targets too, just slightly more work).
- **"Settle" timing is environment-dependent** → Measure the reorder-quiet point from the WindowManager capture; reuse the existing 180 ms watchdog cadence as the first candidate rather than inventing a new timer.
- **Listing a non-switchable Chromium helper window** → Low impact: the raise path no-ops safely on a dead/odd wid, and the watchdog will not falsely recover (it checks frontmost+key, not the specific wid).

## Migration Plan

Phased, each phase independently shippable and gated by on-device confirmation:
1. **D0 revert** → `INSTALL=1 ./scripts/build-app.sh`, `open` the app, confirm lone off-Space focus holds (and, per the open discrepancy, observe whether the "every off-Space deselects" regression reproduces).
2. **D2 step 1 probe → D1** → enhance probe, capture Chrome-off-Space, set thresholds, implement list-without-AX, confirm Chrome appears off-Space with no shadow duplicates.
3. **D2 step 2 capture (the gate)** → reproduce co-staged Terminal off-Space, capture WindowManager log, choose D3a vs D3b.
4. **D3** → implement the chosen hold, confirm focus holds with no ~12/sec storm; `swift test`.

Rollback: phases are independent; D0 is the safety floor (never worse than the prior shipped behavior for any Stage-Manager user).

## Resolution (as shipped — the Decisions above are the path taken; this is where it landed)

On-device traces revised two hypotheses above. The shipped fixes, all confirmed on-device:

**Bug A — listing (D1, as designed).** Off-Space windows list without a live AX element via the CGS heuristic `alpha > 0 && min(width, height) ≥ 130` (real off-Space windows, incl. Stage Manager strip thumbnails, have min-dim ≥ 150; junk toolbars/slivers/alpha-0 shadows are ≤ 106 or alpha 0 — confirmed across two diags). No `(pid, bounds)` de-dup was needed (captures showed thin/zero-alpha junk, not shadow *duplicates*).

**Bug A — raising a no-AX off-Space window (Chrome) — NEW (the D2 gate was abandoned).** Listing wasn't enough: selecting an off-Space Chrome window fronted the app but didn't switch Spaces, because the Space switch is driven by `kAXRaiseAction` on an element Chrome doesn't expose. The fix is the AltTab/HyperSwitch strategy — a **persistent `elementCache`** keyed by CGWindowID, seeded when an app activates (its windows are then on the current Space and resolvable) and during snapshots, reused as a fallback when brute force fails. A cached element stays valid across Spaces, so `kAXRaise` on it switches to and focuses the window. Limit: a window off-Space since before launch and never focused has no cached element and can't be navigated to (the documented AltTab limit).

**Bug B — NOT a co-staging war (revises D3/D4).** The multi-delay focus trace showed **WindowManager (the Stage Manager daemon) grabs frontmost with no key window ~300ms after EVERY off-Space raise** — lone *and* co-staged alike — past the +180ms watchdog. The shipped fix is a **bounded polling hold-guard** (`offSpaceHoldTick`, off-Space + Stage Manager only): poll every ~60ms, re-front the target the instant the steal is detected (≈ one-frame flash), cover the occasional late re-steal, capped at 6 re-fronts / ~2.4s, bail on secure input. The co-staging detection (D4) and lone-vs-co-staged branch (D3) were **not built** — co-staging is not the discriminator; the gentler fixed-delay re-assert (D3a) was prototyped, confirmed it sticks, then replaced by the faster polling guard.

**Rejected — direct Space switch (option 1).** `CGSManagedDisplaySetCurrentSpace` resolves but is inert for an unentitled, SIP-on process on Tahoe — the WindowServer gates Space switching to Dock.app's privileged connection (the reason yabai needs SIP disabled). Confirmed on-device (no visible switch despite a valid display UUID) and removed entirely. The `SLSBridgedMoveWindowsToManagedSpaceOperation` "move the window to you" alternative was researched as a fallback but not adopted — the cached-element raise made it unnecessary, and it has a jarring move-vs-navigate semantic.

## Open Questions — all resolved

1. **Bug A thresholds — RESOLVED.** `alpha > 0 && min(width,height) ≥ 130`.
2. **Bug B hold — RESOLVED.** A polling hold-guard that re-fronts on detection holds focus cleanly; the steal is a WindowManager front-grab, not a co-staging oscillation, so no co-staging branch is needed.
3. **No-AX raise — RESOLVED.** Cached AX element + `kAXRaise`; a direct Space switch is impossible (Dock-gated) and was removed.
