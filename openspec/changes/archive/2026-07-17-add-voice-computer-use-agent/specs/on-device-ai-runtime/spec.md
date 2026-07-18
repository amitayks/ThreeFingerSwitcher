# Delta: on-device-ai-runtime — add-voice-computer-use-agent

## ADDED Requirements

### Requirement: Audio input is carried on the request seam and honestly refused until served
`LLMRequest` and `LLMChatRequest` SHALL carry an `audio` input (encoded audio byte payloads, defaulting to empty) alongside `images`, with a `requiresAudio` derivation, and capability selection SHALL treat a non-empty `audio` as requiring the `.audio` modality through the SAME `selectModel(requiring:)` path as vision. Until a conformer actually serves audio, every runtime — including the stub — SHALL REJECT a non-empty `audio` request with `unsupportedModality(.audio)`: the seam is statically typed and carried end-to-end, and its unimplemented half is an explicit, tested refusal, never a silently-ignored field. (This is the v4+ foundation for direct audio-in Gemma via the vendored audio tower; wiring the tower is a separate change.)

#### Scenario: Audio requests select for the audio capability
- **WHEN** a request carries non-empty audio and model selection runs
- **THEN** only descriptors advertising `.audio` satisfy it, and `RuntimeError.unavailable` is reported when none does

#### Scenario: A non-audio runtime refuses rather than ignores
- **WHEN** a request with non-empty audio reaches a runtime that does not serve audio (including the test stub)
- **THEN** it fails with `unsupportedModality(.audio)` — the audio bytes are never silently dropped

#### Scenario: Empty audio changes nothing
- **WHEN** requests carry the default empty audio
- **THEN** behavior is byte-for-byte identical to before the field existed (text and vision paths unaffected)
