## ADDED Requirements

### Requirement: Live gesture preview surface in the Hub
The Hub SHALL provide a reusable **gesture preview** surface that leads each gesture-driven feature page: a stylized trackpad pad (glowing fingertip dots) beneath a live miniature of the feature's actual overlay. The preview SHALL play itself by default — a ghost hand looping the feature's gesture (the macOS System-Settings idiom) — with the miniature reacting to the looped motion. The preview SHALL reuse the First Touch wizard's pad and motion vocabulary (`FingerDotsPad`, the pose driver, `PulseHalo`/`BreathingGlowBackdrop`/`ShimmerSweep`) and the real overlay views, so the Hub and the runtime read as one app. The preview SHALL request **no new permission** and SHALL relocate **no gesture**.

#### Scenario: Gesture page opens with a self-looping preview
- **WHEN** the user opens a gesture-driven feature page in the Hub
- **THEN** a trackpad pad with a looping ghost hand and a live overlay miniature appears above the page's controls, playing the feature's gesture without any input

#### Scenario: Preview is presentation-only by default
- **WHEN** the preview is idle (no real touch)
- **THEN** it loops the feature's currently-bound gesture and never fires the feature

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

### Requirement: Gestureless pages are out of scope for the preview
Feature pages with **no gesture** (Keyboard Language, Devices, Setup, General) SHALL NOT show a gesture preview in this capability — they keep their current header — so the app never fabricates a gesture that does not exist. A later visual refactor MAY give those pages a different illustrative treatment.

#### Scenario: A gestureless page shows no fabricated gesture
- **WHEN** the user opens a page whose feature has no trackpad gesture (e.g. Keyboard Language)
- **THEN** no trackpad/ghost-hand preview is shown for it
