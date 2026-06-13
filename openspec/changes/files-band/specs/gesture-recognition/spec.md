## ADDED Requirements

### Requirement: Files-drill modal sub-state

While the Files band's column navigator is open, the recognizer SHALL enter a **files-drill modal sub-state** that, like the AI canvas-resolution mode, **bypasses the normal finger-count latch**: gesture handling SHALL be routed to the drill tracker **before any idle re-latch**, so a fresh contact during drill-in SHALL NOT open the switcher or a second launcher on top of the navigator. The sub-state SHALL be **entered when the navigator opens** (signalled by the launcher controller) and **cleared when it resolves or hides**.

While in the sub-state the recognizer SHALL:
- remain active while **two or more** contacts remain, measuring travel from the **centroid of the remaining contacts**, and **re-baseline** the reference origin (clearing any sub-step carry) on **every contact-count change**, so a leaving or landing finger emits no spurious step;
- emit a **depth** intent (with direction) per item-step distance of **horizontal** travel and a **highlight** intent (with direction) per step of **vertical** travel, honoring the launcher's direction-inversion settings;
- detect a **relative +1 finger** — a contact count that rises **above the current relaxed baseline** (not an absolute count of three) — and, on the subsequent resolving lift, emit an **open-with** resolution instead of a plain **open**;
- treat a fresh deliberate **four-finger horizontal swipe-away** as a **discard** resolution;
- treat the resolving lift (contact count dropping below two, with the standard below-target debounce) as a **one-shot** resolution (open / open-with / discard), so a stray re-lift after resolution is a **no-op**.

The recognizer SHALL NOT itself implement directory navigation, preview, search-field focus, dwell, arm, or fire — it emits only intents; the controller and model interpret them (including deciding that an up-step while already at the top of the list means focus-search).

#### Scenario: Drill-in bypasses the latch
- **WHEN** the navigator is open and a fresh contact lands
- **THEN** the recognizer routes to the drill tracker and does not open the switcher or a second launcher

#### Scenario: Horizontal emits depth, vertical emits highlight
- **WHEN** in the drill sub-state the user travels horizontally or vertically past the step distance
- **THEN** the recognizer emits a depth intent (horizontal) or a highlight intent (vertical) in the travel direction, per the direction settings

#### Scenario: Relative plus-one finger arms Open-With
- **WHEN** the user adds a finger above the current relaxed baseline and then lifts to resolve on a file
- **THEN** the recognizer emits an open-with resolution rather than a plain open

#### Scenario: Plus-one is relative, not an absolute three
- **WHEN** the user has relaxed to three fingers and then adds a fourth (baseline three rising to four)
- **THEN** the added finger is detected as the Open-With morph (the trigger is "a finger was added", not "exactly three fingers")

#### Scenario: Re-baseline on contact change emits no spurious step
- **WHEN** the contact count changes and the centroid shifts as fingers leave or land
- **THEN** the reference origin is re-baselined and no depth or highlight intent is emitted from the count change alone

#### Scenario: Four-finger horizontal swipe discards
- **WHEN** in the drill sub-state the user makes a fresh deliberate four-finger horizontal swipe-away
- **THEN** the recognizer emits a discard resolution

#### Scenario: Resolution is one-shot
- **WHEN** the selection has resolved (opened / open-with / discarded) and the user re-lifts
- **THEN** the recognizer emits nothing further (the re-lift is a no-op)
