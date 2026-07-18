# voice-conversation Specification (delta: add-voice-computer-use-agent)

## ADDED Requirements

### Requirement: Push-to-talk voice input, never always-listening
The system SHALL capture voice ONLY while the push-to-talk trigger is held (the configurable hold-key, default Right Option, or the press-and-hold mic button). The microphone SHALL open on press and close on release — there SHALL be NO wake word, NO always-on capture, and NO voice-activity-triggered listening. The feature SHALL be a separate opt-in (default OFF) under the AI master gate, and microphone authorization SHALL be requested lazily on the FIRST actual push-to-talk press (never at enable time). A denied authorization SHALL surface as a bounded, non-blocking failure card with a System Settings link — never an app-modal alert, never a crash.

#### Scenario: Mic opens and closes with the trigger
- **WHEN** the user presses and holds the push-to-talk trigger, speaks, and releases
- **THEN** capture runs only between press and release, the transcript is finalized on release, and the finalized text is sent as the agent turn

#### Scenario: No capture outside the hold
- **WHEN** the voice feature is enabled but no trigger is held
- **THEN** no audio session is active and no audio is read

#### Scenario: Denied mic permission is a clean, recoverable failure
- **WHEN** the user denies microphone authorization on first use
- **THEN** a bounded non-blocking card explains it with a Settings link, the feature stays off-path, and nothing crashes or blocks

### Requirement: On-device transcription behind a seam, macOS 26-gated
Transcription SHALL run fully on-device via the injected `SpeechTranscribing` seam. The real conformer SHALL wrap Apple `SpeechAnalyzer`/`SpeechTranscriber` and SHALL be gated `@available(macOS 26)`; on older macOS the factory SHALL resolve to nil and the voice feature SHALL read as unavailable with a clean "requires macOS 26" reason (the platform floor does not rise). Core SHALL ship a scripted stub conformer so every voice behavior verifies under `swift test` with no Speech framework involvement.

#### Scenario: Older macOS reports unavailable, never crashes
- **WHEN** the voice opt-in is viewed on macOS earlier than 26
- **THEN** the toggle is disabled with a "requires macOS 26" disclosure and no Speech API is touched

#### Scenario: Voice logic verifies with the stub
- **WHEN** the Core test suite runs
- **THEN** the full turn lifecycle (capture → transcript → turn → spoken reply → barge-in) executes against the stub transcriber/synthesizer deterministically

### Requirement: Sentence-chunked spoken replies from the streaming turn
The spoken reply SHALL be produced by chunking the existing `.response`-channel token stream at sentence boundaries and feeding each closed chunk to the `SpeechSynthesizing` seam as it closes — the first sentence SHALL be speakable while the remainder is still generating. Thinking-channel tokens SHALL NEVER be spoken. Code blocks SHALL be summarized in speech (e.g. "code block, N lines"), not read symbol-by-symbol. The visible canvas/notch transcript SHALL remain the full, unmodified text.

#### Scenario: First sentence speaks during generation
- **WHEN** a voice turn's reply streams
- **THEN** the first completed sentence begins speaking before the stream finishes, and remaining sentences queue in order

#### Scenario: Thinking is never spoken
- **WHEN** a reply streams with reasoning enabled
- **THEN** only `.response`-channel text reaches the synthesizer

### Requirement: Barge-in stops speech and cancels the turn as a discard
While the agent is thinking or speaking, a new push-to-talk press SHALL barge in: text-to-speech output stops, any in-flight generation is cancelled through the existing cancellable-generation path (a DISCARD, never a failure state), and listening begins immediately — a fluent correction, not an error. Tokens arriving after a barge-in SHALL be dropped, not spoken. A human trackpad touch during agent action SHALL abort identically (the computer-use arbitration requirement).

#### Scenario: Barge-in mid-reply
- **WHEN** the user presses push-to-talk while the reply is being spoken
- **THEN** speech stops immediately, the generation is cancelled as a discard, late tokens are not spoken, and the mic is live

#### Scenario: The voice turn lifecycle is pure and tested
- **WHEN** the voice-turn state machine is driven in tests with fake timestamps through idle→listening→transcribing→thinking→speaking and a barge-in at each interruptible state
- **THEN** every transition and emitted effect matches the specified lifecycle deterministically

### Requirement: A voice session is a foreground conversational surface
An open voice conversation SHALL count as `foregroundSessionActive` in the model-eviction quiescence snapshot (the OR-shaped flag landed by `model-idle-ttl-and-memory-pressure`), so idle-TTL and warning-pressure eviction never unload the model between spoken turns of a live dialogue.

#### Scenario: No eviction mid-dialogue
- **WHEN** a voice conversation is open and idle between spoken turns past the idle TTL
- **THEN** the TTL trigger does not evict the resident model

### Requirement: Speak-last-response works without the microphone
A "speak the last response" command SHALL exist independently of the voice opt-in's mic capture: it resolves the target window through the switcher's own enumeration, reads the window text via the accessibility reader, extracts the relevant tail (e.g. the assistant's final reply in a terminal transcript), and speaks it through the synthesizer seam. It SHALL require no microphone, no new permission, and no open conversation.

#### Scenario: Read Claude's last response aloud
- **WHEN** the user fires speak-last-response with a terminal window frontmost showing an assistant transcript
- **THEN** the window's text is read via AX, the final assistant reply is extracted, and it is spoken — with a bounded, non-blocking failure card if the window cannot be read

### Requirement: Voice errors join the single error taxonomy
Voice failures SHALL be classified into a `VoiceError` taxonomy (`LocalizedError`, parallel to `FileActionError`) — mic denied, speech unavailable, OS too old, capture failure — mapped at the boundary where AVFoundation/Speech errors cross into app code, routed through the single `AIError.message(for:)` translator, and surfaced bounded + non-blocking. Raw vendor error text SHALL appear only in opt-in details, never in a headline.

#### Scenario: A capture failure surfaces cleanly
- **WHEN** the audio engine fails to start mid-press
- **THEN** the user sees a clean headline card (details behind a disclosure), the turn is not sent, and the app remains responsive
