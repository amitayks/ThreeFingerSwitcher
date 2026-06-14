## ADDED Requirements

### Requirement: Directional axis-lock commits a stroke to one axis

When directional axis-lock is enabled for a positional navigation surface, the recognizer SHALL commit a stroke to a single **dominant axis** and SHALL feed **only that axis** per frame, so an off-axis (diagonal) stroke moves the selection on the committed axis only while the perpendicular axis stays **frozen**. The recognizer SHALL freeze the perpendicular axis by **not feeding it** — it SHALL NOT feed that axis a zero offset, because under position-tracking a zero offset would step the selection back toward center (the axis index SHALL hold its current value).

The committed axis SHALL be chosen only once one axis **clearly dominates** the other, governed by a configurable **commit wedge** (`|dominant offset| ≥ ratio · |other offset|`, equivalently within a half-angle of the axis). While the offset direction is ambiguous (near the diagonal), the recognizer SHALL commit to **neither** axis and emit **no** step.

The lock SHALL persist until either (a) the offset returns inside the deadzone (a **settle**), or (b) the perpendicular axis exceeds the committed axis by a configurable **re-commit hysteresis** margin (a deliberate turn). On a re-commit the recognizer SHALL **per-axis re-anchor** the newly committed axis — reset that axis's center to the current centroid and reset its zone state — so the new direction starts from a fresh offset of zero, yielding clean **L-shaped** moves rather than diagonal movement. The lock SHALL re-arm to **none** on every re-anchor (contact-count change, activation). The lock SHALL apply to both **position-tracking** and **out-and-back** axes.

#### Scenario: Angled stroke commits to the dominant axis (forgives drift)

- **WHEN** a stroke moves predominantly along one axis while drifting off-axis (e.g. up-and-right where rightward dominates past the wedge)
- **THEN** the navigator commits to the dominant axis and emits steps on it only; the perpendicular drift produces no step

#### Scenario: Perpendicular axis is frozen, not pulled back

- **WHEN** an axis is committed and the perpendicular (position-tracking) axis already holds a non-zero index
- **THEN** the perpendicular axis is not fed and its index holds (the selection is not stepped back toward center)

#### Scenario: Ambiguous diagonal commits to neither axis

- **WHEN** a stroke's offset is near the diagonal so neither axis dominates the other by the wedge ratio
- **THEN** no axis is committed and no step is emitted until one axis clearly dominates

#### Scenario: A deliberate perpendicular turn re-commits with per-axis re-anchor

- **WHEN** an axis is committed and the finger then turns so the perpendicular axis exceeds the committed axis by the re-commit hysteresis margin
- **THEN** the lock switches to the perpendicular axis, that axis is per-axis re-anchored to the current centroid (its zone reset to zero offset), and the previously committed axis's index holds — producing an L-shaped move

#### Scenario: Settling to center re-arms the lock

- **WHEN** the committed axis's offset returns inside the deadzone
- **THEN** the lock re-arms to none, so the next stroke can commit afresh to either axis

#### Scenario: Re-anchor on contact-count change re-arms the lock

- **WHEN** the contact count changes (re-anchor) while an axis was committed
- **THEN** the lock re-arms to none along with the per-axis state, and no step is emitted from the count change alone

### Requirement: Directional (asymmetric) commit wedge

The horizontal-commit wedge MAY be **wider in one direction** than the baseline, so a stroke toward a specific target commits more readily than the opposite direction or the perpendicular axis. The recognizer SHALL support a separate, wider acceptance ratio applied ONLY to **rightward** strokes (`offset.x > 0`); the leftward and vertical commit tests SHALL keep the baseline wedge. When the directional ratio is unset the wedge SHALL be symmetric (the baseline applies in all directions). The horizontal-commit test SHALL be evaluated before the vertical-commit test, so within any overlap of the two cones the horizontal (target) direction wins.

#### Scenario: A rightward stroke uses the wider wedge

- **WHEN** the directional rightward ratio is set wider than the baseline and a stroke is angled off-axis toward the right past the wider cone but inside the baseline ambiguous band
- **THEN** the stroke commits to the horizontal axis (rightward), whereas the same angle would be ambiguous or vertical under the symmetric baseline

#### Scenario: The widening is rightward-only

- **WHEN** the directional rightward ratio is set and a stroke is angled off-axis toward the **left** at the same angle
- **THEN** the leftward stroke uses the baseline wedge (it does not get the widened acceptance)
