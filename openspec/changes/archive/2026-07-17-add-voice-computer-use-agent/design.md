# Design: add-voice-computer-use-agent

## Context

The agent substrate exists: `AgentLoop` (route → dispatch → feed-back, step-capped), `ToolRegistry` contributors, write-policy tiers + the foreground approval gate, cancellable streaming generation, hardened window raising (`WindowService` + SkyLight), AX-tree reading precedent (`AXDockReader`), screen/region capture, and the parked-session engine with `isTurnInFlight`. The TTL change just landed `QuiescenceSnapshot` with an OR-shaped `foregroundSessionActive`. Missing: everything voice, everything AX-act, loop budgets, auto mode, and human-abort arbitration.

Idioms this design inherits: pure state machines with time as an input (`DockHoverModel.feed(now:)`, `EvictionPolicy`), injected seams with stubs in Core (`LLMRuntime`/`StubLLMRuntime`, `MemoryPressureObserving`/fake), error taxonomies mapped at the boundary (`FileActionError`, `DockPreviewError`), bounded non-blocking failure surfaces, and "a side effect that didn't land becomes `.failed`, never a false Done."

## Goals / Non-Goals

**Goals:**
- Fluent push-to-talk voice conversation with barge-in, entirely on-device; ~1–2 s voice-to-voice via sentence-chunked TTS and a resident model.
- The agent can read, focus, and act on real windows through AX with the constrained-ID discipline; every act verifies; every write respects the gate; auto mode makes multi-step tasks hands-free when granted.
- One human trackpad touch aborts anything the agent is doing, instantly.
- All pure logic verifies under `swift build`/`swift test`; only live mic/AX behavior needs the signed build.
- Seams for v4+: `audio` on the request types; the voice session in the quiescence snapshot.

**Non-Goals:**
- No wake word / always-listening; the mic opens only while push-to-talk is held.
- No direct audio-in generation this change (the seam lands; the Gemma audio-tower integration is a follow-up).
- No coordinate clicking, no synthetic mouse moves; acts are semantic (`AXPress`/`AXSetValue`/typed text) only.
- No Kokoro/MLX TTS yet (`AVSpeechSynthesizer` first; the `SpeechSynthesizing` seam admits it later).
- No file ops / OS settings mutation tools in this change — the tool surface is read/focus/click/type/speak.

## Decisions

### D1 — `VoiceTurnModel`: one pure state machine owns the conversation lifecycle

States: `idle → listening (PTT held) → transcribing (PTT released, STT finalizing) → thinking (turn streaming) → speaking (TTS draining) → idle`, plus `bargeIn` entry from `thinking`/`speaking`. Inputs are events with timestamps (`pttDown/pttUp/transcript/tokens/ttsDone/humanTouch/error`, each `(at: Date)`); outputs are effects (`startCapture`, `stopCapture`, `sendTurn`, `speak(chunk)`, `stopSpeaking`, `cancelTurn`). The model never touches AVFoundation/Speech — `VoiceSessionController` (@MainActor) executes effects through the seams. Same testing story as `DockHoverModel`: every transition is a unit test with fake time.

### D2 — Two seams, stubs in Core, real conformers behind availability

- `SpeechTranscribing`: `start() -> AsyncThrowingStream<TranscriptChunk, Error>` (partials + final), `stop()`. Real conformer `SpeechAnalyzerTranscriber` wraps `SpeechAnalyzer`/`SpeechTranscriber` + `AVAudioEngine` voice-processing input, entirely `@available(macOS 26.0, *)`. The protocol itself is unversioned in Core; the **factory** (`VoiceRuntimeInjection.transcriberFactory`) returns `nil` on older macOS → the voice feature reports `VoiceError.osTooOld` (clean headline, feature reads as unavailable, never a crash). Stub: scripted transcript chunks with delays.
- `SpeechSynthesizing`: `speak(_ text: String)` queueing, `stop()`, `onFinished`. Real conformer wraps `AVSpeechSynthesizer` (macOS 15-safe, no gate needed). Stub records spoken strings + supports fake completion, so chunking and barge-in are fully testable.
- Voice-processing I/O (`setVoiceProcessingEnabled(true)`) gives system AEC so the mic doesn't hear our TTS — the physical precondition for barge-in-by-voice later; in this change barge-in is by *press* and *touch* (deterministic), not VAD.

### D3 — Sentence-chunked TTS off the existing token stream

`SentenceChunker` (pure): consume `.response`-channel token text, emit speakable chunks at sentence boundaries (`.`, `!`, `?`, `\n\n` + a max-length flush + a final flush). The controller feeds chunks to `SpeechSynthesizing` as they close, so the first sentence speaks while the rest generates. Thinking-channel tokens are never spoken. Markdown is flattened (code fences summarized as "code block, N lines" — reading `}` aloud is noise).

### D4 — Push-to-talk trigger: hold-key global PTT + mic button; trackpad touch is ABORT, never talk

The honest walkie-talkie trigger is a **held key** — the app already runs event taps (⌘-Tab path, Input Monitoring granted). Default: **hold Right Option** (configurable; chosen because it's a bare modifier — no text-input collision — and reachable one-handed); also a press-and-hold mic button on the canvas/notch surface. `pttDown` opens the mic (permission-gated), `pttUp` finalizes STT and sends the turn. During `thinking`/`speaking`, a new `pttDown` IS the barge-in (stop TTS + cancel turn + start listening — fluent correction). A human trackpad touch during agent action aborts (D10) — the trackpad is deliberately NOT a talk trigger; it's the kill switch, per the product's gesture grammar.

### D5 — The AX layer: read = semantic tree, IDs are the only currency, verify is mandatory

- `AXWindowSnapshot` (pure value): window identity (pid + CGWindowID + title), extracted text blocks, and `elements: [AXElementRef]` — each with a **stable ID** (SHA-hash of role + title/label + hierarchical path), role, label, value preview, and actionability (pressable / settable / focusable). Built by `AXWindowReader` (boundary type wrapping `AXUIElement`, mirroring `AXDockReader`), depth- and count-bounded (large trees truncate honestly with a `truncated` flag).
- **Constrained selection**: act tools take an `elementID` that must resolve against the **most recent snapshot for that window** (a per-window epoch). A stale/unknown ID → `AXActionError.staleElement` telling the loop to `read_window` again — the model can only act on things that exist. No coordinates anywhere in the tool schema.
- **Verify-after-act**: after `press`/`setValue`/`type`, the primitive re-reads the affected element/subtree and reports `verified: Bool` + the new value in the `ToolStepResult` summary. A failed verify → `.failed` with a clean headline ("Clicked 'Send' but the field still shows text") — never a false Done.
- Reader and act primitives all throw `AXActionError` (Core `LocalizedError` taxonomy parallel to `FileActionError`: `notPermitted`, `appNotResponding` (AX timeout), `windowGone`, `staleElement`, `elementNotActionable`, `verifyFailed`) mapped at the boundary, surfaced bounded + non-blocking, and registered with `AIError.message(for:)`.

### D6 — Tools: five contributors, switcher-as-API for focus

- `read_window(windowRef)` (`.auto`): AX text + element list into the conversation (bounded; the summary carries the text, the element list is cached for act tools).
- `focus_window(app, titleHint)` (`.auto`): resolves via `WindowService.snapshot()` matching, commits through the **existing `raiseCommitted` path** (trackpad/⌘-Tab's third caller) — inheriting the SkyLight handshake, minimized restore, Stage Manager guards for free.
- `click_element(windowRef, elementID)` / `type_text(windowRef, elementID?, text, submit: Bool)` (**`.confirm` tier** — auto mode can lift it): the act primitives above. `type_text` focuses the target element, types via CGEvent keyboard events from a **tagged event source** (D10), optional Return.
- `speak(text)` (`.auto`): routes into the TTS seam — the agent narrates on demand, and the loop uses it for progress narration.
- All registered as one `ComputerUseToolContributor` + `VoiceToolContributor`, flag-gated so the tools don't exist while the features are off (`ToolRegistry` re-queries live).

### D7 — Auto mode: a per-conversation grant threaded through the existing gate

`AgentConversation` gains `autoApprove: Bool` (persisted with the conversation, default false). The approval gate consults it: a `.confirm`-tier step with `autoApprove` → executes immediately, and the step summary is **narrated** (spoken when voice is active, always visible in the step list) so silence never hides an act. Granting: (a) the initial command text ("…do it without asking" → the router's schema includes an `autoMode` boolean the executor applies), (b) mid-conversation via a routable `set_auto_mode(on)` tool (`.confirm` to turn ON — the one approval you can't skip — `.auto` to turn OFF), (c) a visible toggle on the canvas/notch surface. Revocation is instant and sticky-off for the rest of the conversation.

### D8 — Loop budgets: per-step timeout + per-turn deadline in `AgentLoop`

Injected `LoopBudget` (pure config): `stepTimeout` (default 30 s), `turnDeadline` (default 180 s), both fed by settings closures. Implementation: each tool dispatch races a timeout (`withThrowingTaskGroup`); a timed-out step becomes `.failed("<tool> timed out")` (the step's own task is cancelled — tools must be cancellation-safe, which `registry.run` already requires). The turn deadline is checked between steps like `maxToolSteps`; exceeding it terminates with the existing cap-reached fallback (partial narration: "ran out of time; here's where I got"). Timeouts are budget errors, not `RuntimeError`s — no false "server unavailable" headlines.

### D9 — Agent-acting arbitration: tagged synthetic events + any-human-touch aborts

A session-scoped `AgentActionArbiter` (@MainActor): tools that post synthetic input (only `type_text` today — AX press/setValue post no HID events) run inside `arbiter.acting { … }`. While acting: (1) synthetic keyboard events are posted from a private `CGEventSource` whose `userData` carries a magic tag, and the app's own event taps **ignore tagged events** (the recognizer never interprets agent typing); (2) the raw touch stream (`TouchEngine`) reports any human contact → `arbiter.abort()` → cancels the in-flight tool task + the turn (cancellation is a discard, not a failure: the canvas/voice narrates "stopped"). The arbiter also exposes `isActing` to the overlay layer for a visible "agent has the wheel" indicator (a bounded pill, not a modal).

### D10 — speak-last-response: the v0 command that needs no mic

A catalog command ("Speak last response") + keywordable tool chain: resolve the frontmost-or-named terminal window → `read_window` → extract the tail (the `summarize` subagent with an extraction prompt: "the assistant's final reply in this transcript") → `speak`. Works with voice fully off (it's TTS-only), giving the read-aloud anecdote standalone value and exercising window-resolve + AX-read + TTS end-to-end before the mic even asks for permission.

### D11 — Permission + gating

`voiceConversationEnabled` (default OFF) and `computerUseEnabled` (default OFF) — separate opt-ins under the AI master gate; the Hub rows disclose costs (mic grant; "the agent can click and type"). First `pttDown` requests mic authorization (`AVCaptureDevice.requestAccess(.audio)`); denial → `VoiceError.micDenied` with a non-blocking card + a System Settings deep link. If `SpeechAnalyzer` additionally requires speech-recognition authorization, the same flow covers it (checked at conformer init; failure maps to `VoiceError.speechUnavailable`). The STT conformer being macOS-26-gated means on macOS 15–25 the voice toggle shows "requires macOS 26" and stays off — computer-use tools work regardless.

### D12 — The `audio` seam (v4+ foundation, statically honest)

`LLMRequest`/`LLMChatRequest` gain `audio: [Data]` (PCM/WAV bytes, default `[]`, mirroring `images`), `requiresAudio` computed, and `Modality.audio` selection plumbs through `selectModel(requiring:)` exactly like vision. Every current runtime **rejects** a non-empty `audio` with `unsupportedModality(.audio)` (the stub enforces the same contract in tests) — the field is carried, typed, and honestly refused until the Gemma audio-tower conformer lands (the vendored `Gemma4AudioProcessor`/`pendingAudioFeatures` mirrors the vision integration shape). No dead-seam ambiguity: the spec delta states the reject contract explicitly.

## Risks / Trade-offs

- [AX quality varies wildly (Electron/web deserts)] → constrained IDs mean the model can only choose from what exists; empty/thin trees produce an honest "I can't read this window" (`elementNotActionable`/empty snapshot), and the vision-capture fallback (existing `.screenRegion` machinery) covers reading; acting on a desert stays impossible by design rather than degrading to coordinate guessing.
- [Held-key PTT collides with user's existing Right-Option usage] → configurable binding + off-by-default feature; the mic button is always available.
- [Agent typing into the wrong window] → `type_text` targets an element in a *named window snapshot*, and the primitive re-asserts window focus (`focus_window` semantics) before typing; verify-after-act catches the miss; `.confirm` tier unless auto-granted.
- [A hung AX call (beachballing app) freezes a step] → AX calls run off-main with the per-step timeout (D8); `appNotResponding` is a clean failure.
- [TTS speaking stale tokens after barge-in] → the chunker is flushed and the synthesizer stopped in the same effect batch as `cancelTurn`; the model's `bargeIn` state drops late `tokens` events on the floor (tested).
- [Mic permission adds a scary prompt] → requested lazily on first actual PTT (never at enable), with the Hub disclosure ahead of it.
- [SpeechAnalyzer API surface drift (new OS API)] → the conformer is one file, seam-isolated; a breakage strands only that file, and the stub keeps Core green.

## Open Questions

- Whether `SpeechAnalyzer` needs the separate speech-recognition TCC prompt in addition to mic (checked at first run on the signed build; both paths handled).
- Default voice (AVSpeech voice selection) — ship system default; a picker is a follow-up nicety.
- Whether `read_window` summaries should auto-include OCR of the vision fallback for AX deserts (deferred; explicit capture keeps costs visible).
