## Context

The dwell-to-arm machinery already exists and is the launcher's universal commit contract; the Files band is the lone surface that bypasses it. This change **wires the existing nucleus** into the Files resolution path, not builds a new one.

- **The nucleus is `DwellArmDriver` + `model.armed`.** `LauncherOverlayController` owns a `DwellArmDriver` (a cancellable `DispatchWorkItem` timer + the static `hapticTick()` `.alignment` tick). `manageDwell()` → `startDwell()` (`model.beginArming()` + `dwellDriver.charge(after: dwell)`) → `arm()` (`model.setArmed()` + `hapticTick()`). The lift gate is `end()`'s `guard model.armed else { hide(); return false }`.
- **The Files drill drives a different model and bypasses the gate.** Navigation intents (`filesHighlight`, `filesDepth`) move `FilesNavigationModel.highlightedIndex` via `FilesColumnController`, not `LauncherModel.selectedIndex`, so `manageDwell()` never runs for it. Resolution is the recognizer's `resolveFilesDrillLift` → `resolveFilesDrillExcursion(.lift / .plusOneFingerLift)` → `delegate.filesOpen() / filesOpenWith()`, firing immediately. `AppCoordinator.filesDepth` is even commented *"No edge auto-repeat / dwell here — a Files entry resolves on the lift, not by arming."*
- **The resolutions being gated are new.** `add-files-band-actions` made lift = **deliver to the captured front app** and `+1`-finger = **open the action menu**; both are side-effecting enough that firing-on-contact is a real misfire risk (an accidental paste, an accidental menu).
- **The arm gate belongs in coordinator/controller land, not the recognizer.** The launcher proves the pattern: the recognizer emits the excursion, the *controller* decides armed-vs-not. The Files path already routes every navigation + resolution intent through `AppCoordinator` (and `LauncherOverlayController` / `FilesColumnController`), where the dwell timer + arm state already live. The recognizer stays a dumb excursion detector.

## Goals / Non-Goals

**Goals:**
- The Files drill arms by dwell with the **same** timing (`dwellToArmDuration`), haptic (the existing arm tick), and charge-ring visual as the rest of the launcher.
- A committing Files lift (deliver / open / open-menu / commit a sub-column row) fires **only when armed**; an unarmed lift **dismisses the overlay**.
- The gate covers the **navigator and every sub-column** (action menu, Open-With picker, app grid) — full launcher parity (the chosen scope).
- Reuse the existing nucleus (`DwellArmDriver`, `model.armed`, `dwellToArmDuration`); no parallel timer, no new setting, no Hub change, no recognizer change.

**Non-Goals:**
- A new haptic **pattern** — only the existing arm tick, now reaching the Files surface.
- A per-surface or Files-specific dwell setting — one global `dwellToArmDuration` governs the whole launcher.
- Gating the **discard** — back-out is never gated; only committing lifts are.
- Changing the recognizer's excursion detection, the defuse fuse, or "discard never terminates a running app."

## Decisions

**1. Reuse the launcher's dwell nucleus; gate in the coordinator, not the recognizer.**
The recognizer (`resolveFilesDrillLift` / `resolveFilesDrillExcursion`) is unchanged — it still fires `filesOpen()` / `filesOpenWith()` on the detected excursion. The **arm gate** is added in those coordinator handlers (and the sub-column commits): act only if the highlighted row is armed, else `hide()`. The dwell **timer** reuses `LauncherOverlayController`'s `DwellArmDriver` and the `model.armed` / `arming` semantics — no second timer, no arm-state in the pure recognizer. (Mirror of the launcher, where `end()` — not the recognizer — checks `model.armed`.)
  *Alternative considered (track arm in the recognizer, fire only if armed):* rejected — it would push timing + haptic policy into the pure gesture layer and duplicate the launcher's nucleus; the controller already owns both.

**2. Restart the dwell on every highlight/depth/column move; arm after the dwell.**
Re-charge on: `filesHighlight` (row move), `filesDepth` (descend/ascend lands on a new column's row), the async re-list that re-feeds the column and may shift the highlight, and every sub-column move (`filesActionMenuMove`, `filesPickerMove`, app-grid scrub). Each "the highlighted thing changed" → `beginArming()` + `charge`; after `dwellToArmDuration` → `setArmed()` + `hapticTick()`. Because every step (including edge auto-repeat) re-charges, **auto-drill never arms mid-scroll** — parity with the launcher's `manageDwell()` in the edge tick.

**3. The `+1`-finger morph does NOT restart the dwell.**
Adding a finger doesn't change the highlighted item, and the recognizer re-baselines the count change **without** emitting a highlight step — so the arm **persists** across the morph. The intended flow falls out for free: dwell on the file → arm (haptic) → add a finger → lift → the action menu opens, armed. A scrub-then-immediate-`+1`-lift (no dwell) opens nothing and dismisses. **Entering** the menu then lands on a fresh row → a fresh dwell (the menu's first row must itself be dwelled before its lift commits).

**4. Every lift-to-commit surface is gated (navigator + sub-columns).**
Per the chosen scope: the action-menu rows, Open-With picker rows, and app-grid cells each arm their highlighted row; `filesCommitMenuRow` / the picker-commit fire only when armed; scrubbing re-charges; an unarmed lift dismisses. The charge-ring renders on whichever highlight is active.

**5. An unarmed lift dismisses the overlay; discard backs out one level.**
Parity with the launcher's grammar: **lift = commit-the-armed-thing or leave**, **swipe = back out**. An unarmed lift — at the navigator or inside a sub-column — `hide()`s the whole overlay (it does not back out one level). The four-finger discard remains the one-level back-out and is **never** gated by arm. One mental model: lift to act, swipe to retreat.
  *Alternative considered (unarmed lift in a sub-column backs out to the navigator):* rejected — it splits the meaning of "lift" by context and muddies the contract; the discard is already the back-out.

**6. The charge-ring on `FilesRowHighlight`, reusing the launcher ring.**
The single sliding `FilesRowHighlight` (and the sub-column highlights) gains the launcher's charge-ring fill + armed-lock. It is a **fill overlay on the existing highlight**, not a per-row spring — the documented "`FilesRowHighlight` is NOT bubble-morphed / per-row morphs reintroduce the scrub strobe" landmine is untouched. The ring is the primary arm signal; the haptic is best-effort secondary (same as the launcher).

**7. The arm haptic reuses the existing tick — this supersedes the Files "no new haptics" note.**
`DwellArmDriver.hapticTick()` is the product's single `.alignment` tick, "reserved for moments of arrival (an item arming)." Arming a Files row IS such a moment, so it fires the **same** tick — not a new pattern. This explicitly supersedes the `files-band` design's prior "add no new haptics" line **for the arm moment only**; no per-scrub, per-descend, or per-commit haptics are added.

**8. Arm-state hygiene across re-arm and sub-column transitions.**
Every path that (re)enters a navigable Files surface starts **unarmed** and charges from zero: the `rearmDrill` used by `filesOpenWith` on menu-open and by the delivery-failure retry (`filesDeliver`), plus every sub-column enter/leave. A stale armed flag must never survive a transition and fire an unintended commit. (The launcher gets this free via `manageDwell` on every step; the Files path must reset explicitly at these seams.)

**9. Composes with the existing defuse fuse and observability.**
The arm gate sits **before** the action fires. Armed lift → the existing `commit(afterFuse: filesOpenFuse)` / `filesDeliver` paths run unchanged (the 120 ms defuse window and `.failed` observability are untouched). Unarmed lift → `hide()`, no fuse, no action, no failure. Reuse `dwellToArmDuration` — no new persisted setting, so reset semantics and the Hub are unchanged.

## Risks / Trade-offs

- **Muscle-memory change for current Files-band users:** a quick scrub-and-lift now dismisses instead of opening/delivering. That is the **point** (it matches the launcher and prevents accidental delivery), and the dwell is brief (~0.5s). Accepted.
- **Stale arm across a transition could fire an unintended commit** → Decision 8 (every re-arm / sub-column seam starts unarmed). Unit-test the reset where the state machine allows.
- **More charge-ring surfaces** (navigator + 3 sub-columns) → all reuse the one launcher ring view; no new visual primitive. Per-row spring is explicitly avoided (Decision 6).
- **The arm gate sits in the coordinator, the excursion detection in the recognizer** → they must stay in sync on "what counts as a move that re-charges"; mitigated by re-charging on the **delegate intents** the recognizer already emits (so any move the recognizer recognizes re-charges), not on a parallel notion of movement.

## Open Questions (tuning, not design)

- **Ring geometry on the Files row** — reuse the launcher ring's exact size/placement, or a Files-row-appropriate variant (the row is wider/flatter than a grid tile). Pick a default and tune in run-verify.
- **Descend/ascend feel** — depth steps re-charge identically to a highlight step here; confirm in run-verify that descending fast through folders doesn't feel like it's "fighting" the dwell.
