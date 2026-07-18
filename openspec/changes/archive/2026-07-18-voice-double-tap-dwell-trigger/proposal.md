# Proposal: voice-double-tap-dwell-trigger

## Why

The single-hold trigger (even with the chord-arming fix) still shares its key with ordinary typing: a long Right-Option hold for special characters sits ambiguously against "start talking", and the arming window is a heuristic. The user's call: make the trigger **two fast clicks + dwell** — tap, then tap-and-HOLD the second press. This is the macOS dictation idiom (double-press 🌐), it makes chord collision structurally impossible (no typing chord ever double-taps a bare modifier), and it returns ALL single-press/single-hold Option behavior to the system untouched.

## What Changes

- **The hold-key trigger becomes double-tap-then-hold**: first click (down+up, each ≤ 0.3 s), second down within 0.3 s, held past a 0.15 s dwell → push-to-talk begins; release sends. A double-tap WITHOUT the dwell is a no-op; a long single hold is a no-op (plain modifier use); any other key at any pre-talk stage cancels to typing. Barge-in uses the same gesture (the turn model's `pttDown` semantics are unchanged — only when it fires changes).
- **`PTTArmingModel` is rewritten** for the new grammar (idle → firstDown → awaitingSecond → dwelling → held, with an `inert` disqualified state); still pure, still fully transition-tested; the monitor stays a thin one-timer driver.
- Hub caption updated to teach the new gesture.

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `voice-conversation`: the push-to-talk requirement's trigger grammar changes from hold-alone-with-arming to double-tap-then-hold.

## Impact

- `PTTArmingModel.swift`, `PTTKeyMonitor.swift`, `PTTArmingModelTests.swift`, one Hub caption. The mic-button press-and-hold path is unchanged.
