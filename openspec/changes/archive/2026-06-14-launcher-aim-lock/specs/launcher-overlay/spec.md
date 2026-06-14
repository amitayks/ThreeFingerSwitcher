## ADDED Requirements

### Requirement: Single-axis launcher navigation across the rail↔grid crossing

With directional axis-lock active (see gesture-recognition's *Directional axis-lock commits a stroke to one axis*), launcher navigation SHALL move on **one axis at a time**, so a diagonally-angled stroke does not change the band/row **and** the focus/column at once.

Crossing **from the band list into the grid** (a horizontal-dominant stroke) SHALL NOT switch the active band as a side effect of vertical drift — the user lands in the **current** band's items. Crossing **from the grid back to the band list** (a horizontal-dominant stroke) SHALL land on the **same band** the user entered from (the active band is preserved across a horizontal crossing) and SHALL NOT switch bands as a side effect of vertical drift; moving to an adjacent band SHALL require a **fresh, deliberate vertical stroke** after the crossing. Inside the grid, an angled stroke SHALL step on a single axis (between items, or between rows), not diagonally.

This SHALL apply equally to the Files band's navigator (its position-tracking highlight vs. its out-and-back depth), so a diagonal stroke does not move the highlight while drilling, nor drill while scrubbing the highlight.

#### Scenario: Entering a band's items forgives vertical drift

- **WHEN** the band list is focused and the user strokes horizontally into the grid while drifting vertically
- **THEN** the focus crosses into the current band's items and the active band does not change

#### Scenario: Returning to the band list lands on the origin band

- **WHEN** the grid is focused at the first column and the user strokes horizontally back toward the band list while drifting vertically
- **THEN** the focus crosses back to the band list on the **same** band the user came from, with no band switch from the drift

#### Scenario: A fresh vertical stroke after returning switches bands

- **WHEN** the user has crossed back to the band list and then makes a fresh, deliberate vertical stroke
- **THEN** the active band changes to the adjacent band (the lock having re-armed after the crossing settled)

#### Scenario: Grid navigation steps one axis at a time

- **WHEN** the grid is focused and the user strokes diagonally
- **THEN** the selection steps along the committed (dominant) axis only — between items or between rows — not diagonally

### Requirement: Wider acceptance for crossing from the band rail into the items

While the band list is focused, the **rightward** (into-items) direction SHALL use a **wider** acceptance cone than band switching, so an up/down-and-right stroke commits to **entering the items** (crossing the focus into the grid) rather than switching a band — a bigger "crossing triangle." A clearly-vertical stroke (steeper than the wider cone) SHALL still switch bands. This widening SHALL apply only while the band list is focused; once in the grid the wedge SHALL be symmetric again.

#### Scenario: An up-and-right stroke enters the items, not the band above

- **WHEN** the band list is focused and the user strokes toward the items while drifting upward, at an angle inside the wider crossing cone
- **THEN** the focus crosses into the current band's items (item movement) and the active band does not change

#### Scenario: A clearly-vertical stroke still switches bands

- **WHEN** the band list is focused and the user strokes steeply (steeper than the wider crossing cone), e.g. nearly straight up or down
- **THEN** the active band switches (the crossing widening does not swallow a deliberate band move)
