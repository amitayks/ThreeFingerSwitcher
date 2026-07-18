# Delta: voice-conversation — fix-ptt-chord-collision

## MODIFIED Requirements

### Requirement: Push-to-talk voice input, never always-listening
The system SHALL capture voice ONLY while the push-to-talk trigger is held (the configurable hold-key, default Right Option, or the press-and-hold mic button). The microphone SHALL open on press and close on release — there SHALL be NO wake word, NO always-on capture, and NO voice-activity-triggered listening. The feature SHALL be a separate opt-in (default OFF) under the AI master gate, and microphone authorization SHALL be requested lazily on the FIRST actual push-to-talk press (never at enable time). A denied authorization SHALL surface as a bounded, non-blocking failure card with a System Settings link — never an app-modal alert, never a crash.

**The hold-key trigger SHALL have hold-intent semantics.** The modifier going down ARMS a short window (~180 ms); push-to-talk begins only when the window elapses with the modifier still held ALONE. Any other key going down during the window SHALL cancel the arming — a typing chord (⌥⌫, ⌥→, option-symbols) is typing, never talk — and a release within the window SHALL be a complete no-op. The capture stack (audio engine, voice processing, speech analyzer) SHALL NOT be touched, and the microphone SHALL NOT open, for a chord or a sub-window tap. The chord observation SHALL be passive (no event is consumed or delayed).

#### Scenario: Mic opens and closes with the trigger
- **WHEN** the user presses and holds the push-to-talk trigger alone, past the arming window, speaks, and releases
- **THEN** capture runs only between arming and release, the transcript is finalized on release, and the finalized text is sent as the agent turn

#### Scenario: No capture outside the hold
- **WHEN** the voice feature is enabled but no trigger is held
- **THEN** no audio session is active and no audio is read

#### Scenario: A typing chord never triggers voice
- **WHEN** the user types ⌥⌫ (or any other-key chord with the push-to-talk modifier) at any speed
- **THEN** the arming is cancelled, the capture stack is never started, the mic never opens, and the chord reaches the target app unmodified

#### Scenario: A stray tap is a no-op
- **WHEN** the user taps and releases the push-to-talk key within the arming window
- **THEN** nothing happens — no capture start, no teardown, no failure card

#### Scenario: Denied mic permission is a clean, recoverable failure
- **WHEN** the user denies microphone authorization on first use
- **THEN** a bounded non-blocking card explains it with a Settings link, the feature stays off-path, and nothing crashes or blocks
