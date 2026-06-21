## MODIFIED Requirements

### Requirement: Swipe-to-resolve (commit / discard) for AI commands
After an AI command's result is shown in the preview canvas, the canvas SHALL be resolved by a fresh **two-finger swipe** whose direction-to-action mapping is the user's **configured canvas binding** (`gesture-bindings`), defaulting to: a **down swipe commits** the result (routing it per the command's output target — paste/replace, or run the task; "bringing the result into the document"), a **horizontal swipe (deliberate excursion) discards** it (cancelling any in-flight generation and writing nothing), and an **up swipe is ignored**. Whichever excursion is bound to **commit** SHALL be honored only when the result is committable; a commit excursion performed before the result is ready (still loading or streaming) SHALL be ignored — the user waits — while a discard SHALL be honored at any time. Committing or discarding SHALL then dismiss the overlay. The resolution swipe SHALL be a **deliberate excursion past a threshold larger than incidental two-finger scrolling**, so reading/scrolling the canvas is not mistaken for a resolve; because the firing lift has already raised the fingers, resolution is always a new swipe, and a re-lift while the canvas is open commits nothing. The **at-top commit guard** SHALL hold for whichever excursion is bound to commit: a commit excursion performed while the canvas is scrolled away from the top SHALL be treated as scrolling, not committing.

This aligns the platform grammar: **four fingers open/dismiss the platform, two fingers act within it** — so the canvas (which is summoned by a two-finger trigger) is also resolved by two fingers.

#### Scenario: Default commit excursion commits
- **WHEN** the result is committable and the user performs the commit-bound excursion (default: two-finger down swipe)
- **THEN** the result is routed to the command's output target and the overlay hides

#### Scenario: Remapped commit excursion commits
- **WHEN** the user has bound commit to a different excursion (e.g. swipe-right) and performs it on a committable result
- **THEN** the result is committed, and the previously-default excursion no longer commits

#### Scenario: Commit excursion before ready is ignored
- **WHEN** the user performs the commit excursion while the model is still loading or streaming
- **THEN** nothing is committed and the canvas stays open until the result is ready

#### Scenario: Discard excursion discards and cancels
- **WHEN** the result is streaming or shown and the user performs the discard-bound excursion (default: two-finger horizontal swipe)
- **THEN** generation is cancelled, nothing is written, and the overlay hides

#### Scenario: Ignore excursion does nothing
- **WHEN** the user performs the excursion bound to ignore (default: up swipe) while the canvas is open
- **THEN** nothing is committed or discarded and the canvas stays open

#### Scenario: Scrolling the canvas is not mistaken for a resolve
- **WHEN** the user scrolls the canvas content with a small two-finger motion below the resolve excursion threshold
- **THEN** the canvas scrolls and neither commit nor discard is triggered (and the sub-threshold scroll is never a bindable excursion)

### Requirement: Files band resolution — open, Open-With, discard

Resolution of a Files-band selection SHALL be **lift-to-open with a defusable commit** (the navigator's reach-in-and-open intent — *not* the AI canvas's review-then-apply), with the **action-to-excursion mapping taken from the user's configured Files-drill binding** (`gesture-bindings`), defaulting to: **lift = open**, **+1-finger lift = Open-With**, **four-finger horizontal swipe-away = discard**. Performing the **open**-bound excursion on a highlighted entry SHALL **open** it — a file in its default application, a folder as a Finder window — on the current Space; the open SHALL be **defusable** for a brief window so a discard issued before it fires opens nothing. The **Open-With**-bound excursion SHALL instead arm **Open-With**, presenting the **relevant-apps picker** for the highlighted file, which the user navigates (vertical) and lifts to choose; choosing opens the file with that app. The **discard**-bound excursion SHALL **discard** — defusing any pending open and writing nothing — and SHALL **never terminate an already-running application**, regardless of which excursion is bound to it. Resolution SHALL be **one-shot**: once opened or discarded, a stray re-lift is a no-op. The captured front app SHALL remain frontmost throughout. The default `+1-finger` Open-With excursion SHALL remain a **relative** +1 versus the current relaxed contact baseline.

#### Scenario: Open excursion opens the highlighted entry
- **WHEN** the user performs the open-bound excursion (default: lift) on a highlighted file (or folder)
- **THEN** it opens in its default app (or as a Finder window) on the current Space

#### Scenario: Discard excursion defuses before it opens and never kills a running app
- **WHEN** the user performs the discard-bound excursion (default: four-finger horizontal swipe-away) instead of opening (or within the defuse window)
- **THEN** nothing opens, any pending open is defused, and no running application is terminated

#### Scenario: Open-With excursion opens the picker
- **WHEN** the user performs the Open-With-bound excursion (default: +1-finger lift) on a file
- **THEN** the relevant-apps picker opens, which the user navigates and lifts to choose the opening app

#### Scenario: Resolution is one-shot
- **WHEN** the selection has already been opened or discarded
- **THEN** a subsequent stray re-lift does nothing
