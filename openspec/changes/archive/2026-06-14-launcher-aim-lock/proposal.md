## Why

The anchored-positional navigator feeds **both** axes every frame from one diagonal offset, so a finger stroke that drifts off-axis moves the selection on **both** axes at once. Nobody strokes a trackpad on a perfect XY line: arcing up-and-right to enter a band's items also switches the band, and drifting down-and-left to return to the rail also jumps off the band you came from. This is the classic mega-menu "diagonal aim" problem — the fix is the well-known **menu-aim triangle** (here: an angular **directional axis-lock**, the same trick iOS/browsers use for scroll-direction locking) so an angled stroke commits to **one** axis and forgives the perpendicular drift.

## What Changes

- **Directional axis-lock in the positional core.** `PositionalNavigator.feed` gains an opt-in **axis-commit arbiter**: a stroke commits to whichever axis *clearly* dominates (a wedge half-angle ≈ 30°; near 45° it waits until one wins), then **freezes** the other axis (by not feeding it — feeding `0` under position-tracking would actively pull the selection back). A clearly-perpendicular turn past a **hysteresis** margin re-commits to the other axis, per-axis re-anchoring it for a clean **L-shaped** move (right, then down) instead of diagonal mush. The lock re-arms to none on settle (return to the deadzone) and on every `reanchor`.
- **Applied globally to the launcher and the Files band.** Both adopt the lock — the launcher (both axes position-tracking) and the Files drill (vertical highlight position-tracking, horizontal depth out-and-back); the lock therefore must work when one axis is out-and-back. The rail↔grid crossing fix falls out for free: a horizontal-dominant crossing freezes vertical, so you enter *this* band's items without switching bands, and you return to the **same** band icon you came from (the model already preserves `currentBand` across a horizontal crossing — only the spurious vertical step needed suppressing).
- **A wider, directional crossing wedge (refinement).** While on the band rail, the **rightward (into-items)** direction gets a wider acceptance cone than band switching, so an up/down-and-right stroke **enters the items** instead of switching a band — the "bigger crossing triangle." Only a clearly-vertical stroke still switches bands; off the rail the wedge is symmetric again.
- **New feel tunables** for the wedge (commit ratio / angle), the **crossing wedge** (wider into-items angle), and the re-commit hysteresis, persisted and live-applied, surfaced on the Hub Launcher page; the live trackpad preview draws the **wedge cones** (with the wider rightward crossing cone) so the abstract values are visible.
- **Untouched:** the opening/activation odometer fling, the three-finger window switcher, and the media player's out-and-back transport (a possible follow-up, not in scope).

## Capabilities

### New Capabilities
<!-- None — this refines the existing positional-navigation behavior rather than adding a new domain. -->

### Modified Capabilities
- `gesture-recognition`: the post-activation positional navigator commits a stroke to a single dominant axis (angular wedge), freezes the perpendicular axis, re-commits on a clearly-perpendicular turn (hysteresis + per-axis re-anchor), and re-arms on settle/re-anchor; applied to both the launcher and the Files-drill navigators (including the Files depth axis, which is out-and-back).
- `launcher-overlay`: the rail↔grid crossing and grid-internal navigation become single-axis (a diagonal stroke no longer switches a band while crossing, nor jumps off the origin band on return); the held-in-zone auto-repeat still drives off whichever axis is committed.
- `tunable-settings`: add the axis-lock tunables (wedge commit ratio/angle, re-commit hysteresis) — persisted, live-applied.
- `configuration-hub`: surface the axis-lock tunables on the Hub Launcher page and draw the committed-axis wedge in the live trackpad preview.

## Impact

- **Core (`Gesture/PositionalNavigator.swift`):** add the axis-commit arbiter (state + wedge/hysteresis params) to `PositionalNavigator`; `feed` routes the offset to the committed axis only and per-axis re-anchors on re-commit. Pure, no new dependencies.
- **Recognizer (`Gesture/GestureRecognizer.swift`):** enable the lock on `launcherNav` and `filesNav` and feed the new tunables; opening/activation and the window switcher stay on the odometer.
- **Settings (`Settings/AppSettings.swift`):** new `positional*` tunables (`Defaults` + `Keys` + `didSet` persist + reset).
- **Hub (`Hub/HubFeaturePages.swift`, `Hub/PositionalTrackpadPreview.swift`):** Launcher-page controls for the new tunables and a committed-axis wedge in the preview.
- **Verification:** `PositionalNavigatorTests` covers wedge commit, freeze-not-pull, hysteresis re-commit + per-axis re-anchor, and re-arm on `reanchor`; existing recognizer/launcher tests stay green. Pure-Core, so `swift build` / `swift test`; the MLX/`GemmaRuntime` split is untouched.
