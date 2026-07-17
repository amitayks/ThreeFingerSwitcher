## ADDED Requirements

### Requirement: A fired AI command is one-shot and never becomes a conversation
A fired AI command SHALL execute as a **one-shot preset action**: it auto-fires exactly one generation from its configured input and template, streams the result into the preview canvas, and resolves by the canonical two-finger compass — **DOWN commits** (only when the canvas is scrolled to the top), **RIGHT/LEFT discards**, **UP scrolls**. The preview canvas SHALL NOT offer a typed composer, SHALL NOT accept follow-up turns, and SHALL NOT require the overlay panel to become the key window. A quick action SHALL NOT create a durable conversation or session of any kind: it SHALL never be handed to the notch dock's store or scheduler, SHALL never appear as a notch dock card, and SHALL leave nothing behind after commit or discard (the notch dock is populated exclusively by sessions born at the notch — see `ai-parked-sessions`). Re-running, adjusting the runtime parameter, and the armed confirmation for side-effecting tasks SHALL all operate within the same single-fire model.

#### Scenario: A preset auto-fires once and resolves by the compass
- **WHEN** the user fires an AI command item on selected text
- **THEN** the command auto-fires one generation that streams into the preview canvas, a two-finger DOWN at the top commits the result to the command's output target, and a horizontal swipe discards it

#### Scenario: The canvas offers no conversation affordance
- **WHEN** the preview canvas is open for a fired AI command
- **THEN** there is no typed composer, no follow-up-turn affordance, and no way to continue the result as a multi-turn thread from this surface

#### Scenario: A quick action never reaches the notch dock
- **WHEN** an AI command is fired and then committed or discarded — including while it is still streaming
- **THEN** no durable session is created, nothing is written to the notch dock's store or scheduler, and no card for it ever appears on the notch dock's rail
