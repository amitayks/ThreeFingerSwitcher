## ADDED Requirements

### Requirement: Axis-lock controls and committed-axis wedge in the trackpad preview

The Hub Launcher page SHALL expose the directional axis-lock tunables — the **commit wedge**, the **crossing wedge** (the wider into-items acceptance), and the **re-commit hysteresis** — as controls, and the live trackpad preview SHALL visualize the lock.

While the preview is visible and live frames are arriving, it SHALL draw the **commit wedge** around the anchored center (the angular region within which a stroke commits to an axis, so the diagonal "no-commit" zone is visible), with the **rightward (into-items) cone drawn wider** per the crossing wedge, and the diagonal "no-commit" gaps visible. Adjusting any tunable SHALL update the preview immediately (the same values drive the preview and the live navigation). When no live touch is available, the preview SHALL still show the wedge at the neutral resting center, consistent with the existing positional preview's graceful empty state.

#### Scenario: The commit wedge is drawn around the center

- **WHEN** the Launcher page's trackpad preview is visible
- **THEN** the wedge (and the ambiguous diagonal no-commit region) is drawn around the anchored center, scaled to the current commit-wedge tunable

#### Scenario: The into-items cone is drawn wider

- **WHEN** the crossing wedge is larger than the commit wedge
- **THEN** the rightward (into-items) cone is drawn wider than the other cones, so the bigger crossing triangle is visible

#### Scenario: Axis-lock tunables drive the preview live

- **WHEN** the user changes the commit wedge, the crossing wedge, or the re-commit hysteresis
- **THEN** the preview's wedge cones update immediately so the slider value is seen as a physical angular zone
