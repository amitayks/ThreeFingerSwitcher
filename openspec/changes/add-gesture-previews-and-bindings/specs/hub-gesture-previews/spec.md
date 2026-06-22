## ADDED Requirements

### Requirement: Live gesture preview surface in the Hub
The Hub SHALL provide a reusable **gesture preview** surface that leads each gesture-driven feature page: a stylized trackpad pad (glowing fingertip dots) beneath a live miniature of the feature's actual overlay. The preview SHALL play itself by default — a ghost hand looping the feature's gesture (the macOS System-Settings idiom) — with the miniature reacting to the looped motion. The preview SHALL reuse the First Touch wizard's pad and motion vocabulary (`FingerDotsPad`, the pose driver, `PulseHalo`/`BreathingGlowBackdrop`/`ShimmerSweep`) and the real overlay views, so the Hub and the runtime read as one app. The preview SHALL request **no new permission** and SHALL relocate **no gesture**.

#### Scenario: Gesture page opens with a self-looping preview
- **WHEN** the user opens a gesture-driven feature page in the Hub
- **THEN** a trackpad pad with a looping ghost hand and a live overlay miniature appears above the page's controls, playing the feature's gesture without any input

#### Scenario: Preview is presentation-only by default
- **WHEN** the preview is idle (no real touch)
- **THEN** it loops the feature's currently-bound gesture and never fires the feature

#### Scenario: Band-feature preview demonstrates the full path
- **WHEN** the user opens a band-based feature page (Clipboard, Files, or AI Commands)
- **THEN** the preview's loop plays the whole journey — the four-finger launcher opening, traversing across to that feature's band, and then the band's in-surface gesture — not a single isolated excursion

### Requirement: Preview reacts to the user's real trackpad (rehearse)
While a gesture preview is on screen and focused, the Hub SHALL subscribe to the live trackpad touch feed and let the user **rehearse** the gesture: the user's real fingertips SHALL replace the ghost hand on the pad and drive the live miniature, and performing a **bound** excursion SHALL play that excursion's **result** in the miniature (e.g. the canvas text commits, or the surface dismisses). Touch capture SHALL be gated to **two or more fingers** — a single-finger move SHALL never drive the preview or trigger anything.

#### Scenario: Real fingers take over the preview
- **WHEN** the user places two or more fingers on the trackpad while the preview is focused
- **THEN** the ghost hand yields and the user's contacts drive the pad and the live miniature

#### Scenario: Performing a bound gesture shows its result in the miniature
- **WHEN** the user performs an excursion bound to an action (e.g. the canvas commit) while rehearsing
- **THEN** the miniature plays that action's result (commit / dismiss) as a preview, without affecting the real app

#### Scenario: A single finger never triggers the preview
- **WHEN** the user moves a single finger on the trackpad
- **THEN** the preview ignores it and nothing is demonstrated or triggered

### Requirement: Rehearsing in the Hub does not fire the real feature
While a preview is being rehearsed on the real trackpad, the live gesture recognizer SHALL **not** also act on that gesture — rehearsing a swipe in the Hub SHALL NOT open the launcher, switch a window, or fire an AI command. The Hub SHALL suppress real gesture handling for the duration of the rehearsal (the runtime-gesture-ownership precedent) and SHALL resume normal handling when the preview loses focus or the fingers lift.

#### Scenario: Rehearsal is isolated from the runtime
- **WHEN** the user rehearses a feature's gesture inside the Hub preview
- **THEN** the real feature is not activated and the runtime gesture is suppressed for that rehearsal

#### Scenario: Normal handling resumes after rehearsal
- **WHEN** the preview loses focus or the user lifts their fingers
- **THEN** the runtime gesture handling resumes and the trackpad behaves normally outside the Hub

### Requirement: Hovering a binding demos that gesture
When a feature page offers configurable gesture bindings, **hovering** a binding option (the dropdown that maps an action to an excursion) SHALL switch the preview's loop to demonstrate that **candidate** excursion, so the user sees the move before choosing it. Leaving the hover SHALL return the loop to the currently-bound gesture.

#### Scenario: Hover-to-demo plays the candidate excursion
- **WHEN** the user hovers a binding option for an action
- **THEN** the preview loops the hovered excursion (e.g. a swipe-right) in place of the current default

#### Scenario: Leaving the hover restores the bound gesture
- **WHEN** the user moves off the binding option without choosing it
- **THEN** the preview returns to looping the currently-bound gesture

### Requirement: Previews render the real overlay, not an abstract stand-in
A gesture page's preview miniature SHALL be the **actual overlay view**, seeded with the user's real content — exactly as the First Touch wizard presents it — so the user sees how the feature really looks:
- The **Switcher** preview SHALL render a mini `SwitcherView` over the user's **currently open windows** (real `WindowInfo` rows + their live thumbnails when Screen Recording is granted, icons otherwise), at the switcher's true real-proportion sizing — a scaled-down version of the real grid.
- The **Launcher** preview SHALL render the **real `LauncherView`** seeded with the user's actual bands; when the demo plays the four-finger trigger, the launcher SHALL **launch in** (appear/morph on) the mini screen, not sit statically.
- The **band** pages (Clipboard / Files / AI) SHALL render the real `LauncherView` showing their band (the journey traverses to it), reusing the same seeded model.
The Hub SHALL obtain this real content through the coordinator (the same `realWindowRows` / `seedThumbnails` / `launcherBands` providers the wizard uses); it SHALL degrade gracefully (icons when no thumbnails, the real bands always) and request no new permission.

#### Scenario: Switcher preview shows the user's real windows
- **WHEN** the user opens the Window Switcher page
- **THEN** the preview shows a mini switcher built from their currently open windows at real proportions (with live thumbnails when available)

#### Scenario: Launcher preview shows the real launcher launching
- **WHEN** the launcher preview plays the four-finger trigger
- **THEN** the real `LauncherView` (seeded with the user's bands) launches in on the mini screen, as in the onboarding playground

### Requirement: Demonstrations are deterministic directed gestures in the real finger grammar
The ghost-hand demonstration SHALL **perform the actual gesture as a deterministic directed stroke**, not a relentless side-to-side oscillation. A demonstrated swipe SHALL travel decisively from a start toward an end in the action's direction (e.g. a two-finger commit swipe runs from top-middle to center-middle), carrying a slight **angle/arc so it reads as a human hand**, then lift and repeat. The demonstration SHALL portray the product's real **finger-count grammar**, changing the ghost hand's finger count through the journey:
- **open** the platform with **three** fingers (switcher) or **four** fingers (launcher and its bands),
- **navigate / traverse / move the canvas / scrub the clipboard** with **two** fingers,
- **four** fingers **dismiss** an open launcher surface.
The miniature's selection/highlight (and the launcher's launch/dismiss) SHALL advance **in sync** with the demonstrated strokes, so the gesture and its effect read as one.

#### Scenario: A demonstrated swipe performs a directed stroke
- **WHEN** the preview demonstrates a two-finger commit
- **THEN** the ghost fingers stroke decisively from top-middle toward center-middle at a natural hand angle, then lift and repeat — not an endless left-right ping-pong

#### Scenario: The demonstration follows the real finger-count grammar
- **WHEN** a band-page preview plays its journey
- **THEN** it opens with four fingers, traverses and acts within the surface with two fingers, and a four-finger stroke dismisses the surface — the finger count changes through the demo to match the real gesture grammar

#### Scenario: The miniature reacts in sync with the stroke
- **WHEN** a navigate stroke is demonstrated
- **THEN** the miniature's highlight/selection steps in time with that stroke (and the launcher launches on the open stroke), so the gesture and its effect are shown together

### Requirement: Gestureless pages are out of scope for the preview
Feature pages with **no gesture** (Keyboard Language, Devices, Setup, General) SHALL NOT show a gesture preview in this capability — they keep their current header — so the app never fabricates a gesture that does not exist. A later visual refactor MAY give those pages a different illustrative treatment.

#### Scenario: A gestureless page shows no fabricated gesture
- **WHEN** the user opens a page whose feature has no trackpad gesture (e.g. Keyboard Language)
- **THEN** no trackpad/ghost-hand preview is shown for it
