# gesture-recognition Specification

## Purpose

Define the three-finger horizontal scrub state machine: detection, axis-lock, activation threshold, step accumulation/carry, and the commit/cancel lifecycle that drives the window switcher.
## Requirements
### Requirement: Three-finger gesture detection
The system SHALL latch the active finger count at the start of a candidate gesture and use it to route the whole gesture. A gesture beginning with exactly three fingers SHALL be tracked as a window-switcher gesture. When the launcher opt-in is effective, a gesture beginning with four fingers SHALL be tracked as a launcher gesture. The latched count SHALL govern the gesture for its lifetime, with the same brief-excursion debounce used for edge flicker. When the launcher opt-in is NOT effective, a fourth finger landing during a three-finger candidate SHALL cancel it (preserving prior behavior).

#### Scenario: Exactly three fingers starts switcher tracking
- **WHEN** the active finger count becomes exactly 3
- **THEN** the recognizer captures the starting centroid and begins tracking displacement in window-switcher mode

#### Scenario: Four fingers starts launcher tracking
- **WHEN** the launcher opt-in is effective and a gesture begins with four fingers
- **THEN** the recognizer tracks displacement in launcher mode for the duration of the gesture

#### Scenario: Fourth finger cancels when the launcher is off
- **WHEN** the launcher opt-in is not effective and a fourth finger lands during a three-finger candidate or active gesture
- **THEN** the recognizer cancels without committing and hides any overlay

### Requirement: Axis-lock yields vertical to the OS
The system SHALL determine gesture axis from accumulated displacement and SHALL yield (take no action) when vertical motion dominates, so Mission Control / App Exposé are handled by the OS.

#### Scenario: Vertical motion is ignored
- **WHEN** accumulated |Δy| dominates |Δx| beyond the configured axis-lock ratio before activation
- **THEN** the recognizer treats the gesture as vertical and never shows the overlay

#### Scenario: Horizontal motion is captured
- **WHEN** accumulated |Δx| dominates |Δy| beyond the axis-lock ratio
- **THEN** the recognizer locks to the horizontal axis for the remainder of the gesture

### Requirement: Activation threshold
The system SHALL not show the switcher until horizontal centroid displacement crosses the configured activation threshold, preventing accidental triggering.

#### Scenario: Below threshold shows nothing
- **WHEN** three fingers move horizontally less than the activation threshold and then lift
- **THEN** no overlay is shown and no window is raised

#### Scenario: Crossing threshold activates
- **WHEN** horizontal centroid displacement crosses the activation threshold
- **THEN** the overlay is shown and live scrubbing begins

### Requirement: Step accumulation with carry
The system SHALL move the selection by one window each time accumulated horizontal centroid travel reaches the configured step distance, carrying the remainder so scrubbing feels continuous, and SHALL step backward when the direction reverses.

#### Scenario: One step per step-distance
- **WHEN** accumulated horizontal travel since the last step reaches the step distance in the locked direction
- **THEN** the selection index advances by one and the step distance is subtracted from the accumulator (remainder retained)

#### Scenario: Reversal steps back
- **WHEN** the fingers reverse horizontal direction by at least one step distance
- **THEN** the selection index moves back by one

#### Scenario: End-of-list behavior honors setting
- **WHEN** the selection reaches an end of the window list
- **THEN** it wraps to the other end if wrap is enabled, otherwise it clamps at the end

### Requirement: Live highlight, commit on lift
The system SHALL update only the highlighted selection during scrubbing and SHALL raise+focus the highlighted window only when the fingers lift (commit), and SHALL cancel without raising if the activation threshold was never crossed.

#### Scenario: Scrubbing only highlights
- **WHEN** the user scrubs while three fingers stay down
- **THEN** only the highlight moves and no window is raised yet

#### Scenario: Lift commits
- **WHEN** the fingers lift after the overlay was activated
- **THEN** the currently highlighted window is raised and focused and the overlay hides

#### Scenario: Cancel before activation
- **WHEN** the fingers lift before the activation threshold was crossed
- **THEN** nothing is raised and no overlay was shown

### Requirement: Vertical row stepping after activation
After the switcher has activated via horizontal motion AND the Space-row switching opt-in is effectively enabled, the system SHALL track vertical centroid travel and step the selection between Space-rows — one row each time accumulated vertical travel reaches the configured row-step distance (with carry), reversing when direction reverses. When the opt-in is not effectively enabled, the system SHALL NOT track vertical for row stepping at any point in the gesture and SHALL fully yield vertical motion to the OS (Mission Control / App Exposé). In all cases the system SHALL NOT track vertical for row stepping before horizontal activation.

#### Scenario: Up/down switches Space-rows mid-gesture when enabled
- **WHEN** the Space-row switching opt-in is effectively enabled, the overlay is active, and the fingers move vertically past the row-step distance
- **THEN** the selection moves to the adjacent Space-row (and again for each further row-step distance)

#### Scenario: Vertical fully yielded when the opt-in is disabled
- **WHEN** the Space-row switching opt-in is not effectively enabled and the fingers move vertically after horizontal activation
- **THEN** the recognizer takes no row action and does not consume the vertical motion, leaving the OS to handle Mission Control / App Exposé

#### Scenario: Fresh vertical yields to the OS when the feature is off
- **WHEN** three fingers move vertically before any horizontal activation and the Space-row switching opt-in is not effectively enabled
- **THEN** the recognizer does not show the overlay and does not consume the vertical motion (the OS handles Mission Control / App Exposé natively)

#### Scenario: Horizontal jitter does not flip rows
- **WHEN** the opt-in is effectively enabled and the user scrubs horizontally with small incidental vertical wobble below the row-step distance
- **THEN** no row change occurs

#### Scenario: Reverse vertical direction setting
- **WHEN** the opt-in is effectively enabled and the reverse-vertical setting is enabled
- **THEN** sliding up moves rows in the opposite direction from the default

### Requirement: Fresh vertical triggers Mission Control / App Exposé when the feature owns the gesture
When the Space-row switching opt-in is effectively enabled (so the OS three-finger vertical gesture has been freed to a scroll), a fresh three-finger vertical swipe — vertical axis dominant, before any horizontal activation — SHALL emit a one-shot Mission Control / App Exposé intent rather than yielding, so idle three-finger up/down still opens the system overview even though the OS no longer handles it. Up SHALL map to Mission Control and down to App Exposé, the intent SHALL fire at most once per gesture, and only after a deliberate vertical travel threshold (larger than axis detection) to avoid accidental triggers.

#### Scenario: Idle vertical up opens Mission Control
- **WHEN** the opt-in is effectively enabled and three fingers swipe up past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single Mission Control intent (up) and shows no overlay

#### Scenario: Idle vertical down opens App Exposé
- **WHEN** the opt-in is effectively enabled and three fingers swipe down past the trigger threshold without a prior horizontal activation
- **THEN** the recognizer emits a single App Exposé intent (down)

#### Scenario: Fires once per gesture
- **WHEN** the fingers continue moving vertically after the intent has fired
- **THEN** no further Mission Control / App Exposé intent is emitted until the fingers lift and a new gesture begins

#### Scenario: Below threshold does not trigger
- **WHEN** the opt-in is effectively enabled and the vertical travel stays below the trigger threshold
- **THEN** no Mission Control / App Exposé intent is emitted

### Requirement: Four-finger launcher gesture intents
When tracking a latched four-finger launcher gesture, the recognizer SHALL emit semantic launcher intents and SHALL NOT raise windows or step Space-rows: an activate intent when horizontal travel crosses the four-finger activation threshold; an item-step intent (with direction) per item-step distance of horizontal travel after activation; a context-step intent (with direction) per context-step distance of vertical travel after activation; and an end intent when the gesture ends. The recognizer SHALL NOT itself implement dwell, arm, or fire — those are owned by the launcher controller.

The launcher gesture SHALL be **latched** at begin and SHALL remain a launcher gesture for its entire lifetime regardless of later contact-count changes: a transient three-finger count (for example while lifting from four fingers to two) SHALL NOT route to the switcher and SHALL NOT cancel the gesture. After the four-finger activation, the gesture SHALL continue while **two or more** contacts remain, with item-step and context-step travel measured from the **centroid of the remaining contacts**. The step reference origin SHALL be **re-baselined on every contact-count change** (with any in-progress sub-step carry cleared) so that relaxing or adding fingers produces no step. The gesture SHALL **end when the contact count drops below two**, at which point the recognizer emits the end intent and the controller decides fire-or-dismiss. Keeping four fingers in contact for the whole gesture SHALL behave exactly as before.

#### Scenario: Activate on horizontal threshold
- **WHEN** a four-finger launcher gesture's horizontal travel crosses the activation threshold
- **THEN** the recognizer emits a launcher activate intent

#### Scenario: Item step on horizontal travel
- **WHEN** the launcher gesture is active and horizontal travel accumulates past the item-step distance
- **THEN** the recognizer emits an item-step intent in the travel direction

#### Scenario: Context step on vertical travel
- **WHEN** the launcher gesture is active and vertical travel accumulates past the context-step distance
- **THEN** the recognizer emits a context-step intent in the travel direction

#### Scenario: Navigation continues after dropping to two fingers
- **WHEN** the launcher gesture is active and the user lifts to two (or three) fingers and then moves
- **THEN** the gesture stays a launcher gesture and the recognizer emits item/context-step intents from the remaining contacts' movement

#### Scenario: Relaxing fingers does not emit a spurious step
- **WHEN** the contact count changes (e.g. four fingers relax to two) and the centroid shifts as fingers leave
- **THEN** the step reference origin is re-baselined and no item-step or context-step intent is emitted from the count change alone

#### Scenario: Transient three-finger count does not route to the switcher
- **WHEN** an active four-finger launcher gesture passes through a three-finger count while lifting toward two
- **THEN** the recognizer emits no switcher intents and does not cancel the launcher gesture

#### Scenario: End below two contacts
- **WHEN** the contact count drops below two during a launcher gesture
- **THEN** the recognizer emits a launcher end intent and the controller decides fire-or-dismiss

### Requirement: Switcher navigation relaxes to two fingers after activation

After the three-finger switcher has activated via horizontal motion, the gesture SHALL continue while **two or more** contacts remain (subject to the existing too-many-fingers cancel rule), so the user can relax from three fingers to two and keep navigating the horizontal window grid and the vertical Space-rows, then lift to commit. Horizontal and vertical travel SHALL be measured from the **centroid of the remaining contacts**, and the step reference origin SHALL be **re-baselined on every contact-count change** (with any in-progress sub-step carry cleared) so that relaxing or adding a finger produces no spurious window-step or row-step. The gesture SHALL commit on lift when the contact count **drops below two**.

This relaxation applies **only after activation**. Before the overlay is shown the trigger is unchanged: the candidate still requires three fingers, and dropping below three before activation cancels exactly as before (the recognizer SHALL NOT activate the switcher from a two-finger contact). Keeping three fingers in contact for the whole gesture SHALL behave exactly as before.

#### Scenario: Navigation continues after relaxing to two fingers
- **WHEN** the switcher is active (overlay shown) and the user lifts from three fingers to two and then moves horizontally
- **THEN** the gesture stays a switcher gesture and the selection steps through windows from the two remaining contacts' movement

#### Scenario: Two-finger vertical still steps Space-rows
- **WHEN** the switcher is active, the Space-row switching opt-in is effectively enabled, and the user moves two fingers vertically past the row-step distance
- **THEN** the selection moves to the adjacent Space-row, exactly as it would with three fingers

#### Scenario: Relaxing fingers does not emit a spurious step
- **WHEN** the contact count changes (e.g. three fingers relax to two) and the centroid shifts as the finger leaves
- **THEN** the step reference origin is re-baselined and no window-step or row-step is emitted from the count change alone

#### Scenario: Lift below two contacts commits
- **WHEN** the contact count drops below two after the switcher was activated
- **THEN** the currently highlighted window is raised and focused and the overlay hides

#### Scenario: Trigger still requires three fingers
- **WHEN** fewer than three fingers are in contact and the overlay has not yet been activated
- **THEN** no overlay is shown and the recognizer does not activate the switcher (two-finger movement alone never triggers it)

#### Scenario: Dropping below three before activation cancels
- **WHEN** three fingers begin a candidate switcher gesture but lift below three before the activation threshold is crossed
- **THEN** the gesture cancels, nothing is raised, and no overlay was shown

### Requirement: Relative +1-finger action-menu intent

Across navigation surfaces, adding a contact **above the current relaxed baseline** (a relative +1 finger, `count > baseline`, not an absolute count) and then lifting SHALL resolve to an **action-menu** intent for the highlighted target (a right-click-equivalent contextual menu), distinct from the plain-lift resolution. The +1 SHALL be detected relative to the re-anchored baseline (so a user already holding three fingers does not false-trigger), and the resolution SHALL be **one-shot** per session (a stray re-lift after it resolves emits nothing). This generalizes the Files navigator's existing relative +1 → Open-With morph into a surface-agnostic action-menu intent.

#### Scenario: Relative +1 finger then lift opens the action menu

- **WHEN** a contact is added above the current relaxed baseline and the fingers then lift
- **THEN** the recognizer emits the action-menu intent for the highlighted target rather than the plain-lift resolution

#### Scenario: Holding the same count never false-triggers the action menu

- **WHEN** the user holds a steady contact count (no contact added above the re-anchored baseline) and then lifts
- **THEN** the plain-lift resolution is emitted, not the action-menu intent

#### Scenario: Action-menu resolution is one-shot

- **WHEN** the action-menu intent has already resolved for the session and the fingers re-lift
- **THEN** no further intent is emitted until the surface re-arms the session

### Requirement: Files-drill modal sub-state

While the Files band's column navigator is open, the recognizer SHALL enter a **files-drill modal sub-state** that, like the AI canvas-resolution mode, **bypasses the normal finger-count latch**: gesture handling SHALL be routed to the drill tracker **before any idle re-latch**, so a fresh contact during drill-in SHALL NOT open the switcher or a second launcher on top of the navigator. The sub-state SHALL be **entered when the navigator opens** (signalled by the launcher controller) and **cleared when it resolves or hides**.

While in the sub-state the recognizer SHALL:
- remain active while **two or more** contacts remain, measuring travel from the **centroid of the remaining contacts**, and **re-baseline** the reference origin (clearing any sub-step carry) on **every contact-count change**, so a leaving or landing finger emits no spurious step;
- emit a **depth** intent (with direction) per item-step distance of **horizontal** travel and a **highlight** intent (with direction) per step of **vertical** travel, honoring the launcher's direction-inversion settings;
- detect a **relative +1 finger** — a contact count that rises **above the current relaxed baseline** (not an absolute count of three) — and, on the subsequent resolving lift, emit an **open-with** resolution instead of a plain **open**;
- treat a fresh deliberate **four-finger horizontal swipe-away** as a **discard** resolution;
- treat the resolving lift (contact count dropping below two, with the standard below-target debounce) as a **one-shot** resolution (open / open-with / discard), so a stray re-lift after resolution is a **no-op**.

The recognizer SHALL NOT itself implement directory navigation, preview, dwell, arm, or fire — it emits only intents; the controller and model interpret them (an up-step while already at the top of the list simply clamps — the navigator is pure-trackpad with no search to focus).

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

