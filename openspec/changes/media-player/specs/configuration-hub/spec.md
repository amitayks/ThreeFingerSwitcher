## ADDED Requirements

### Requirement: Player page in the Hub sidebar
The configuration Hub SHALL include a **Player** page in its grouped sidebar that hosts the built-in media player's controls: the player opt-in, per-media-kind default-open toggles (video, audio, image), the default playback engine selection (AVFoundation or libmpv), the seek and volume step increments, and the resume behavior (the resume threshold / near-end margin). The page SHALL follow the Hub's Liquid-Glass presentation and persistence conventions, reflect the live persisted values, and apply changes immediately. The Overview landing page's feature master toggles SHALL include the player opt-in consistent with the other optional features.

#### Scenario: Player page hosts the player controls
- **WHEN** the user opens the Player page of the Hub
- **THEN** they see and can change the player opt-in, the per-kind default-open toggles, the default engine, the seek/volume increments, and the resume behavior, reflecting the persisted values

#### Scenario: Changes apply immediately and persist
- **WHEN** the user changes a player control on the Player page
- **THEN** the change applies immediately to subsequent opens and is written to persistent settings

#### Scenario: Player opt-in appears on the Overview master toggles
- **WHEN** the user views the Hub Overview landing page
- **THEN** the built-in player opt-in is present among the feature master toggles, consistent with the other optional features
