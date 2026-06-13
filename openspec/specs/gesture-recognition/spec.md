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
When tracking a latched four-finger launcher gesture, the recognizer SHALL emit semantic launcher intents and SHALL NOT raise windows or step Space-rows: an **activate** intent when horizontal travel crosses the four-finger activation threshold; an **end** intent when the gesture ends; and, **after activation**, navigation intents produced by the **anchored positional navigation interpretation** (see that requirement) rather than by odometer travel accumulation. The launcher uses the **position-tracking (padding-box)** behavior on both axes — the item / band cursor follows the finger's position in steps (a fast sweep may emit several steps at once), and leaving the box or the edge band emits a held-in-zone sign so the controller can drive eased auto-repeat. The recognizer SHALL NOT itself implement dwell, arm, fire, or the repeat cadence — those are owned by the launcher controller.

The opening **activation** itself is unchanged: it is still the odometer-style horizontal fling crossing the four-finger activation threshold (the positional model governs only navigation *after* activation).

The launcher gesture SHALL be **latched** at begin and SHALL remain a launcher gesture for its entire lifetime regardless of later contact-count changes: a transient three-finger count (for example while lifting from four fingers to two) SHALL NOT route to the switcher and SHALL NOT cancel the gesture. After the four-finger activation, the gesture SHALL continue while **two or more** contacts remain, with navigation measured from the **centroid of the remaining contacts**. The positional **center and scale SHALL be re-anchored on every contact-count change** (with per-axis arm/zone state reset) so that relaxing or adding fingers produces no step. The gesture SHALL **end when the contact count drops below two**, at which point the recognizer emits the end intent and the controller decides fire-or-dismiss. Keeping four fingers in contact for the whole gesture SHALL behave consistently with the relaxed posture (navigation is positional in both).

#### Scenario: Activate on horizontal threshold

- **WHEN** a four-finger launcher gesture's horizontal travel crosses the activation threshold
- **THEN** the recognizer emits a launcher activate intent

#### Scenario: Item cursor tracks the finger position

- **WHEN** the launcher gesture is active and the horizontal offset moves N item-steps from center
- **THEN** the recognizer emits N item-step intents (the cursor tracks the finger); moving back steps it back

#### Scenario: Holding past the box accelerates the cursor

- **WHEN** the launcher gesture is active and an axis's offset is held past the box (or in the edge band)
- **THEN** the recognizer reports a held-in-zone sign so the controller auto-repeats item/context stepping along the eased curve

#### Scenario: Navigation continues after dropping to two fingers

- **WHEN** the launcher gesture is active and the user lifts to two (or three) fingers and then moves
- **THEN** the gesture stays a launcher gesture and the recognizer emits positional item/context-step intents from the re-anchored center

#### Scenario: Relaxing fingers does not emit a spurious step

- **WHEN** the contact count changes (e.g. four fingers relax to two) and the centroid shifts as fingers leave
- **THEN** the positional center/scale re-anchor, the per-axis state resets, and no item-step or context-step intent is emitted from the count change alone

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

### Requirement: Anchored positional navigation interpretation

While an overlay navigation surface is open (post-activation launcher navigation and the Files column navigator), the recognizer SHALL interpret movement **positionally** rather than as accumulated travel. It SHALL anchor a **center** at the current contact centroid and a **scale** derived from the fingers' landing **footprint** (the spread of the per-contact positions), and SHALL read navigation as the **offset of the centroid from that center, normalized by the footprint scale** — so the same physical displacement means the same thing regardless of where on the trackpad the hand landed. When the footprint is unavailable (e.g. a fabricated frame with no per-contact positions) or degenerate (near-zero spread), the recognizer SHALL fall back to a **fixed normalized scale** so behavior remains defined. The center and scale SHALL be **re-anchored on every contact-count change** (resetting per-axis state), so relaxing or adding a finger emits no spurious step — this replaces the odometer accumulation and the physical-edge detection used previously.

Each axis SHALL use one of two behaviors:

- **Position-tracking (a "padding box"):** inside a box of half-size **`radius`** around the locked center, the selection index SHALL **follow the finger's offset** in discrete steps (`round(offset / step)`, both directions) — moving out steps the selection out, moving back steps it back, possibly **several steps in one frame** on a fast sweep. Leaving the box (`|offset| ≥ radius`) **or** the centroid entering the fixed **edge-margin band** at the trackpad border SHALL enter the **margin**, where the recognizer emits a **held-in-zone sign** (−1 / 0 / +1 per axis) and the controller drives the eased auto-repeat (the recognizer SHALL NOT time the repeat).
- **Out-and-back:** crossing an **outer** threshold SHALL emit **exactly one** step + a held sign; returning inside an **inner** deadzone SHALL re-arm. Used where stepping must stay deliberate (one step per gesture), e.g. Files folder depth.

While accelerating in the margin, a small move **back** — the offset retreating from its furthest held point by more than a configurable **back-off** — SHALL **snap the center onto the finger and stop** the auto-repeat, leaving a fresh box centered under the finger.

#### Scenario: Center is anchored at the landing footprint

- **WHEN** the navigation surface opens (or the contact count changes) and the fingers settle
- **THEN** the recognizer anchors the center at the current centroid and derives the scale from the fingers' footprint, so offset is measured relative to where the hand actually landed

#### Scenario: Position-tracking follows the finger both ways

- **WHEN** a position-tracking axis's offset moves out by several steps and then back toward center
- **THEN** the selection steps out by that many and then steps back, tracking the finger's position (the center stays locked)

#### Scenario: Leaving the box accelerates

- **WHEN** a position-tracking axis's offset reaches the box radius (or the centroid enters the edge-margin band)
- **THEN** the recognizer reports a held-in-zone sign for that axis and the controller auto-repeats; holding emits no further discrete steps

#### Scenario: Pull back from the margin re-centers and stops

- **WHEN** an axis is accelerating in the margin and the finger moves back past the back-off
- **THEN** the center snaps onto the finger, the held sign clears, the auto-repeat stops, and a fresh box is centered there

#### Scenario: Out-and-back emits exactly one step (deliberate axis)

- **WHEN** an out-and-back axis's offset crosses the outer threshold and returns inside the inner deadzone
- **THEN** exactly one step is emitted in that direction and the axis re-arms (no second step until it crosses outer again)

#### Scenario: Re-anchor on contact-count change emits no step

- **WHEN** the contact count changes (e.g. four fingers relax to two) and the centroid shifts as fingers leave
- **THEN** the center and scale re-anchor, the per-axis state resets, and no step is emitted from the count change alone

#### Scenario: Footprint fallback when per-contact positions are unavailable

- **WHEN** a frame carries no usable per-contact footprint (or a degenerate near-zero spread)
- **THEN** the recognizer uses a fixed normalized scale rather than producing undefined or runaway stepping

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

