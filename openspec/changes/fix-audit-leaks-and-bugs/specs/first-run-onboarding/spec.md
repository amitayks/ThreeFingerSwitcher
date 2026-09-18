## MODIFIED Requirements

### Requirement: The demo plays before anything is asked
Before requesting any permission, the wizard SHALL present an interactive demo built from the product's own overlay presentation (the switcher strip rendered from sample data). The demo SHALL begin as a self-playing scripted scene, and WHEN live multitouch frames with three or more contacts are available it SHALL hand control to the user's actual fingers (tracking fingertips and scrubbing the strip from their motion). A live touch SHALL count as a scrub only when the fingers actually travel — the highlight reaches a column other than the one the fingers landed on — never merely because the landing column differs from where the scripted loop left the highlight; a lift after a real scrub advances the act, a lift without one leaves the documented fallback in place. The demo act SHALL function fully when no live touch data is available.

#### Scenario: Demo runs with zero permissions
- **WHEN** the demo act is shown on a machine with no permissions granted
- **THEN** the simulated switcher strip animates from sample data without requesting anything

#### Scenario: Real fingers take over
- **WHEN** the user places three fingers on the trackpad during the demo act and touch frames are flowing
- **THEN** the scripted loop yields and the strip scrubs under the user's own finger motion

#### Scenario: A touchdown alone is not a scrub
- **WHEN** the user lands three fingers at a column different from the scripted highlight and lifts without moving
- **THEN** the act does not treat that as a completed scrub

#### Scenario: No touch data degrades to cinema
- **WHEN** no multitouch frames are available (no trackpad, or the read is unavailable)
- **THEN** the demo continues as the scripted scene without error or a dead-end state
