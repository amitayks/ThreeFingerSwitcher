## MODIFIED Requirements

### Requirement: Lift fires only when armed
Lifting the fingers SHALL fire the currently armed item; if no item is armed, lifting SHALL dismiss the overlay without firing anything. A quick scrub-and-lift (no dwell) SHALL therefore never fire an item. The overlay SHALL be ordered out **before** the armed item is fired, so an action that switches Spaces (e.g. Next/Previous Space) does not carry the still-visible overlay onto the destination Space (the panel can join all Spaces, so firing first would leave it lingering there).

An **AI command item** is an exception to the order-out-before-fire rule: firing it does NOT dismiss the overlay. Instead, firing **begins the command and opens its streaming preview canvas**, leaving the overlay visible; the command then resolves through the AI command preview-and-commit behavior (a fresh four-finger **down** swipe commits, a fresh four-finger **horizontal** swipe discards) rather than completing on this first lift. Because the firing lift has already raised the fingers, the canvas is resolved by a *new* swipe, never by re-lifting; a stray lift while the canvas is open is a no-op. The order-out-before-fire rule continues to apply to items that complete on lift (launches, Space switches, paste-on-fire).

#### Scenario: Armed lift fires
- **WHEN** an item is armed and the fingers lift
- **THEN** that item is fired and the overlay hides

#### Scenario: Unarmed lift dismisses
- **WHEN** the fingers lift while no item is armed
- **THEN** the overlay hides and nothing is fired

#### Scenario: Regret path
- **WHEN** an item is armed and the user keeps swiping off it, then lifts
- **THEN** nothing is fired and the overlay hides

#### Scenario: Space-switch action does not drag the overlay along
- **WHEN** an armed Next/Previous Space item is fired on lift
- **THEN** the overlay is dismissed before the Space switch, and it does not appear on the destination Space

#### Scenario: Armed AI command lift opens the preview canvas
- **WHEN** an armed AI command item is lifted
- **THEN** the command begins, the overlay stays visible, and its streaming preview canvas appears instead of the overlay dismissing

## ADDED Requirements

### Requirement: AI command streaming preview canvas
When an AI command is fired, the overlay SHALL present a preview canvas (reusing the master-detail preview surface) into which the model's result is **streamed incrementally** as it is generated. The captured front app SHALL remain frontmost throughout (the overlay stays non-activating), and the canvas SHALL show a loading state while the model is loading or before the first tokens arrive.

#### Scenario: Result streams into the canvas
- **WHEN** an AI command is generating
- **THEN** the preview canvas fills with the result incrementally rather than only at completion

#### Scenario: Loading is shown before tokens
- **WHEN** the model is loading or has not yet produced output
- **THEN** the canvas shows a loading state rather than appearing blank or frozen

#### Scenario: Front app stays focused
- **WHEN** the preview canvas is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

### Requirement: Swipe-to-resolve (commit / discard) for AI commands
After an AI command's result is shown in the preview canvas, a fresh four-finger **down swipe SHALL commit** the result (routing it per the command's output target — paste/replace, or run the task; "bringing the result into the document") and a fresh four-finger **horizontal swipe (deliberate excursion) SHALL discard** it (cancelling any in-flight generation and writing nothing). Committing or discarding SHALL then dismiss the overlay. A down swipe before the result is committable (still loading or streaming) SHALL be ignored — the user waits — while a horizontal discard SHALL be honored at any time. An **up** swipe SHALL be ignored, so a stray upward motion never throws the result away. Because the firing lift has already raised the fingers, resolution is always a new swipe; a re-lift while the canvas is open commits nothing.

#### Scenario: Down swipe commits
- **WHEN** the result is committable and the user swipes down
- **THEN** the result is routed to the command's output target and the overlay hides

#### Scenario: Down swipe before ready is ignored
- **WHEN** the user swipes down while the model is still loading or streaming
- **THEN** nothing is committed and the canvas stays open until the result is ready

#### Scenario: Horizontal swipe discards and cancels
- **WHEN** the result is streaming or shown and the user swipes horizontally to discard
- **THEN** generation is cancelled, nothing is written, and the overlay hides

#### Scenario: Up swipe is ignored
- **WHEN** the user swipes up while the canvas is open
- **THEN** nothing is committed or discarded and the canvas stays open

### Requirement: Armed-confirmation state for side-effecting tasks (when enabled)
For an AI command whose output is a side-effecting task **with `confirmBeforeRun` enabled** (the default for side-effecting tasks), the preview canvas SHALL enter a distinct **armed-confirmation ("review the action") state** that displays the parsed action's concrete fields before it can be committed; the side effect SHALL fire only from this confirmed commit. When `confirmBeforeRun` is disabled for the command, the canvas SHALL NOT require this extra state and the task commits on the normal commit (down) swipe. A horizontal discard swipe SHALL always cancel with no side effect.

#### Scenario: Task shows the parsed action before firing (review enabled)
- **WHEN** a side-effecting task whose command has confirmation enabled has produced its parsed action
- **THEN** the canvas enters the armed-confirmation state showing the action's fields, and nothing is applied yet

#### Scenario: Confirm commit fires the side effect
- **WHEN** the user commits from the armed-confirmation state
- **THEN** the task executes its side effect and the overlay hides

#### Scenario: Review disabled commits without the extra state
- **WHEN** a side-effecting task whose command has confirmation disabled is committed
- **THEN** the task executes on the normal commit (down) swipe without a separate armed-confirmation state

#### Scenario: Discard cancels the side effect
- **WHEN** the user swipes horizontally to discard before the side effect fires
- **THEN** no side effect occurs and the overlay hides
