## MODIFIED Requirements

### Requirement: Fresh vertical triggers Mission Control / App Exposé when the feature owns the gesture
When the Space-row switching opt-in is effectively enabled (so the OS three-finger vertical gesture has been freed to a scroll), a fresh three-finger vertical swipe — vertical axis dominant, before any horizontal activation — SHALL emit a one-shot overview intent rather than yielding, so idle three-finger up/down still acts even though the OS no longer handles it. Up SHALL map to Mission Control. Down SHALL map to the **configured down-action**: **App Exposé by default**, or **minimize-all-windows** (minimize every current-Space window to reveal the desktop) when the swipe-down-minimize-all opt-in is on. The recognizer SHALL emit the same up/down intent regardless of which action is configured — the action is selected by the handler, not the recognizer. The intent SHALL fire at most once per gesture, and only after a deliberate vertical travel threshold (larger than axis detection) to avoid accidental triggers.

#### Scenario: Idle vertical up opens Mission Control
- **WHEN** the opt-in is effectively enabled and three fingers swipe up past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single Mission Control intent (up) and shows no overlay

#### Scenario: Idle vertical down performs the configured down-action (default App Exposé)
- **WHEN** the opt-in is effectively enabled, the swipe-down-minimize-all opt-in is off, and three fingers swipe down past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single down intent and the handler performs App Exposé

#### Scenario: Idle vertical down minimizes all windows when opted in
- **WHEN** the opt-in is effectively enabled, the swipe-down-minimize-all opt-in is on, and three fingers swipe down past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single down intent and the handler minimizes all current-Space windows, revealing the desktop, rather than performing App Exposé

#### Scenario: Fires once per gesture
- **WHEN** the fingers continue moving vertically after the intent has fired
- **THEN** no further down/up intent is emitted until the fingers lift and a new gesture begins

#### Scenario: Below threshold does not trigger
- **WHEN** the opt-in is effectively enabled and the vertical travel stays below the trigger threshold
- **THEN** no down/up intent is emitted
