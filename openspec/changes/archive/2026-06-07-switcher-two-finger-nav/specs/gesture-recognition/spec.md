## ADDED Requirements

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
