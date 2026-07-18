# Delta: voice-conversation — voice-double-tap-dwell-trigger

## MODIFIED Requirements

### Requirement: Push-to-talk voice input, never always-listening
The system SHALL capture voice ONLY while the push-to-talk trigger is engaged (the configurable hold-key gesture, default Right Option, or the press-and-hold mic button). The microphone SHALL open on engagement and close on release — there SHALL be NO wake word, NO always-on capture, and NO voice-activity-triggered listening. The feature SHALL be a separate opt-in (default OFF) under the AI master gate, and microphone authorization SHALL be requested lazily on the FIRST actual engagement (never at enable time). A denied authorization SHALL surface as a bounded, non-blocking failure card with a System Settings link — never an app-modal alert, never a crash.

**The hold-key trigger SHALL be double-tap-then-hold** (the macOS dictation idiom): a first click of the key (down and up, each within the tap window, ~0.3 s), a second press within the gap window (~0.3 s), HELD past the dwell (~0.15 s) — capture begins at dwell-elapsed and release sends. A double-tap WITHOUT the dwell SHALL be a complete no-op. A LONG SINGLE hold SHALL be a complete no-op (plain modifier use — special-character typing is untouched). Any OTHER key going down at any pre-capture stage SHALL cancel the gesture — a typing chord can never trigger voice — and the capture stack SHALL NOT be touched, nor the microphone opened, until dwell-elapsed. The observation SHALL be passive (no event consumed or delayed). Barge-in while the assistant thinks or speaks SHALL use the SAME gesture.

#### Scenario: Double-tap-and-hold talks; release sends
- **WHEN** the user clicks the trigger key, presses it again within the gap, holds past the dwell, speaks, and releases
- **THEN** capture runs only from dwell-elapsed to release, the transcript is finalized on release, and the finalized text is sent as the agent turn

#### Scenario: No capture outside the gesture
- **WHEN** the voice feature is enabled but the gesture has not completed its dwell
- **THEN** no audio session is active and no audio is read

#### Scenario: A typing chord never triggers voice
- **WHEN** the user types any chord using the trigger modifier (⌥⌫, ⌥→, option-symbols) at any speed
- **THEN** the gesture cancels, the capture stack is never started, the mic never opens, and the chord reaches the target app unmodified

#### Scenario: A long single hold is plain modifier use
- **WHEN** the user presses and holds the trigger key once (no second tap)
- **THEN** nothing happens — no capture, no timers left pending after release

#### Scenario: A bare double-tap is a no-op
- **WHEN** the user double-taps the trigger key without holding the second press past the dwell
- **THEN** nothing happens

#### Scenario: Denied mic permission is a clean, recoverable failure
- **WHEN** the user denies microphone authorization on first use
- **THEN** a bounded non-blocking card explains it with a Settings link, the feature stays off-path, and nothing crashes or blocks
