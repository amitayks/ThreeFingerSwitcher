## ADDED Requirements

### Requirement: User-configurable resolution-gesture bindings
The app SHALL let the user choose **which excursion performs which action** for the **resolution** gestures of remappable open surfaces — today, the window switcher's scrub axes. Each surface SHALL have its own **action set** and its own **excursion vocabulary** (the surfaces are deliberately distinct grammars and SHALL NOT be unified into one remap). *(The former AI-canvas and Files-drill binding surfaces were removed with those features — `remove-local-ai`.)* Bindings SHALL be **persisted** and SHALL **default to exactly today's behavior**. The bindings SHALL be consumed at the existing raw-direction seam (the recognizer's emitted direction is unchanged); only the action a direction maps to is configurable.

- **Switcher:** per-axis scrub `{windows axis, Spaces axis}` ∈ `{normal, reversed}`. Default: both normal.

#### Scenario: Default bindings reproduce today's grammar
- **WHEN** the user has never changed a binding
- **THEN** every surface resolves exactly as it does today (both switcher axes normal)

#### Scenario: A remapped axis performs the bound direction
- **WHEN** the user sets the switcher's windows axis to reversed and scrubs right
- **THEN** the highlight steps in the reversed direction (and the normal mapping no longer applies)

### Requirement: Reserved and invalid excursions are never bindable
The binding vocabularies SHALL exclude excursions that must keep a fixed meaning: **single-finger** motion is never a trigger anywhere. **Activation** gestures (which finger-count opens which platform) SHALL NOT be remappable — bindings cover resolution within an already-open surface only.

#### Scenario: Single-finger is not offered as a binding
- **WHEN** the user opens a binding editor
- **THEN** no single-finger excursion is available to bind

#### Scenario: Activation finger-counts are not remappable
- **WHEN** the user looks for a way to change which finger-count opens the launcher vs. the switcher
- **THEN** no such binding is offered (the open/dismiss-vs-act-within finger grammar is fixed)
