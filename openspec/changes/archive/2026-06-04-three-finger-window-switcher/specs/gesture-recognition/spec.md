## ADDED Requirements

### Requirement: Three-finger gesture detection
The system SHALL begin tracking a candidate gesture only when exactly three fingers are active, and SHALL cancel the candidate if a fourth finger lands.

#### Scenario: Exactly three fingers starts tracking
- **WHEN** the active finger count becomes exactly 3
- **THEN** the recognizer captures the starting centroid and begins tracking displacement

#### Scenario: Fourth finger cancels
- **WHEN** a fourth finger lands during a candidate or active gesture
- **THEN** the recognizer cancels without committing and hides any overlay

### Requirement: Axis-lock yields vertical to the OS
The system SHALL determine gesture axis from accumulated displacement and SHALL yield (take no action) when vertical motion dominates, so Mission Control / App Exposé are handled by the OS.

#### Scenario: Vertical motion is ignored
- **WHEN** accumulated |Δy| dominates |Δx| beyond the configured axis-lock ratio before activation
- **THEN** the recognizer treats the gesture as vertical and never shows the overlay

#### Scenario: Horizontal motion is captured
- **WHEN** accumulated |Δx| dominates |Δy| beyond the axis-lock ratio
- **THEN** the recognizer locks to the horizontal axis for the remainder of the gesture

### Requirement: Activation threshold
The system SHALL not show the switcher until horizontal centroid displacement crosses the configured activation threshold, preventing accidental triggering.

#### Scenario: Below threshold shows nothing
- **WHEN** three fingers move horizontally less than the activation threshold and then lift
- **THEN** no overlay is shown and no window is raised

#### Scenario: Crossing threshold activates
- **WHEN** horizontal centroid displacement crosses the activation threshold
- **THEN** the overlay is shown and live scrubbing begins

### Requirement: Step accumulation with carry
The system SHALL move the selection by one window each time accumulated horizontal centroid travel reaches the configured step distance, carrying the remainder so scrubbing feels continuous, and SHALL step backward when the direction reverses.

#### Scenario: One step per step-distance
- **WHEN** accumulated horizontal travel since the last step reaches the step distance in the locked direction
- **THEN** the selection index advances by one and the step distance is subtracted from the accumulator (remainder retained)

#### Scenario: Reversal steps back
- **WHEN** the fingers reverse horizontal direction by at least one step distance
- **THEN** the selection index moves back by one

#### Scenario: End-of-list behavior honors setting
- **WHEN** the selection reaches an end of the window list
- **THEN** it wraps to the other end if wrap is enabled, otherwise it clamps at the end

### Requirement: Live highlight, commit on lift
The system SHALL update only the highlighted selection during scrubbing and SHALL raise+focus the highlighted window only when the fingers lift (commit), and SHALL cancel without raising if the activation threshold was never crossed.

#### Scenario: Scrubbing only highlights
- **WHEN** the user scrubs while three fingers stay down
- **THEN** only the highlight moves and no window is raised yet

#### Scenario: Lift commits
- **WHEN** the fingers lift after the overlay was activated
- **THEN** the currently highlighted window is raised and focused and the overlay hides

#### Scenario: Cancel before activation
- **WHEN** the fingers lift before the activation threshold was crossed
- **THEN** nothing is raised and no overlay was shown
