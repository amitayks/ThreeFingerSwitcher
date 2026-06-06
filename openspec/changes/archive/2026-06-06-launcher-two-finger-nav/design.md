## Context

The (archived) `four-finger-launcher` change built the launcher as a **held gesture**: land four fingers, swipe past a threshold to open the overlay, scrub horizontally to step items / vertically to step context bands, dwell-to-arm, lift to fire. The recognizer **latches the contact count at `begin`** (3 = switcher, 4 = launcher) and routes the whole gesture by that latched count; steps come from centroid travel measured against a reference origin with sub-step carry. A session `ScrollEventTap` consumes scroll while `currentFingerCount >= 3` so the freed multi-finger swipe never leaks scroll to the app. `AppCoordinator` owns the recognizer, the `LauncherOverlayController` (which exposes `isVisible`), and wires the tap's consume predicate.

The ergonomic weak point: four splayed fingers are tiring and jittery for the fine dwell-to-arm selection. The hand wants to relax. This change lets it relax to **two fingers** after the launcher is open, without giving up the held-gesture model (and its lift-to-dismiss safety).

## Goals / Non-Goals

**Goals:**
- After a four-finger activation, let the user **drop to two (or three) fingers** and keep navigating; four fingers keeps working unchanged.
- Make the four→two hand-off **seamless** — no spurious step from the centroid shift, no accidental switcher hand-off from the transient three-finger count, no cancel.
- Preserve the launcher's commit/dismiss model exactly: dwell-to-arm, **lift fires the armed item else dismisses** — where "lift" now means contacts drop **below two**.
- Keep two-finger scrolling completely normal whenever the launcher is closed.

**Non-Goals:**
- **No persistent / modal launcher.** The overlay must never linger after the hand leaves the trackpad; lift-to-dismiss is a feature, not a bug (explicit product decision). So we do **not** decouple "open" from "held," do not make the overlay interactive (mouse/keys), and do not add a sticky mode.
- No change to the dwell-to-arm timing, the overlay visuals, the item/context step *distances*, or any launch-action behavior.
- No new opt-in/setting — this is always-on once the launcher is enabled (dropping fingers is optional and additive; there's no downside to expose).
- No new permissions or system-settings writes.

## Decisions

### D1. The launcher gesture is latched, and lives while ≥2 contacts remain

The recognizer already latches `launcher` at `begin` (4 contacts). Extend that latch's **lifetime rule**: the launcher gesture stays active while `contacts >= 2`, and **ends when `contacts < 2`**. The latched mode is *never* re-evaluated mid-gesture, so the contact count passing through 3 (or 2) during a lift does **not** route to the switcher and does **not** cancel. A new gesture (and a fresh latch) can only begin after contacts return to 0. Activation (overlay open) is unchanged — it still requires the four-finger swipe to cross the activation threshold; dropping fingers only matters *after* the gesture has begun.

*Why ≥2 and not ≥1:* two contacts give a stable centroid and a clear, deliberate "still navigating" signal; one finger is ambiguous with a tap/click and too easy to leave resting. Two is also the floor that lets the scroll tap own the movement as "scroll" (see D4).

### D2. Re-baseline the step origin on every contact-count change

Steps are computed from centroid travel against a reference origin. Removing a finger **moves the centroid** (the average of remaining contacts), which would otherwise register as a large instantaneous travel and fire spurious item/context steps right at the moment of relaxing the hand. So on **every change in contact count**, reset the step reference origin to the *current* centroid and clear any in-progress sub-step carry. The result: relaxing four→two produces zero steps; only finger *movement after* the new baseline advances the selection.

*Alternative considered — track a single anchor finger instead of the centroid:* rejected; finger identity across frames is unreliable from the passive read, and the centroid (re-baselined) is simpler and steadier.

### D3. End = "below two contacts"; commit/dismiss unchanged

On the end transition (`contacts < 2`), the recognizer emits the existing launcher `end` intent; `LauncherOverlayController.end()` fires the armed item or dismisses, exactly as today. A quick four-finger flick that drops below two *before* the dwell arms anything therefore still **dismisses harmlessly** — the safety property is preserved verbatim. No new intents are added; the recognizer→coordinator→overlay protocol is unchanged, only what drives the steps (≥2-finger centroid) and what triggers `end` (<2 contacts).

### D4. Scroll tap consumes while the launcher overlay is open

Two-finger movement makes the OS emit two-finger scroll. To keep it from scrolling the app *underneath* the launcher, widen the tap's consume predicate from `currentFingerCount >= 3` to `currentFingerCount >= 3 || launcherOverlay.isVisible`. While the overlay is open, all scroll is swallowed (covering two-finger navigation); the instant it closes, the predicate falls back to `≥3` only, so **normal two-finger scrolling is untouched** at every other moment. The `isVisible` signal already exists on the overlay controller and flips deterministically on activate/end/cancel.

*Trade-off:* post-lift momentum scroll can arrive a few frames after the overlay hides and would leak to the app. Acceptable (a tiny blip); if it proves noticeable, hold the consume for a short grace window after close.

### D5. No persistence — re-affirmed in the recognizer's end rule

Because `end` is driven purely by `contacts < 2`, the overlay cannot outlive the hand: lifting to zero (or one) always ends it. There is intentionally no timer, no key/click commit, and no "stay open" path. This keeps the lift-to-dismiss safety that makes a stray launcher flick consequence-free.

## Risks / Trade-offs

- **[Centroid jump on relaxing fingers fires a spurious step]** → D2 re-baselines the origin and clears carry on every count change; covered by a recognizer test that simulates 4→3→2 with a centroid shift and asserts zero steps emitted.
- **[Transient three-finger count hands off to the switcher or cancels]** → D1's latch is never re-evaluated mid-gesture; test asserts no switcher intents during a 4→2 drop.
- **[Two-finger navigation scrolls the app underneath]** → D4 consumes scroll while the overlay is visible; test asserts the consume predicate is true when `isVisible` even at two fingers, and false (for two fingers) when closed.
- **[Normal two-finger scrolling breaks]** → the consume widening is strictly scoped to `isVisible`; when the launcher is closed the predicate is byte-for-byte the old `≥3` rule. Manual verification on the signed build (the tap is TCC-dependent).
- **[Post-dismiss momentum scroll blip]** → noted in D4; mitigation (grace window) deferred unless observed.
- **[One-finger resting keeps the launcher open]** → floor is two contacts, not one, specifically so a single resting finger ends the gesture.
