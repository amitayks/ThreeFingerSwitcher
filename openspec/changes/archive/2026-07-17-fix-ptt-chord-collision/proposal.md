# Proposal: fix-ptt-chord-collision

## Why

The push-to-talk key is a bare modifier (Right Option), and macOS typing chords use modifiers: ⌥⌫ (delete word), ⌥→ (jump word), ⌥-symbols. The shipped monitor fired `pttDown` on the FLAG ALONE, so every ⌥⌫ spun up the full capture stack — audio engine, the system voice-processing unit, SpeechAnalyzer, an asset-inventory check — and tore it down milliseconds later on release. The user feels it as "option+delete is very laggy every time"; it also flashes the mic indicator on a typing chord, which is a privacy smell. (This was a named risk in the voice design — "Held-key PTT collides with Right-Option usage" — mitigated only by configurability; that was insufficient.)

## What Changes

- **Hold-intent arming window**: the PTT flag going down ARMS a short window (180 ms, tunable constant) instead of firing immediately. `pttDown` fires only when the window elapses with the modifier still held ALONE. Any OTHER key going down during the window cancels the arming — a chord is typing, never talk — and a release during the window is a complete no-op. The capture stack is never touched for a chord or a stray tap.
- **Chord detection**: the monitor also observes `keyDown` (passively — nothing is consumed) purely to cancel a pending arming.
- **Asset-check caching**: `SpeechAnalyzerTranscriber` remembers a successful speech-asset check process-wide, so legitimate PTT presses after the first skip the `AssetInventory` round-trip.
- The arming logic is a pure, unit-tested state machine (`PTTArmingModel`) — the NSEvent monitor is a thin driver.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `voice-conversation`: the push-to-talk requirement gains hold-intent semantics — a bare-modifier hold ALONE arms voice; typing chords and sub-window taps never touch the capture stack.

## Impact

- `PTTKeyMonitor.swift` (arming model + keyDown observation), `SpeechAnalyzerTranscriber.swift` (asset-check cache), new tests. Trade-off: voice start gains ~180 ms of deliberate-hold latency — imperceptible against multi-second turns, and the price of chord immunity.
