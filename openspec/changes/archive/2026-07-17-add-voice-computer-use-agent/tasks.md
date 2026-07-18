# Tasks: add-voice-computer-use-agent

## 1. Runtime audio seam (v4+ foundation)

- [x] 1.1 Add `audio: [Data]` + `requiresAudio` to `LLMRequest`/`LLMChatRequest` (defaults keep every call site compiling); thread `.audio` through required-modality derivation in the executor path
- [x] 1.2 Enforce the refusal contract: `StubLLMRuntime` (and a doc note for `GemmaMLXRuntime`) reject non-empty `audio` with `unsupportedModality(.audio)`; unit tests for select-for-audio, refusal, and empty-audio-changes-nothing

## 2. Voice foundation (MLX-free Core)

- [x] 2.1 `VoiceError` taxonomy (`micDenied`, `speechUnavailable`, `osTooOld`, `captureFailed`, `synthesisFailed`) + registration in `AIError.message(for:)`
- [x] 2.2 `SpeechTranscribing` + `SpeechSynthesizing` seams; `StubTranscriber` (scripted partials/final, cancellation-aware) + `StubSynthesizer` (records utterances, fake completion)
- [x] 2.3 `SentenceChunker` (pure): sentence-boundary + max-length + final flush; code-fence flattening ("code block, N lines"); unit tests
- [x] 2.4 `VoiceTurnModel` (pure, time-as-input): idle/listening/transcribing/thinking/speaking + barge-in from thinking/speaking; effects (`startCapture`/`stopCapture`/`sendTurn`/`speak`/`stopSpeaking`/`cancelTurn`); drop-late-tokens rule; full transition test matrix
- [x] 2.5 `VoiceSessionController` (@MainActor): executes effects through the seams, binds a turn to the existing chat/engine path (`.response` tokens → chunker → synthesizer), cancellation as discard; integration tests against stubs
- [x] 2.6 Voice session publishes into `QuiescenceSnapshot.foregroundSessionActive` (the OR-shaped flag) + test

## 3. STT/TTS conformers + push-to-talk (app-visible glue)

- [x] 3.1 `AVSpeechSynthesizer` conformer (macOS 15-safe): utterance queueing, stop, finished callbacks
- [x] 3.2 `SpeechAnalyzerTranscriber` `@available(macOS 26)`: AVAudioEngine voice-processing input → SpeechAnalyzer/SpeechTranscriber async stream; factory returns nil pre-26 → `VoiceError.osTooOld`
- [x] 3.3 Mic authorization flow: lazy request on first PTT press; denial → `VoiceError.micDenied` card with Settings deep link; plist usage strings added to the app bundle (build script/Info.plist)
- [x] 3.4 PTT trigger: configurable hold-key (default Right Option) via the existing event-tap path + press-and-hold mic button surface; press = `pttDown`, release = `pttUp`; press during thinking/speaking = barge-in

## 4. AX read/act layer (MLX-free Core)

- [x] 4.1 `AXActionError` taxonomy + `AIError` registration
- [x] 4.2 `AXWindowSnapshot` value model: text blocks + `AXElementRef` list (stable hash IDs: role+label+path), actionability flags, `truncated` flag; per-window epoch bookkeeping
- [x] 4.3 `AXWindowReader` boundary (AXUIElement, off-main, timeout-guarded, depth/count-bounded); pure snapshot-building logic separated so tests feed fake trees
- [x] 4.4 Act primitives: `press(elementID)`, `setValue(elementID, value)`, `typeText(elementID?, text, submit)` — resolve against the epoch snapshot (stale → `staleElement`), tagged-source synthetic keys for typing
- [x] 4.5 Verify-after-act inside each primitive (re-read affected subtree, `verified` + new value in the result; unverified → failure); tests over fake trees

## 5. Tools + speak-last-response

- [x] 5.1 `ComputerUseToolContributor`: `read_window` (.auto), `focus_window` (.auto, via `raiseCommitted`), `click_element` (.confirm), `type_text` (.confirm) — schemas with element IDs only (no coordinates); flag-gated live
- [x] 5.2 `VoiceToolContributor`: `speak` (.auto) + `set_auto_mode` (.confirm on, .auto off)
- [x] 5.3 Routing/candidate keywords for all new tools; tests: hallucinated element degrades cleanly, off-flag means absent from candidates
- [x] 5.4 Speak-last-response command in the catalog: frontmost/named window resolve → AX read → tail extraction via the summarize subagent → speak; works with voice opt-in off; bounded failure card when unreadable

## 6. Auto mode + budgets + human-abort arbitration

- [x] 6.1 `AgentConversation.autoApprove` (persisted, default false); approval gate consults it; enabling via gate-protected `set_auto_mode(on)`, initial-command intent, and a surface toggle; instant revoke
- [x] 6.2 Narration of auto-executed acts: step summaries stream to the visible list and to `speak` when voice is active
- [x] 6.3 `LoopBudget` in `AgentLoop`: per-step timeout race (default 30 s, settings-fed) → `.failed("timed out")`; per-turn deadline (default 180 s) → cap-reached fallback with honest partial summary; cancellation stays a discard; tests with fake slow tools
- [x] 6.4 `AgentActionArbiter`: `isActing` scope, tagged `CGEventSource` for synthetic keys, event-tap ignore rule, any-human-touch abort wired from the touch stream; visible "agent has the wheel" indicator (bounded pill)

## 7. Wiring + settings + Hub

- [x] 7.1 `AppSettings`: `voiceConversationEnabled` (default off), `computerUseEnabled` (default off), `voicePTTKey`, budget/timeout tunables; reset + persistence
- [x] 7.2 Hub rows with cost disclosure (mic grant; "the agent can click and type"); macOS-26 gate messaging on the voice toggle
- [x] 7.3 `AppCoordinator` composition: controller construction, contributor registration, PTT tap wiring, arbitration hookup, voice-session quiescence closure
- [x] 7.4 Conformer composition: the coordinator (the composition root) builds the Speech conformers directly — Core hosts them, so a cross-target injection enum would be a dead seam and was deliberately NOT kept (the controller's closure seams are the test injection points)

## 8. Verification

- [x] 8.1 `swift build` && `swift test` green (all Core logic incl. stubs); `xcodebuild` compile-verify for the app target
- [x] 8.2 Full-suite regression pass (no existing behavior change with both flags off)
- [x] 8.3 Manual signed-build checklist for the user (mic prompt, PTT feel, barge-in, AX on Terminal/Chrome, auto-mode session, abort-by-touch)
