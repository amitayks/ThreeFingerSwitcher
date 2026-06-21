## ADDED Requirements

### Requirement: User-configurable resolution-gesture bindings
The app SHALL let the user choose **which excursion performs which action** for the **resolution** gestures of remappable open surfaces — the AI command canvas, the Files-band drill, and the window switcher's scrub axes. Each surface SHALL have its own **action set** and its own **excursion vocabulary** (the surfaces are deliberately distinct grammars and SHALL NOT be unified into one remap). Bindings SHALL be **persisted** and SHALL **default to exactly today's behavior**. The bindings SHALL be consumed at the existing raw-direction seam (the recognizer's emitted direction is unchanged); only the action a direction maps to is configurable.

- **AI canvas:** actions `{commit, dismiss, ignore}` ← excursions `{swipe up, swipe down, swipe left, swipe right}` (two-finger). Default: down = commit, horizontal = dismiss, up = ignore.
- **Files drill:** actions `{open, Open-With, discard}` ← excursions `{lift, +1-finger lift, four-finger horizontal}`. Default: lift = open, +1-finger = Open-With, four-finger horizontal = discard.
- **Switcher:** per-axis scrub `{windows axis, Spaces axis}` ∈ `{normal, reversed}`. Default: both normal.

#### Scenario: Default bindings reproduce today's grammar
- **WHEN** the user has never changed a binding
- **THEN** every surface resolves exactly as it does today (canvas down = commit, etc.)

#### Scenario: A remapped excursion performs the bound action
- **WHEN** the user binds the canvas commit to swipe-right and then swipes right on a ready canvas result
- **THEN** the result is committed (and no longer discarded), and the old default no longer commits

#### Scenario: Surfaces keep separate vocabularies
- **WHEN** the user configures the Files-drill bindings
- **THEN** only Files-drill excursions/actions are offered there, independent of the canvas bindings

### Requirement: Bindings are mutually exclusive per surface
Within a single surface, two actions SHALL NOT share one excursion. Assigning an excursion already held by another action SHALL resolve the conflict deterministically (swap the two actions' excursions, or present the taken excursion as unavailable) so the binding set is always **a one-to-one mapping**. The conflict resolution SHALL be a pure, unit-testable verdict.

#### Scenario: Assigning a taken excursion resolves the conflict
- **WHEN** swipe-down is bound to commit and the user assigns swipe-down to dismiss
- **THEN** the binding set is renormalized so no excursion maps to two actions (e.g. commit takes dismiss's former excursion)

#### Scenario: The mapping stays one-to-one
- **WHEN** any binding assignment is made
- **THEN** the resulting per-surface mapping has at most one action per excursion

### Requirement: Reserved and invalid excursions are never bindable
The binding vocabularies SHALL exclude excursions that must keep a fixed meaning: **single-finger** motion (never a trigger anywhere), and on the AI canvas the **sub-threshold two-finger pan** that scrolls/reads the canvas (below the resolve excursion threshold) SHALL remain "read the canvas" and SHALL NOT be offered as a bindable excursion. **Activation** gestures (which finger-count opens which platform) SHALL NOT be remappable — bindings cover resolution within an already-open surface only.

#### Scenario: Single-finger is not offered as a binding
- **WHEN** the user opens a binding editor
- **THEN** no single-finger excursion is available to bind

#### Scenario: Reading the canvas stays unbindable
- **WHEN** the user opens the canvas binding editor
- **THEN** the sub-threshold two-finger scroll is not offered as a bindable excursion and keeps scrolling the canvas

#### Scenario: Activation finger-counts are not remappable
- **WHEN** the user looks for a way to change which finger-count opens the launcher vs. the switcher
- **THEN** no such binding is offered (the open/dismiss-vs-act-within finger grammar is fixed)

### Requirement: Load-bearing resolution guards are binding-independent
Safety guards on a resolution action SHALL apply to **whichever** excursion is bound to that action. The AI canvas commit SHALL still require the canvas to be **scrolled to the top** (a commit-bound excursion mid-scroll is the user scrolling, not committing). The Files-drill discard SHALL **never terminate an already-running application**, regardless of which excursion is bound to it.

#### Scenario: Commit guard survives a remap
- **WHEN** the canvas commit is rebound to a different excursion and performed while the canvas is scrolled away from the top
- **THEN** nothing is committed (the at-top guard still holds)

#### Scenario: Discard never kills a running app after a remap
- **WHEN** the Files discard is rebound and performed against an entry whose target app is already running
- **THEN** the pending open is defused but the running application is not terminated
