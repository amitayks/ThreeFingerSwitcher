## ADDED Requirements

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

## MODIFIED Requirements

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
