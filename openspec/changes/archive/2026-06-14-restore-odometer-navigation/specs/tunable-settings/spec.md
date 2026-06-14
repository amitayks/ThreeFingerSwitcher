## MODIFIED Requirements

### Requirement: Launcher tunables
The system SHALL expose tunable parameters for the launcher: a four-finger activation threshold, an item-step distance, a context-step distance, and a dwell-to-arm duration. The item-step and context-step SHALL parameterize **accumulated travel distance** per step (odometer travel) for item movement versus band switching respectively (a coarser context step keeps band switching deliberate while item movement stays fine). All SHALL persist and appear in the Settings UI. These tunables SHALL take effect only while the launcher opt-in is enabled.

#### Scenario: Dwell duration default is brief but deliberate
- **WHEN** the app runs for the first time
- **THEN** the dwell-to-arm duration defaults to a brief deliberate value (on the order of half a second), not a full second

#### Scenario: Changing dwell changes arm time
- **WHEN** the launcher opt-in is enabled and the user increases the dwell-to-arm duration
- **THEN** an item must be rested on longer before it arms

#### Scenario: Changing context-step distance changes band sensitivity
- **WHEN** the launcher opt-in is enabled and the user increases the context-step distance
- **THEN** more vertical travel is required to switch context bands

#### Scenario: Launcher tunables persist
- **WHEN** the user changes a launcher tunable and relaunches
- **THEN** the value is retained and applied when the opt-in is enabled

## REMOVED Requirements

### Requirement: Positional navigation tunables
**Reason**: The anchored-positional navigation model and its eased auto-repeat are removed; their tunables (footprint→deflection scale + fixed fallback, padding-box radius, edge-margin band, initial repeat delay, repeat floor, acceleration curve, back-off-to-stop) no longer have anything to control.
**Migration**: The navigation feel is again governed by the **Launcher tunables** (item-step / context-step travel distances) plus the **edge-triggered auto-repeat** tunables (edge zone, base rate, acceleration, maximum rate) described in launcher-overlay. Persisted `positional*` keys are obsolete and SHALL be ignored on load (older settings still decode with the launcher opt-in unchanged).

### Requirement: Axis-lock tunables
**Reason**: The directional axis-lock is removed with the positional model; its commit wedge, crossing wedge, and re-commit hysteresis have nothing to tune.
**Migration**: None. The odometer accumulates both axes independently with no axis commitment. Persisted axis-lock keys are obsolete and SHALL be ignored on load.
