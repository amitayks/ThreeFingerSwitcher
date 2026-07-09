## ADDED Requirements

### Requirement: Live gesture preview surface in the Hub
The Hub SHALL provide a reusable **gesture preview** surface that leads each gesture-driven feature page: a stylized trackpad pad (glowing fingertip dots) beneath a **static** miniature of the feature's actual overlay. The preview SHALL play itself — a ghost hand looping the feature's gesture (the macOS System-Settings idiom) — as **pure autoplay**: it reads no input and does **not** manipulate the miniature's model (the miniature is seeded once and rendered static). The preview SHALL reuse the First Touch wizard's pad and motion vocabulary (`FingerDotsPad`, the pose driver, `PulseHalo`) and the real overlay views, so the Hub and the runtime read as one app. The preview SHALL request **no new permission** and SHALL relocate **no gesture**.

> This is deliberately autoplay-only: the earlier live-tracking/**rehearse** integration (the user's real fingers replacing the ghost and driving the miniature) and the **driven form** (a per-frame clock stepping the caller's real overlay model in sync) were removed. Both kept a perpetual `TimelineView`/Observation/Auto-Layout loop alive inside the retained, hidden Hub window and pinned the main thread — see `docs/postmortem-idle-cpu-spin.md`.

#### Scenario: Gesture page opens with a self-looping preview
- **WHEN** the user opens a gesture-driven feature page in the Hub
- **THEN** a trackpad pad with a looping ghost hand and a static overlay miniature appears above the page's controls, playing the feature's gesture without any input

#### Scenario: Preview is presentation-only
- **WHEN** the preview is on screen
- **THEN** it loops the feature's currently-bound gesture over the static miniature and never reads touch, never manipulates the miniature's model, and never fires the feature

#### Scenario: Band-feature preview demonstrates the full path
- **WHEN** the user opens a band-based feature page (Clipboard, Files, or AI Commands)
- **THEN** the preview's loop plays the whole journey — the four-finger launcher opening, traversing across to that feature's band, and then the band's in-surface gesture — not a single isolated excursion, and the static miniature is seeded showing that feature's band

### Requirement: The gesture preview must not consume CPU while the Hub is not visible
The self-playing gesture preview SHALL run its animation clock **only while the Hub window is genuinely on screen**. When the Hub is closed, miniaturized, ordered-out, or occluded, the preview SHALL stop ticking entirely — it SHALL NOT keep a periodic `TimelineView` running, invalidate layout, or otherwise consume the main thread — so an idle app with the Hub not visible costs zero. Visibility SHALL be determined from **real window state** (an authoritative on-screen/off-screen flag the Hub controller sets on show/hide, reinforced by the window's `occlusionState`), **not** from SwiftUI `.onAppear`/`.onDisappear`, which do not fire reliably for a Hub window that is kept alive (retained) after being hidden. This requirement exists because a perpetual preview loop inside the retained, hidden Hub window pinned the main thread at ~100% CPU — see `docs/postmortem-idle-cpu-spin.md`.

#### Scenario: A closed (but retained) Hub does not spin
- **WHEN** the Hub window is closed or miniaturized while the app keeps running
- **THEN** every gesture preview stops its clock and the app is idle — no perpetual `TimelineView` tick or layout invalidation on the main thread

#### Scenario: An occluded Hub does not spin
- **WHEN** the Hub window is fully covered by another window (occluded)
- **THEN** the previews stop ticking until the Hub is visible again

#### Scenario: Reopening the Hub resumes the previews
- **WHEN** the Hub returns to the screen (reopen / deminiaturize)
- **THEN** the previews resume looping their gesture

### Requirement: Hovering a binding demos that gesture
When a feature page offers configurable gesture bindings, **hovering** a binding option (the dropdown that maps an action to an excursion) SHALL switch the preview's loop to demonstrate that **candidate** excursion, so the user sees the move before choosing it. Leaving the hover SHALL return the loop to the currently-bound gesture.

#### Scenario: Hover-to-demo plays the candidate excursion
- **WHEN** the user hovers a binding option for an action
- **THEN** the preview loops the hovered excursion (e.g. a swipe-right) in place of the current default

#### Scenario: Leaving the hover restores the bound gesture
- **WHEN** the user moves off the binding option without choosing it
- **THEN** the preview returns to looping the currently-bound gesture

### Requirement: Previews render the real overlay, not an abstract stand-in
A gesture page's preview miniature SHALL be the **actual overlay view**, seeded once with the user's real content — exactly as the First Touch wizard presents it — so the user sees how the feature really looks. The miniature is **static** (the autoplay ghost hand plays over it; its model is not driven):
- The **Switcher** preview SHALL render a mini `SwitcherView` over the user's **currently open windows** (real `WindowInfo` rows + their live thumbnails when Screen Recording is granted, icons otherwise), at the switcher's true real-proportion sizing — a scaled-down version of the real grid.
- The **Launcher** preview SHALL render the **real `LauncherView`** seeded with the user's actual bands, resting on the home band.
- The **band** pages (Clipboard / Files / AI) SHALL render the real `LauncherView` seeded **showing their band** (the last band), reusing the same seeded model, so the static miniature already displays the band the autoplay journey traverses to.
The Hub SHALL obtain this real content through the coordinator (the same `realWindowRows` / `seedThumbnails` / `launcherBands` providers the wizard uses); it SHALL degrade gracefully (icons when no thumbnails, the real bands always) and request no new permission.

#### Scenario: Switcher preview shows the user's real windows
- **WHEN** the user opens the Window Switcher page
- **THEN** the preview shows a mini switcher built from their currently open windows at real proportions (with live thumbnails when available)

#### Scenario: Band preview shows the real launcher on the feature's band
- **WHEN** the user opens a band page (Clipboard / Files / AI)
- **THEN** the static miniature shows the real `LauncherView` seeded with the user's bands, landed on that feature's band

### Requirement: Demonstrations are deterministic directed gestures in the real finger grammar
The ghost-hand demonstration SHALL **perform the actual gesture as a deterministic directed stroke**, not a relentless side-to-side oscillation. A demonstrated swipe SHALL travel decisively from a start toward an end in the action's direction (e.g. a two-finger commit swipe runs from top-middle to center-middle), carrying a slight **angle/arc so it reads as a human hand**, then lift and repeat. The demonstration SHALL portray the product's real **finger-count grammar**, changing the ghost hand's finger count through the journey:
- **open** the platform with **three** fingers (switcher) or **four** fingers (launcher and its bands),
- **navigate / traverse / move the canvas / scrub the clipboard** with **two** fingers,
- **four** fingers **dismiss** an open launcher surface.
The demonstration plays over the **static** miniature (it does not step the miniature's model in sync — that live-driving was removed with the driven form; see `docs/postmortem-idle-cpu-spin.md`).

For the **launcher and its band pages**, the demonstration SHALL portray the *real usage story*, not a generic stroke: (1) the four-finger **open** stroke SHALL travel roughly the **activation distance** (`launcherActivationThreshold`) before the launcher appears; (2) the hand SHALL then **drop from four fingers to two on continuous contact** — two fingers lift while two stay down — rather than fully releasing and re-pressing; (3) the remaining two fingers SHALL continue in the navigate/traverse direction. The demonstration SHALL always play at **preview scale** (it SHALL NOT grow).

#### Scenario: A demonstrated swipe performs a directed stroke
- **WHEN** the preview demonstrates a two-finger commit
- **THEN** the ghost fingers stroke decisively from top-middle toward center-middle at a natural hand angle, then lift and repeat — not an endless left-right ping-pong

#### Scenario: The demonstration follows the real finger-count grammar
- **WHEN** a band-page preview plays its journey
- **THEN** it opens with four fingers, traverses and acts within the surface with two fingers, and a four-finger stroke dismisses the surface — the finger count changes through the demo to match the real gesture grammar

#### Scenario: The launcher demo hands off from four fingers to two on continuous contact
- **WHEN** the launcher (or band) preview's open stroke completes the activation-distance walk
- **THEN** two ghost fingers lift while two stay in contact and continue the navigate phase — the demo never fully releases and re-presses between opening and navigating

### Requirement: The demonstration's open stroke reflects the live activation threshold
The launcher / switcher demonstration's **open stroke** SHALL scale its travel with the configured **activation distance** (`launcherActivationThreshold` / `activationThreshold`), read from **settings as the single source of truth**, and SHALL update **live** when the tunable changes without reopening the page — so the demonstrated opening swipe reads as "just enough to trigger." (The other launcher tunables — item/band step, dwell — governed the removed in-sync model driving and the removed grow-on-rehearse; they no longer affect the static preview.)

#### Scenario: Raising the activation threshold lengthens the demo's open walk
- **WHEN** the user increases the activation-threshold slider
- **THEN** the demo's open stroke travels a correspondingly longer distance, updating live

### Requirement: Gestureless pages are out of scope for the preview
Feature pages with **no gesture** (Keyboard Language, Devices, Setup, General) SHALL NOT show a gesture preview in this capability — they keep their current header — so the app never fabricates a gesture that does not exist. A later visual refactor MAY give those pages a different illustrative treatment.

#### Scenario: A gestureless page shows no fabricated gesture
- **WHEN** the user opens a page whose feature has no trackpad gesture (e.g. Keyboard Language)
- **THEN** no trackpad/ghost-hand preview is shown for it

### Requirement: The Switcher preview teaches the full gesture as a deterministic story
The Window-Switcher preview SHALL demonstrate the complete switcher gesture as a single deterministic story rather than abstract back-and-forth motion: **three fingers slide** to open (a horizontal swipe whose length tracks the configured **activation threshold**, so it reads as "just enough to trigger"), then **one finger lifts** while the other two keep resting (the ghost hand drops from three fingertips to two **without** a full lift between them), and the two resting fingers **navigate** — **up** to the second Space-row, back **down** to the first, then **sideways** across the windows in the row — before lifting. The story plays over the **static** miniature (the highlight / Space-row reel are seeded, not stepped in sync — the in-sync driving was removed; see `docs/postmortem-idle-cpu-spin.md`). The full story SHALL always play regardless of which switcher sub-features are currently enabled. A compact **action map** SHALL accompany the preview, spelling out the same steps in words.

#### Scenario: The switcher demo performs the connected open-then-lift-one story
- **WHEN** the Window-Switcher preview loops
- **THEN** the ghost hand opens with three fingers, drops to two fingers without lifting the whole hand, moves up to the second Space-row and back, then scrubs sideways across the windows

#### Scenario: The opening swipe reflects the activation threshold
- **WHEN** the user changes the "Activation threshold" control
- **THEN** the length of the demonstrated opening swipe changes to match the new trigger distance

### Requirement: The Switcher preview shows real, scalable, multi-row content
The Window-Switcher preview SHALL render the user's real windows at their true proportions, grouped into **Space-rows** (multi-row), and SHALL reflect the configurable **window size** live: dragging the window-size control SHALL grow or shrink the static preview cards in real time (re-solving the grid), in the same proportion as the real switcher. Two fallbacks SHALL keep the preview alive and teachable: when the user has **at most one** real window (only the Hub is open), the preview SHALL mimic **two icon-only windows**; and when the user has **fewer than two Spaces**, the preview SHALL fabricate a sample second Space-row so the up/down Space part of the story always has a row to reach.

#### Scenario: Windows grow and shrink with the size control
- **WHEN** the user drags the "Window size" control on the Switcher page
- **THEN** the preview's window cards grow or shrink in real time, keeping their true relative proportions

#### Scenario: A user with one window still sees a real-looking switcher
- **WHEN** the user has no other windows open besides the Hub
- **THEN** the preview shows two icon-only windows rather than an empty or abstract scene

#### Scenario: A user with one Space can still be taught the Space move
- **WHEN** the user has fewer than two Spaces
- **THEN** the preview fabricates a sample second Space-row so the demo's "up to the second row, back down" move still plays
