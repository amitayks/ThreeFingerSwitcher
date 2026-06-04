## ADDED Requirements

### Requirement: Passive raw multitouch stream
The system SHALL read raw global trackpad touches via the Kyome OpenMultitouchSupport package without consuming or blocking any input event, so that the OS continues to receive every touch.

#### Scenario: Reading does not block OS gestures
- **WHEN** the touch engine is listening and the user performs a three-finger swipe up
- **THEN** the OS still triggers Mission Control
- **AND** the touch engine also observes the same touches

#### Scenario: Start and stop listening
- **WHEN** the engine is told to start listening
- **THEN** touch frames begin flowing
- **AND** when told to stop, no further frames are delivered

### Requirement: Derived finger count
The system SHALL derive the number of fingers currently down by tracking each touch `id` and its `state` lifecycle, since the package does not report a finger count directly.

#### Scenario: Three fingers down reported as count three
- **WHEN** three distinct touch ids are in an active (touching/making) state
- **THEN** the engine reports an active finger count of exactly 3

#### Scenario: Finger lift decrements count
- **WHEN** a tracked touch transitions to a breaking/leaving/not-touching state
- **THEN** its id is removed from the active set and the reported count decreases accordingly

### Requirement: Derived per-finger and centroid velocity
The system SHALL compute velocity from the change in normalized position over the change in timestamp, since the package does not report velocity, and SHALL expose a smoothed centroid position and velocity for the active touches.

#### Scenario: Velocity computed from position deltas
- **WHEN** a tracked touch moves between consecutive frames
- **THEN** the engine computes its velocity as Δposition / Δtime

#### Scenario: Smoothed centroid exposed
- **WHEN** multiple fingers are active
- **THEN** the engine exposes the mean (centroid) position and an EMA-smoothed centroid velocity

### Requirement: Normalized touch coordinates
The system SHALL treat touch positions as normalized device coordinates in the range 0..1 for both axes, so downstream thresholds are expressed in normalized units.

#### Scenario: Coordinates within unit range
- **WHEN** a touch frame is delivered
- **THEN** each touch position x and y are within 0..1
