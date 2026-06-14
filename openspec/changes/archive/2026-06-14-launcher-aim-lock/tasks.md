## 1. Core: axis-lock arbiter in PositionalNavigator

- [x] 1.1 Add an opt-in axis-lock to `PositionalNavigator` (a flag/mode + `committed ∈ {none, horizontal, vertical}` state, `commitWedge` ratio and `recommitHysteresis` params); default off so existing callers are unchanged.
- [x] 1.2 In `feed(centroid:)`, compute per-axis `|offset|` and arbitrate before feeding: `none` → commit only when one axis ≥ `engage` AND dominates the other by `commitWedge` (else commit to neither, emit nothing).
- [x] 1.3 When committed, feed ONLY the committed axis; do NOT feed the perpendicular axis (freeze its index — never feed it `0`). Return the committed axis's step + held sign; the frozen axis returns `0`/`0`.
- [x] 1.4 Re-commit on a deliberate turn (`perpendicular ≥ committed + recommitHysteresis`): switch `committed`, per-axis re-anchor the new axis (rebuild `PositionalAnchor` moving only that center component to the current centroid, reset that `AxisZone` + its `peak`), hold the other axis's index.
- [x] 1.5 Re-arm `committed = none` on settle (both offsets back inside the deadzone) and inside `reanchor(center:spread:)`.
- [x] 1.6 Choose the `engage` source (reuse the inner deadzone vs. derive from `step`) per design Open Question; keep it ≥ the existing noise floor.

## 2. Core: tests (PositionalNavigatorTests)

- [x] 2.1 Angled stroke commits to the dominant axis; perpendicular drift emits no step (both directions on both axes).
- [x] 2.2 Frozen perpendicular axis HOLDS its index (a non-zero held index is not stepped back when the other axis is committed).
- [x] 2.3 Ambiguous near-diagonal offset commits to neither axis (no step) until one dominates.
- [x] 2.4 Deliberate perpendicular turn re-commits with per-axis re-anchor → an L-move (no multi-step jump on the turn); the frozen axis's index is preserved.
- [x] 2.5 Settle to deadzone re-arms; `reanchor` re-arms and emits no step.
- [x] 2.6 Out-and-back axis participates: horizontal-dominant drill emits exactly one depth step and no highlight step (and vice-versa).

## 3. Recognizer wiring (GestureRecognizer)

- [x] 3.1 Enable the axis-lock on `launcherNav` (both position-tracking axes) and `filesNav` (position-tracking highlight + out-and-back depth); leave `playerNav` off.
- [x] 3.2 Feed the new tunables (`commitWedge`, `recommitHysteresis`) where each navigator is (re)built from settings, alongside the existing `edgeMargin`/`reArmBackoff` wiring.
- [x] 3.3 Confirm the crossing path: a horizontal-dominant stroke crosses rail↔grid with no vertical step; `currentBand` preserved on cross-back; a fresh vertical stroke after the cross switches bands. (No new band memory needed.)

## 4. Settings (AppSettings)

- [x] 4.1 Add `positionalCommitWedge` and `positionalRecommitHysteresis` (`Defaults` + `Keys` + `@Published` + `didSet` persist + load + `resetToDefaults`) with feel-tuned defaults (wedge ≈ 30° drift forgiveness; hysteresis above hold jitter).

## 5. Hub UI + live preview

- [x] 5.1 Add the wedge + hysteresis controls to the Hub Launcher page (`Hub/HubFeaturePages.swift`), grouped with the existing positional tunables.
- [x] 5.2 `PositionalTrackpadPreview`: draw the commit wedge (and the diagonal no-commit region) around the anchored center, and indicate the committed axis / frozen axis live; tunable changes update it immediately.

## 7. Refinement: wider directional crossing wedge (rail → items)

- [x] 7.1 Navigator: add `commitWedgeRightward: CGFloat?` — a wider horizontal-commit ratio applied ONLY to rightward strokes (`off.x > 0`); horizontal tested before vertical so the items win in any overlap; `nil` = symmetric.
- [x] 7.2 Recognizer: set `launcherNav.commitWedgeRightward` to the crossing ratio per-feed when `onBandList`, `nil` otherwise.
- [x] 7.3 Settings: add `positionalCrossingWedge` (degrees, default 55, wider than the base wedge) across Defaults/Keys/@Published/load/reset.
- [x] 7.4 Hub: add the "Into-items forgiveness" control; preview draws the rightward cone wider (`wedgeCones` rightHalfAngle).
- [x] 7.5 Tests: navigator (rightward widens / leftward keeps base) + recognizer (on the band rail an up-right stroke emits item steps, no context step).

## 6. Verify, docs, sync

- [x] 6.1 `swift build` + `swift test` green (new + existing recognizer / launcher / Files-drill tests); `xcodebuild` compile-check the app target.
- [x] 6.2 Update `CLAUDE.md` positional landmines: axis-lock = one axis per stroke (wedge gate), hysteresis re-commit with per-axis re-anchor, freeze-not-pull, opt-in per navigator (off for the player).
- [x] 6.3 `openspec validate launcher-aim-lock --strict`; run `/opsx:sync` to fold the deltas into the main specs after implementation.
