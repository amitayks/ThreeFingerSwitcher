# Proposal: add-speak-last-response-launcher-action

## Why

Speak-last-response shipped (in `add-voice-computer-use-agent`) only as a menu-bar item — the user looked for it in the Hub/launcher and couldn't find it. This is a trackpad-first app; the natural trigger for "read me the last response" is a launcher band item fired by gesture, exactly like every other system action. The original task even scoped it as a command; the menu-bar-only surface was the shortfall.

## What Changes

- **New `SystemAction.speakLastResponse`** (System category): a one-shot launcher action ("Speak Last Response", speaker symbol) that any band can carry via the existing favorites editor — it appears automatically in the action picker (`CaseIterable`).
- **`LaunchService` gains `onSpeakLastResponse`** (injected closure, the `onAICommand` idiom — the launcher never knows the coordinator); the coordinator wires it to the existing `speakLastResponse()`.
- The menu-bar item stays (two triggers, one behavior).

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

- `launch-actions`: the system-action set gains the speak-last-response one-shot (gated like other AI-adjacent surfaces: it does nothing useful with AI off — it falls back to reading the window's last visible lines, which still works).

## Impact

- `LaunchItem.swift` (enum case + meta), `LaunchService.swift` (closure + dispatch), `AppCoordinator.swift` (one wiring line). Additive `String`-raw-value case — existing stored favorites decode unchanged.
