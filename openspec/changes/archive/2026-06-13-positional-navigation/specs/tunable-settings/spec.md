## ADDED Requirements

### Requirement: Positional navigation tunables

The system SHALL expose tunable parameters, with sensible defaults, for the anchored-positional navigation model and its eased auto-repeat, all persisted and live-applied:

- a **footprint→deflection scale** factor (how far the centroid must move relative to the fingers' landing footprint), with a fixed fallback scale used when the footprint is unavailable;
- an **item step** and a (coarser) **band step** — the offset per position-step for item movement vs. band switching;
- a **padding-box size** (`radius`) — how far the position-tracking box extends from center before the margin accelerates (the "make the padding bigger/smaller" control);
- a fixed **edge-margin band** width at the trackpad border that always accelerates (the padding squeezes against it near the edges; `0` disables it);
- an **initial repeat delay** (the gap before the second step once an offset is held in the margin), a **repeat floor** (the fastest interval the curve approaches), and an **acceleration curve** / ramp (how the interval eases from the initial delay toward the floor over dwell duration — a smooth ramp, never an abrupt slow→fast jump);
- a **back-off to stop** distance — how far the offset may retreat from its furthest held point before the center snaps onto the finger and the auto-repeat stops.

These tunables SHALL be surfaced on the Hub Launcher page and SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Defaults give a controllable, eased feel on first run

- **WHEN** the app runs for the first time
- **THEN** the positional box, edge band, and eased repeat curve have sensible defaults so navigation is usable without configuration — the cursor tracks the finger inside the box, holding past it accelerates smoothly toward the floor, and a small move back re-centers and stops

#### Scenario: Changing the padding size changes how far you step before accelerating

- **WHEN** the user increases the padding-box size
- **THEN** more offset from center is available for precise stepping before the margin starts accelerating

#### Scenario: Changing the repeat floor changes top speed

- **WHEN** the user lowers the repeat floor
- **THEN** a held offset reaches a faster maximum auto-repeat rate after dwelling

#### Scenario: Positional tunables persist and live-apply

- **WHEN** the user changes a positional tunable while the launcher opt-in is enabled
- **THEN** the new value is applied to the next navigation without restart and is retained across relaunch

## MODIFIED Requirements

### Requirement: Launcher tunables
The system SHALL expose tunable parameters for the launcher: a four-finger activation threshold (the opening fling), an item-step, a context-step, and a dwell-to-arm duration. The item-step and context-step SHALL parameterize the **positional position-step** (offset per step) for item movement versus band switching respectively (a coarser context step keeps band switching deliberate while item movement stays fine), rather than an odometer travel distance. All SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Dwell duration default is brief but deliberate
- **WHEN** the app runs for the first time
- **THEN** the dwell-to-arm duration defaults to a brief deliberate value (on the order of half a second), not a full second

#### Scenario: Changing dwell changes arm time
- **WHEN** the launcher opt-in is enabled and the user increases the dwell-to-arm duration
- **THEN** an item must be rested on longer before it arms

#### Scenario: Changing context-step changes band sensitivity
- **WHEN** the launcher opt-in is enabled and the user increases the context-step
- **THEN** more vertical offset is required to switch context bands

#### Scenario: Launcher tunables persist
- **WHEN** the user changes a launcher tunable and relaunches
- **THEN** the value is retained and applied when the opt-in is enabled
