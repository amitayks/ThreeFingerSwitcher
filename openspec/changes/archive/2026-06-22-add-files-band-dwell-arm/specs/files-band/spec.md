## ADDED Requirements

### Requirement: Dwell-to-arm gates Files-band resolution

The Files band SHALL arm by **dwell**, like every other launcher surface (mirroring *launcher-overlay → Dwell-to-arm with feedback*). Resting the highlight on a row — in the navigator **or** in any sub-column (the action menu, the Open-With picker, the "Open in ▸" app grid) — for at least the configured dwell-to-arm duration SHALL **arm** that row. Arming SHALL be signalled by the existing best-effort haptic **arm tick** and a visual **charge-ring** that fills over the dwell duration and locks when armed. Moving the highlight — a highlight step, a depth descend/ascend, an async re-list that shifts the highlighted row, or a sub-column move — SHALL **reset the dwell and disarm**. Holding at the trackpad edge (auto-drill / highlight auto-repeat) SHALL re-charge on every step, so it never arms mid-scroll. Adding the `+1` finger SHALL NOT reset the dwell (it does not change the highlighted item); **entering** a sub-column SHALL begin a fresh dwell on its first row.

This **supersedes** the band's prior resolve-on-lift-without-arming behavior, and supersedes the band's "add no new haptics" note **for the arm moment only** — the arm tick is the product's existing single haptic ("moments of arrival"), not a new pattern; no per-scrub, per-descend, or per-commit haptics are added. The dwell duration is the same `dwellToArmDuration` that governs the rest of the launcher (no Files-specific setting).

#### Scenario: Dwell arms the highlighted row

- **WHEN** the highlight rests on a Files row for at least the dwell duration
- **THEN** the row becomes armed, the arm haptic fires (if available), and the charge-ring shows armed

#### Scenario: Charge-ring tracks partial dwell

- **WHEN** the highlight has rested on a row for less than the dwell duration
- **THEN** the charge-ring is partially filled and the row is not armed

#### Scenario: Moving the highlight disarms

- **WHEN** a row is armed and the user steps the highlight, descends/ascends, or scrubs a sub-column to another row
- **THEN** the previous row disarms, its ring empties, and the new row begins its own dwell

#### Scenario: Auto-drill never arms mid-scroll

- **WHEN** the user holds at the trackpad edge and the tree auto-drills (or the highlight auto-repeats)
- **THEN** the dwell re-charges on every step and no row arms until the motion settles

#### Scenario: Adding the +1 finger preserves the arm

- **WHEN** a row is armed and the user adds the `+1` finger without moving the highlight
- **THEN** the row stays armed (the dwell is not reset)

### Requirement: Files lift fires only when armed

A **committing** Files lift SHALL fire **only when the highlighted row is armed**; if no row is armed, lifting SHALL **dismiss the overlay** without acting (mirroring *launcher-overlay → Lift fires only when armed*). This SHALL apply to every committing resolution — the default lift (**deliver** to the captured front app, or **open** when the lift is rebound), the `+1`-finger lift (**open the action menu**), and a **lift that commits a sub-column row** (an action-menu row, an Open-With / app-grid app). A quick scrub-and-lift (no dwell) SHALL therefore never deliver, open, open the menu, or commit a row. The four-finger **discard** (back-out) SHALL **never** be gated by arm — it backs out one level (or dismisses) armed or not, and SHALL NOT terminate a running application (the *Defusable open* rule is unchanged). The arm gate SHALL sit **before** the action fires, so the existing defuse window and observable-failure behavior are unchanged.

#### Scenario: Armed lift acts

- **WHEN** a Files row is armed and the fingers lift
- **THEN** the committing action fires (deliver / open / open-menu / commit the row) and the overlay resolves as before

#### Scenario: Unarmed lift dismisses

- **WHEN** the fingers lift while no Files row is armed
- **THEN** the overlay hides and nothing is delivered, opened, or committed

#### Scenario: Scrub-and-lift never delivers

- **WHEN** the user scrubs onto a file and lifts before the dwell completes
- **THEN** nothing is delivered to the front app and the overlay dismisses

#### Scenario: The +1-finger menu requires an armed row

- **WHEN** the user adds the `+1` finger and lifts on a row that has not armed
- **THEN** the action menu does not open and the overlay dismisses

#### Scenario: Discard is never gated by arm

- **WHEN** the user issues the four-finger discard while no row is armed
- **THEN** the back-out / dismiss happens normally and no running application is terminated
