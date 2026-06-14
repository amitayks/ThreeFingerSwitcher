## Context

The archived `positional-navigation` change replaced the odometer with an **anchored joystick**: `PositionalNavigator` holds a center + footprint scale and two `AxisZone`s, and `feed(centroid:)` returns a per-axis step delta + held sign. It feeds **both** axes every frame from one diagonal offset (`GestureRecognizer.updateLauncher` / `trackFilesDrill`). Real strokes are never perfectly axis-aligned, so an angled stroke moves both axes at once.

This bites hardest at the launcher's **rail↔grid crossing**, because vertical means different things on each side: the band rail is a vertical icon column (vertical = switch band, right = enter items); the grid is to its right (vertical = step a row, left@col0 = back to the rail). The crossing itself is purely horizontal, so a diagonal stroke both crosses **and** fires an unwanted vertical step — entering the wrong band, or jumping off the band you came from. The model already preserves `currentBand` across a horizontal crossing (neither `LauncherModel.stepHorizontal` branch touches `currentBand`), so "land on the same icon" needs **no new memory** — only suppression of the spurious vertical.

This is the mega-menu "diagonal aim" problem; its standard fix is the **menu-aim triangle**. In an offset-from-center joystick (no screen cursor), the faithful analog is an **angular directional axis-lock** — the same mechanism iOS / browsers use for scroll-direction locking. User decisions (locked): apply the lock **globally** across launcher navigation, **and** in the **Files band**.

## Goals / Non-Goals

**Goals:**
- One stroke moves **one axis**: an off-axis (diagonal) stroke commits to the dominant axis and forgives perpendicular drift, in all directions.
- The rail↔grid crossing forgives vertical drift (enter the current band; return to the origin band), with a fresh deliberate vertical stroke required to change bands afterward.
- Clean **L-shaped** grid moves (right, then down) via a hysteresis re-commit, not diagonal movement.
- The mechanism lives in the **pure, testable** `PositionalNavigator` core (`swift test`), opt-in per navigator, working with both position-tracking and out-and-back axes.
- New feel tunables (wedge, hysteresis) surfaced on the Hub Launcher page with the live preview drawing the wedge.

**Non-Goals:**
- The opening/activation odometer fling and the three-finger window switcher stay untouched.
- The media player's out-and-back transport is a possible follow-up, not in scope.
- No change to the absolute position-tracking model (offset = index inside the box), the margin/eased auto-repeat, `reArmBackoff`, or what a step *does*.
- No new haptics, no new permission.

## Decisions

### D1 — The lock lives in `PositionalNavigator`, as an opt-in arbiter before the per-axis feed
Add an axis-commit arbiter inside `PositionalNavigator.feed`, gated by an opt-in flag (e.g. `axisLock: Bool` / a mode). When off, `feed` behaves exactly as today (both axes fed) — so the media player and any future surface are unaffected until they opt in. The recognizer enables it on `launcherNav` and `filesNav`. *Alternative:* implement the lock in the recognizer around `feed`. Rejected — the recognizer can't cleanly freeze an `AxisZone`'s index without reaching into its state; the core owns the zones and is where the behavior is unit-testable.

### D2 — Commit state machine: `none → {horizontal | vertical}`, with a wedge gate
Track `committed ∈ {none, horizontal, vertical}`. Per feed, compute `ox = |off.x|`, `oy = |off.y|`:
- **`none`:** commit only when one axis clearly dominates — `max(ox,oy) ≥ engage` **and** `dominant ≥ wedgeRatio · other`. Near the diagonal (ratio not met) commit to neither and emit nothing. This is the drift forgiveness: a stroke that *starts* slightly off-axis but *becomes* clearly dominant commits to the dominant direction (the off-axis component is still sub-`engage` early on).
- **committed:** feed only the committed axis; **do not feed** the other (freezing its index — feeding `0` under position-tracking would step it back to center).
*Alternative:* "first axis past the step threshold wins." Rejected — an arc that begins vertical would mis-commit; the wedge ratio is what tolerates the angled start.

### D3 — Re-commit on a deliberate turn, with **per-axis** re-anchor
Stay committed until either: (a) **settle** — both offsets back inside the deadzone → `committed = none` (re-arm); or (b) **turn** — the perpendicular axis exceeds the committed one by `recommitHysteresis` (e.g. `otherO ≥ committedO + hysteresis`) → switch `committed`, and **per-axis re-anchor** the newly committed axis (set only that axis's center component to the current centroid, reset that `AxisZone`). The previously committed axis's index holds. Per-axis re-anchor (vs. full re-anchor) keeps the frozen axis's accumulated selection intact while giving the new direction a fresh zero offset, so the turn doesn't emit a multi-step jump and you get an L-move. *Alternative:* full `reanchor` on re-commit. Rejected — it would reset the frozen axis's index too, losing the column/row you'd reached.

### D4 — Per-axis center, minimally
Per-axis re-anchor needs to move one component of the anchor center. Keep `PositionalAnchor` as-is and, on re-commit, rebuild it as `PositionalAnchor(center: CGPoint(x: turnVertical ? anchor.center.x : centroid.x, y: turnVertical ? centroid.y : anchor.center.y), scale: anchor.scale)` and reset the matching `AxisZone`. No structural change to the anchor type; the `peakX/peakY` margin tracking for the re-anchored axis resets too. *Alternative:* split the anchor into two independent per-axis anchors. Rejected as over-engineering for one re-anchored component.

### D5 — Re-arm on every `reanchor`, and works for out-and-back too
`reanchor(center:spread:)` (contact-count change, activation) resets `committed = none`. The arbiter reads `|offset|` per axis, which is defined for both modes, so the Files **depth** axis (out-and-back) participates: a diagonal stroke that's horizontal-dominant drills without moving the highlight, and a vertical-dominant stroke scrubs the highlight without drilling. The out-and-back axis still emits exactly one step per excursion — the lock only gates *whether* it's fed.

### D6 — Tunables: a wedge ratio and a hysteresis margin (feel-only)
Add `positionalCommitWedge` (the dominance ratio — or a half-angle converted to a ratio) and `positionalRecommitHysteresis` (offset units) to `AppSettings` (`Defaults`/`Keys`/`didSet`/reset), fed into the navigator on rebuild (alongside the existing `edgeMargin`/`reArmBackoff` wiring). Defaults: a wedge that forgives ~30° of drift and a hysteresis above hold jitter. Surface both on the Hub Launcher page; `PositionalTrackpadPreview` draws the wedge (and the diagonal no-commit region) around the center and indicates the committed axis live. *Alternative:* hard-code the feel. Rejected — every other positional value is a live tunable; this matches and the values are pure feel.

### D7 — A wider, directional crossing wedge for entering the items (refinement)
The symmetric wedge still leaves a ~45° up/down-and-right stroke from the band rail ambiguous (or read as a band switch). To make "move toward the items" win at steeper angles, the navigator gains an optional **rightward-only** wider commit ratio (`commitWedgeRightward`, applied when `off.x > 0`); the recognizer sets it to a wider `positionalCrossingWedge` (default 55° vs. the base 35°) **only while the band list is focused** (`onBandList`), `nil` otherwise. The horizontal-commit test runs before the vertical one, so within the overlap the items win. *Why rightward-only:* leftward on the band rail is a no-op (nothing left of the rail), and biasing both directions would swallow a shallow up-**left** band move; scoping the widening to the into-items direction avoids that. *Alternative:* widen the whole horizontal axis symmetrically. Rejected — it regresses shallow up-left band switches for no benefit. *Alternative:* a per-quadrant wedge table. Rejected as over-built; one rightward override covers the only asymmetry the launcher needs.

## Risks / Trade-offs

- **Engage threshold vs. drift** — if `engage` is below the initial off-axis drift, the wrong axis can commit. → Anchor `engage` at/above the existing inner deadzone / a fraction of `step`, so commitment waits until the stroke is clearly past the noise; tune in-hand.
- **L-move re-commit jump** — switching axes could emit a multi-step jump if the new axis already has a large offset. → The **per-axis re-anchor** (D3) zeroes the new axis's offset on switch, so the first post-turn step is one step from center.
- **Hysteresis too low → flip-flop near the diagonal** — incidental drift re-commits back and forth. → `recommitHysteresis` sits above hold jitter; the wedge already suppresses near-diagonal commits.
- **Absolute position-tracking interaction** — the frozen axis must HOLD, not snap back; the bug would be feeding it zero. → D2 explicitly *skips the feed* for the frozen axis; covered by the "frozen, not pulled back" test.
- **Files depth (out-and-back) regression** — the lock must not turn a deliberate one-folder drill into a no-op. → The depth axis is fed whenever horizontal is committed; the lock only changes *when* it's fed, not the out-and-back step rule. Existing `FilesDrillRecognizerTests` stay green.
- **Feel unspecifiable up front** — wedge and hysteresis are pure feel. → Ship as tunables with defaults; iterate on a stable-signed build (agent can't sign).

## Migration Plan

Additive and behind the existing launcher opt-in; the lock is opt-in per navigator (off elsewhere), so default behavior changes only for the launcher and Files navigators. New tunables default in (no data migration). **Rollback** is disabling the lock flag (navigation reverts to dual-axis feed) or reverting the change. Verify the arbiter (wedge commit, freeze-not-pull, ambiguous no-commit, hysteresis re-commit + per-axis re-anchor, re-arm on `reanchor`) via `swift build` / `swift test` (`PositionalNavigatorTests`); existing recognizer / launcher / Files-drill tests stay green; compile-check the MLX-linked app via `xcodebuild`; in-hand feel tuning on a stable-signed build (user-run). Update `CLAUDE.md`'s positional landmines (axis-lock: one axis per stroke, wedge + hysteresis re-commit, per-axis re-anchor).

## Open Questions

- **Wedge expressed as a ratio or a half-angle?** A ratio (`dominant ≥ k·other`) is cheapest; a half-angle is more intuitive in the UI (and the preview draws an angle). Likely store an angle, convert to a ratio internally. Resolve when wiring the tunable + preview.
- **`engage` threshold source** — reuse `positionalInnerDeadzone`, derive from `step`, or a dedicated tunable? Prefer reusing the deadzone to avoid yet another slider; confirm in-hand.
- **Extend to the media player?** Out-and-back both axes — the lock would prevent changing volume while seeking. Plausibly desirable, but out of scope; flagged as a follow-up.
