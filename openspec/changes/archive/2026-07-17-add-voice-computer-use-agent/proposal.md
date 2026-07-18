# Proposal: add-voice-computer-use-agent

## Why

The user's vision for the app: talk to the Mac fluently and have the local agent *use the computer like a human* — "read Claude's last response on that terminal tab", "write back … and send", "move to the Chrome window, tell me who messaged me" — all local, fast, and private. This app is uniquely positioned: it already owns hardened window control (SkyLight raise, focus watchdog), AX-tree reading (the Dock reader), screen capture, a vision-capable local model, a tool-routing agent loop with write-policy tiers, and the Accessibility + Screen Recording TCC grants. What's missing is the voice loop (STT/TTS + turn management), the AX read/act/verify tool layer, and the trust machinery (auto mode, budgets, human-abort). Building all stages together now — with the seams for direct audio-in Gemma (v4+) laid — was the user's explicit call.

## What Changes

- **Voice conversation (push-to-talk)**: hold-to-talk mic capture (`AVAudioEngine` voice-processing I/O for echo cancellation), on-device STT via Apple `SpeechAnalyzer`/`SpeechTranscriber` (`@available(macOS 26)`), the transcript feeds the existing agent chat turn, and the reply is spoken via **sentence-chunked TTS** (`AVSpeechSynthesizer`) consuming the existing `.response` token stream — first sentence speaks while the rest generates. **Barge-in**: a new push-to-talk press (or any human trackpad touch) while the agent is speaking/thinking stops TTS and cancels generation via the existing cancellable-generation path. A pure `VoiceTurnModel` state machine (time as input) owns the lifecycle; a voice session counts as `foregroundSessionActive` in the model-eviction quiescence snapshot.
- **Speak-last-response (the v0 wedge, no mic)**: a command that resolves a target window (switcher enumeration), reads its text via AX, extracts/summarizes the relevant content (e.g. the assistant's last reply in a terminal), and speaks it. Ships standalone value and exercises window-resolve + AX-read + TTS end-to-end.
- **Computer-use tools (AX-first, pixels-second)**: an `AXWindowContent` reader producing semantic text + an **enumerated element list with stable IDs**; act primitives (`AXPress`, `AXSetValue`, keyboard-type) that accept **element IDs only — never coordinates, never fabricated targets** (the ToolRouter degrade-never-fabricate philosophy applied one level down); **verify-after-act** (re-read AX; a world that didn't change → `.failed`, never a false "Done"). New routable tools: `read_window`, `focus_window` (via the switcher's `raiseCommitted` path — the "API to the switcher"), `click_element`, `type_text`, `speak`. Vision capture stays the fallback/verifier, not the primary sense.
- **Auto mode + trust**: a per-conversation **auto-approve mode** (grantable in the initial command or mid-conversation, like Claude Code's auto-accept) threaded through the existing approval gate — reads always auto, acts auto only under the grant; **per-step wall-clock timeout + a per-turn budget** in `AgentLoop` (today it has neither); an **agent-acting mode** where agent-posted synthetic events are ignored by the gesture recognizer and **any human trackpad touch instantly aborts** the agent's action; spoken progress narration hooks so long tasks are never silent.
- **v4+ foundations**: `LLMRequest`/`LLMChatRequest` carry `audio: [Data]` (mirroring `images` — the vendored `Gemma4AudioProcessor`/`pendingAudioFeatures` path integrates later without a seam change); the voice session plugs into the already-landed `QuiescenceSnapshot` flag.
- **New TCC permission**: microphone — the app's first new grant. Opt-in feature, default OFF; the mic is open **only while push-to-talk is held**. No wake word, no always-listening.

## Capabilities

### New Capabilities

- `voice-conversation`: push-to-talk capture, on-device STT, sentence-chunked TTS, barge-in, the pure voice-turn lifecycle, mic permission flow, and the speak-last-response command.
- `computer-use-tools`: the AX read/act/verify tool layer, constrained element-ID selection, switcher-as-API window focus, write-policy/approval integration with the per-conversation auto-approve mode, agent-loop step timeouts + turn budgets, the human-abort arbitration, and the vision-fallback rule. *(The budget/auto-mode requirements live here — the main specs do not yet own the agent loop; this capability is what makes them necessary.)*

### Modified Capabilities

- `on-device-ai-runtime`: the request seam gains an `audio` input (reserved-but-real: statically typed, carried through `LLMRequest`/`LLMChatRequest`, required to be rejected cleanly by non-audio runtimes) — the audio-modality foundation for direct audio-in Gemma.

## Impact

- **Code (new, mostly MLX-free Core)**: `Sources/ThreeFingerSwitcher/AI/Voice/` (turn model, chunker, seams + stubs, session controller, errors), `Sources/ThreeFingerSwitcher/AI/Ax/` (reader, element IDs, act primitives, verify, errors), new `ToolRegistry` contributors, `AgentLoop` budget/timeout changes, approval-gate auto-mode, `GestureRecognizer` agent-acting arbitration, `AppSettings` toggles, Hub page rows, `AppCoordinator` wiring. Real STT/TTS conformers use system frameworks (`Speech`, `AVFoundation`) — they compile under `swift build`; the STT conformer is `@available(macOS 26)`-gated (platform floor stays macOS 15).
- **Permissions**: `NSMicrophoneUsageDescription` + (if required by SpeechAnalyzer) speech-recognition usage string in the app bundle plist (build-app.sh / Info.plist path).
- **Non-goals (this change)**: no wake word / always-listening; no direct audio-in generation (seam only); no Kokoro/MLX TTS (AVSpeech first; the seam admits a better voice later); no coordinate-based clicking; no cloud anything.
- **Risk**: AX quality varies per app (Electron deserts) — mitigated by the constrained-ID design (the model can only pick from what actually exists) and the vision fallback; live mic/AX behavior is only fully verifiable in the user's stable-signed build (manual checklist provided at the end).
