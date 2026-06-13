## Context

Every in-overlay navigation today is an **odometer**: `GestureRecognizer` accumulates signed centroid travel between frames (`stepAccumulator += c.x - lastCentroid.x`) and emits a step each time the accumulator crosses `stepDistance`, with carry. "Home" doesn't exist, so to traverse a long list you physically sweep across the pad and hit the trackpad edge — which is why `LauncherOverlayController` has an **edge-triggered** auto-repeat (`launcherEdgeChanged` → `edgeTimer` → `edgeInterval(tick:acceleration:)`, a hyperbolic `0.18s → 0.03s` ramp).

The grounding pass established two enabling facts:
- `TouchFrame.contacts` is `[OMSTouchData]` and each carries `.position` (normalized x/y) — the **per-finger footprint spread is already in the data**, but the recognizer only reads `fingerCount` + `centroid`. So a footprint-scaled local frame is feasible (with a fixed fallback for the test-only `TouchFrame(testFingerCount:)` init, which carries empty `contacts`).
- The recognizer already runs **modal sub-state bypasses** (`launcherCanvasResolutionActive`/`trackCanvasResolution`, `filesDrillActive`/`trackFilesDrill`) routed as the first statements of `feed()`, already **re-baselines the origin on every contact-count change**, and already has a **relative +1-finger** morph (Files `pendingOpenWith`, design D4) and **enter/exit hysteresis** (`edgeAxis`, 0.16/0.24). The controller's `edgeTick` already carries every cross-cutting concern (relayout on band change, files-drill/search resync, dwell reset, clamp-doesn't-reset-dwell).

User decisions for this change (locked):
1. **Keep** the current open/switch activation (odometer fling) — the joystick is navigate-while-open only.
2. **Move** the AI canvas resolution from four fingers to **two** (down = apply, horizontal = dismiss).
3. The current dwell-accelerate is wrong: it must be **eased** — first step immediate, the next after a short initial delay, then the interval shortens **along a curve** (not slow→fast in no time) toward a fast floor — on **both axes, everywhere**.

## Goals / Non-Goals

**Goals:**
- One **anchored-joystick** navigation language across the launcher grid, the Files navigator, and the AI canvas: the landing footprint is the center, a small offset is a direction, an out-and-back is one step, a held offset auto-repeats.
- A **smooth eased acceleration curve** for auto-repeat, triggered by dwelling in the offset zone (not the physical edge), uniform on both axes and every surface.
- The relative **+1-finger → action-menu** intent generalized off the Files-only Open-With morph.
- The AI canvas resolved by **two fingers** (down = commit, horizontal = discard), aligning "4 = open/dismiss platform, 2 = act within."
- A **pure, testable** positional core (`swift test`); the MLX/`GemmaRuntime` split untouched.

**Non-Goals (v1):**
- The **three-finger window switcher** keeps the odometer model. It has no auto-repeat today and is the app's oldest, most-used gesture; converting it is out of scope (flagged as a future follow-up). "On all the app" is scoped to the launcher-family navigation surfaces that actually auto-repeat.
- No change to **opening/activation** thresholds or the latch/relax-to-two/end lifecycle — only the post-activation *interpretation* changes.
- No new haptics (respect the existing single `.alignment` arm tick) and no new permission.
- No change to what a step *does* (the band-list ⇄ grid topology, clamp/wrap, Clipboard/Files carve-outs) — only how a step is *produced*.

## Decisions

### D1 — A shared positional interpreter, reached by extending the Files-drill pattern first
Add one **anchored positional interpreter** (offset-from-center → signed per-axis zone) and route the launcher's post-activation navigation, the Files drill, and the canvas resolution through it. Sequencing: **extend the proven `trackFilesDrill` shape into the launcher first, then extract the shared core** once two surfaces use it — rather than a big-bang unification of the three trackers up front. *Alternative:* rewrite all three trackers into one unified tracker immediately. Rejected for v1 — higher risk to the load-bearing recognizer; the incremental path keeps each step verifiable.

### D2 — Anchor = centroid; scale = footprint spread, with a fixed fallback
On entry and on every contact-count change, capture `center0 = centroid` and `scale0 = k · spread(contacts)` where `spread` is derived from the per-contact `.position` values (e.g. mean distance from centroid, or bounding extent). Navigation reads `offset = (centroid − center0) / scale0`, so the same physical nudge means the same thing regardless of where the hand landed and how far apart the fingers are. When `contacts` is empty or `spread ≈ 0` (test frames, degenerate snapshots), fall back to a **fixed normalized scale**. *Alternative:* fixed normalized radius always (ignore footprint). Rejected — the user explicitly wants the operating region sized to the fingers' landing area, and the data is already present; the fixed value survives as the fallback.

### D3 — Per-axis zone state machine with inner/outer hysteresis
Per axis: states `armed → fired → repeating`. Crossing the **outer** threshold while `armed` emits **one** step and disarms; returning inside the **inner** deadzone re-arms. While beyond outer, the recognizer emits a **held-in-zone signal** carrying the sign (−1/0/+1) — it does **not** time the repeat. This reuses the existing `edgeAxis` enter/exit hysteresis idea, repointed from "near physical edge" to "offset beyond local threshold." *Alternative:* keep accumulating travel and emit on distance. Rejected — that's the odometer we're replacing; it can't express "hold here."

### D4 — Eased auto-repeat lives in the controller, keyed to dwell *duration* not tick count
Replace `edgeInterval(tick:acceleration:)` with a **time-based eased curve**: `interval(dwell) = floor + (start − floor) · ease(dwell / rampTime)` clamped at `floor`, where `ease` is a smooth decay (e.g. easeOut / `1 − (1−x)^2`, or exponential). The first step fires immediately (the recognizer's outer-crossing step); the controller's repeat timer then fires the second after `initialRepeatDelay` and shortens along the curve. The trigger is the positional **held-in-zone signal** replacing `launcherEdgeChanged`; `edgeTick`'s cross-cutting work (relayout, resync, clamp-doesn't-reset-dwell) is preserved. *Alternative:* keep the tick-indexed hyperbolic `1/(1+ramp)`. Rejected — it's edge-triggered and the user finds the feel wrong; dwell-duration easing is the explicit ask.

**On the "30 ms" number:** the user's literal "another step after 30 ms, then faster, but not fast in no time" is internally tense (30 ms *is* fast). We read it as: **first step immediate → second after a comfortable `initialRepeatDelay` → eased decay to a ~30 ms floor**. `initialRepeatDelay`, `floor`, and the curve shape are **tunables** with feel-tuned defaults (see Open Questions); 30 ms is taken as the fast floor, not the initial repeat.

### D5 — Two-finger canvas resolution, distinguished from scroll by a deliberate-excursion threshold
Re-key `trackCanvasResolution` from four fingers to two: a fresh two-finger **down** swipe past a deliberate threshold commits; a two-finger **horizontal** swipe discards; **up** is ignored. Because the canvas is also a **scrollable, input-capturing** surface, the resolve excursion threshold MUST be **larger than incidental two-finger scrolling** so reading the result isn't mistaken for a resolve (the main scroll-vs-resolve risk — see Risks). *Alternative:* keep four-finger resolution. Rejected — decision #2; it also unifies the grammar (4 = platform open/dismiss, 2 = act within).

### D6 — Generalize the relative +1 morph into a surface-agnostic action-menu intent
Promote the Files `pendingOpenWith` (`count > drillContacts`, one-shot) to a general **action-menu** intent the launcher grid and Files both emit; Files' "Open-With" becomes one binding of it. Keep it **relative** to the re-anchored baseline (not absolute three) so a user already holding three doesn't false-trigger (D4 landmine preserved). *Alternative:* absolute three-finger tap. Rejected — ambiguous against the relax-to-two baseline.

### D7 — Item vs band coarseness via two outer thresholds (repurpose existing tunables)
The launcher's existing `launcherStepDistance` / `launcherContextStepDistance` are repurposed from odometer travel distances into the **positional outer thresholds** for item movement vs band switching — so a coarser context step still keeps band switching deliberate while item movement stays fine, with no new settings semantics to learn. *Alternative:* deprecate/remove them. Rejected — repurpose avoids a `REMOVED` migration and preserves the user's existing band-vs-item tuning.

## Risks / Trade-offs

- **Two-finger resolve vs. canvas scroll.** Two-finger down could be read as scroll-down. → *Mitigation:* the resolve is a deliberate excursion past a threshold well above incidental scroll, and the overlay's scroll tap already mediates two-finger scroll while open; tune the threshold against real reading/scrolling. Flagged as the top thing to validate in-hand.
- **Losing the fast "throw across the pad."** Pure joystick replaces flinging with hold-to-accelerate. → *Mitigation:* the eased curve reaches a fast floor quickly; optionally blend `TouchFrame.centroidVelocity` (already computed) so a fast flick still throws multiple steps while small offsets stay precise. Deferred unless the floor feels slow.
- **Footprint instability.** Fingers splay/drift, changing the spread mid-gesture. → *Mitigation:* capture `scale0` at anchor time and hold it for the session segment; re-anchor only on contact-count change (existing hook). The fallback covers degenerate frames.
- **Feel is unspecifiable up front.** Deadzone, outer threshold, initial delay, floor, and curve shape are pure feel. → *Mitigation:* ship as tunables with defaults; iterate on a stable-signed build (agent can't sign).
- **Regressing load-bearing recognizer code.** The latch/relax/re-baseline rules are documented landmines. → *Mitigation:* extend-then-extract (D1); the positional model re-uses the existing re-baseline hook as its re-anchor; keep the odometer path for opening/activation and the window switcher untouched; existing recognizer tests stay green or migrate deliberately.
- **Stale `CLAUDE.md` landmine.** The doc says the canvas resolves on a *four*-finger swipe and the Files drill is the only +1 morph. → *Mitigation:* update the landmines (two-finger canvas resolve, anchored-positional navigation not odometer, dwell-eased not edge-triggered repeat, +1 generalized to action-menu).

## Migration Plan

Additive and behind the existing launcher opt-in. No data migration (new tunables default in). **Rollback** is reverting the change; the opening/activation and window-switcher paths are untouched, so the core gestures degrade to today's behavior if navigation is reverted. Verify the positional interpreter, zone state machine, footprint scaling + fallback, the eased interval curve (monotonic decay to floor, no abrupt jump), and the two-finger canvas resolution via `swift build`/`swift test`; compile-check the MLX-linked app via `xcodebuild`; in-hand feel tuning on a stable-signed build (user-run).

## Open Questions

- **Default feel values** — `initialRepeatDelay`, `floor` (~30 ms?), the curve shape (easeOut vs exponential), the inner/outer thresholds, and the footprint factor `k`. Pick defaults, tune in-hand.
- **Velocity blend** — adopt the flick-to-throw blend (D-Risk) in v1, or rely on the acceleration floor alone?
- **Window switcher** — leave on odometer (current plan) or extend the joystick to it in a follow-up?
- **Action-menu surface** — the launcher grid's action menu contents (vs. Files' Open-With): what actions does a launcher item expose on +1, and does this overlap with the dwell-to-arm fire? Resolve when wiring the launcher binding.
- **Footprint spread metric** — mean-distance-from-centroid vs bounding extent vs nearest-pair; pick the most stable against splay during implementation.
