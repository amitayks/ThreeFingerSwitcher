## ADDED Requirements

### Requirement: Disable always tears down; wake retries on the opt-in
Disabling the switcher SHALL tear down every runtime component it owns (touch engine, scroll and keyboard taps, focus and MRU trackers, overlays, clipboard recorder) regardless of whether the trackpad is currently available. The sleep/wake handling SHALL be gated on the user's enable opt-in, not on trackpad availability, so a wake at which the trackpad was not yet re-attached is retried at the next wake rather than leaving the engine permanently stopped. The touch engine SHALL discard the single frame the input stream replays from before a restart.

#### Scenario: Toggle off after a trackpad-less wake
- **WHEN** the machine woke while the trackpad was unavailable and the user then turns the master toggle off
- **THEN** ⌘-Tab interception, scroll consumption, and clipboard recording all stop

#### Scenario: Trackpad returns at a later wake
- **WHEN** the trackpad was unavailable at one wake and present at the next
- **THEN** the touch engine restarts at that next wake without a manual toggle

#### Scenario: No phantom gesture after a restart
- **WHEN** the touch engine restarts after sleep or display sleep
- **THEN** the frame from before the restart is not fed to the recognizer
