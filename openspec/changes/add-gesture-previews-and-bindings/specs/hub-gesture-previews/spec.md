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

For the **launcher and its band pages**, the demonstration SHALL portray the *real usage story*, not a generic stroke: (1) the four-finger **open** stroke SHALL travel exactly the **activation distance** (`launcherActivationThreshold`) before the launcher appears; (2) the hand SHALL then **drop from four fingers to two on continuous contact** — two fingers lift while two stay down — rather than fully releasing and re-pressing; (3) the remaining two fingers SHALL continue, stepping items horizontally and bands vertically. The idle demonstration SHALL stay at **preview scale** (it SHALL NOT grow — growing is reserved for rehearse, per the grow requirement below).

#### Scenario: A demonstrated swipe performs a directed stroke
- **WHEN** the preview demonstrates a two-finger commit
- **THEN** the ghost fingers stroke decisively from top-middle toward center-middle at a natural hand angle, then lift and repeat — not an endless left-right ping-pong

#### Scenario: The demonstration follows the real finger-count grammar
- **WHEN** a band-page preview plays its journey
- **THEN** it opens with four fingers, traverses and acts within the surface with two fingers, and a four-finger stroke dismisses the surface — the finger count changes through the demo to match the real gesture grammar

#### Scenario: The miniature reacts in sync with the stroke
- **WHEN** a navigate stroke is demonstrated
- **THEN** the miniature's highlight/selection steps in time with that stroke (and the launcher launches on the open stroke), so the gesture and its effect are shown together

#### Scenario: The launcher demo hands off from four fingers to two on continuous contact
- **WHEN** the launcher (or band) preview's open stroke completes the activation-distance walk
- **THEN** two ghost fingers lift while two stay in contact and continue the navigate phase — the demo never fully releases and re-presses between opening and navigating

### Requirement: The launcher and band previews morph into the user's ACTUAL launcher while rehearsed
While a launcher or band-page preview is being **rehearsed** on the real trackpad and the user performs the surface's **open** gesture (four fingers crossing the activation distance), the small preview SHALL **morph into the user's ACTUAL launcher** — the **real `LauncherView` at its native 1:1 size** — presented **floating over the page** on a dim backdrop, so the user can **navigate the real launcher themselves and learn it**. The grown launcher SHALL be the genuine launcher geometry (`LauncherGridLayout`), at **actual size**, and SHALL be **scaled down only if the Hub window cannot fit it** (never clipped); whenever the window can fit the launcher it SHALL be shown at exactly actual size. The user's continuing contacts SHALL **drive it live** (the `onRehearse` seam), exactly as the First Touch wizard's playground does under the hand. The grown launcher SHALL remain **static / non-firing**: dwell-arm MAY tick, but a lift SHALL only **recede the launcher and disarm** — it SHALL NEVER launch an item, open an app, switch a window, or perform any real action. The morph SHALL be **rehearse-only**: the idle self-playing demonstration SHALL stay at small preview scale and SHALL NOT grow.

#### Scenario: Performing the real open gesture presents the actual launcher
- **WHEN** the user puts four fingers down and crosses the activation distance while the launcher preview is the active rehearse target
- **THEN** the small preview morphs into the real launcher at its actual size, floating over the page, and the user's continuing two-finger motion navigates it live

#### Scenario: A lift recedes the actual launcher and never fires
- **WHEN** the user lifts after rehearsing (even on an armed item)
- **THEN** the grown launcher recedes and disarms, and no item is launched and no app is opened

#### Scenario: The idle demo never grows
- **WHEN** no real touch is present and the demo is self-playing
- **THEN** the launcher stays at small preview scale (the morph into the actual launcher happens only under real rehearsing fingers)

### Requirement: Previews reflect the live launcher tunables
The launcher and band-page previews SHALL reflect the user's launcher tunables in **both** the idle demonstration and rehearse, reading them from the **settings as the single source of truth** (not from fixed demo constants): the **activation distance** the open gesture must cover (`launcherActivationThreshold`), the **item-step** travel per item (`launcherStepDistance`), the **band-step** travel per band (`launcherContextStepDistance`), and the **dwell-to-arm** duration (`dwellToArmDuration`). Changing a tunable SHALL update the preview **live**, without reopening the page — so what the user sees demonstrated is what the real launcher will do.

#### Scenario: Raising the activation threshold lengthens the demo's open walk
- **WHEN** the user increases the activation-threshold slider
- **THEN** the demo's four-finger open stroke travels a correspondingly longer distance before the launcher appears

#### Scenario: Changing the item-step changes the navigate feel in the preview
- **WHEN** the user changes the item-step (or band-step) distance
- **THEN** the preview's per-item (or per-band) stepping reflects the new distance in both the demo and rehearse

#### Scenario: Changing dwell-to-arm changes the preview's arm timing
- **WHEN** the user changes the dwell-to-arm duration
- **THEN** the rehearsed preview arms after the new duration, matching the real launcher's dwell

### Requirement: Gestureless pages are out of scope for the preview
Feature pages with **no gesture** (Keyboard Language, Devices, Setup, General) SHALL NOT show a gesture preview in this capability — they keep their current header — so the app never fabricates a gesture that does not exist. A later visual refactor MAY give those pages a different illustrative treatment.

#### Scenario: A gestureless page shows no fabricated gesture
- **WHEN** the user opens a page whose feature has no trackpad gesture (e.g. Keyboard Language)
- **THEN** no trackpad/ghost-hand preview is shown for it

### Requirement: The Switcher preview teaches the full gesture as a deterministic story
The Window-Switcher preview SHALL demonstrate the complete switcher gesture as a single deterministic story rather than abstract back-and-forth motion: **three fingers slide** to open (a horizontal swipe whose length tracks the configured **activation threshold**, so it reads as "just enough to trigger"), then **one finger lifts** while the other two keep resting (the ghost hand drops from three fingertips to two **without** a full lift between them), and the two resting fingers **navigate** — **up** to the second Space-row, back **down** to the first, then **sideways** across the windows in the row — before lifting. The preview's real highlight and Space-row reel SHALL advance **in sync** with the demonstrated strokes (the up-step slides to the second row, the sideways step moves the window highlight). The full story SHALL always play regardless of which switcher sub-features are currently enabled. A compact **action map** SHALL accompany the preview, spelling out the same steps in words.

#### Scenario: The switcher demo performs the connected open-then-lift-one story
- **WHEN** the Window-Switcher preview loops
- **THEN** the ghost hand opens with three fingers, drops to two fingers without lifting the whole hand, moves up to the second Space-row and back, then scrubs sideways across the windows, and the highlight + Space reel follow each step

#### Scenario: The opening swipe reflects the activation threshold
- **WHEN** the user changes the "Activation threshold" control
- **THEN** the length of the demonstrated opening swipe changes to match the new trigger distance

### Requirement: The Switcher preview shows real, scalable, multi-row content
The Window-Switcher preview SHALL render the user's real windows at their true proportions, grouped into **Space-rows** (multi-row), and SHALL reflect the configurable **window size** live: dragging the window-size control SHALL grow or shrink the preview cards in real time, in the same proportion as the real switcher. Two fallbacks SHALL keep the preview alive and teachable: when the user has **at most one** real window (only the Hub is open), the preview SHALL mimic **two icon-only windows**; and when the user has **fewer than two Spaces**, the preview SHALL fabricate a sample second Space-row so the up/down Space part of the story always has a row to reach.

#### Scenario: Windows grow and shrink with the size control
- **WHEN** the user drags the "Window size" control on the Switcher page
- **THEN** the preview's window cards grow or shrink in real time, keeping their true relative proportions

#### Scenario: A user with one window still sees a real-looking switcher
- **WHEN** the user has no other windows open besides the Hub
- **THEN** the preview shows two icon-only windows rather than an empty or abstract scene

#### Scenario: A user with one Space can still be taught the Space move
- **WHEN** the user has fewer than two Spaces
- **THEN** the preview fabricates a sample second Space-row so the demo's "up to the second row, back down" move still plays

### Requirement: A real swipe brings up the genuine switcher overlay, neutralized so it never fires
When the user performs a **real** switcher swipe (three fingers) while the Window-Switcher section is focused and the user is in the Hub, the **genuine switcher overlay itself** SHALL rise — the actual on-screen switcher at its true full size, driven by the user's real fingers exactly as the runtime gesture drives it (the same overlay, not an in-section scaled mimic). It SHALL, however, **neutralize every real side effect**: lifting the fingers SHALL raise **no** window and change **no** Space, and the gesture SHALL **not** open Mission Control. The overlay SHALL simply dismiss on lift. This makes the Switcher section's behavior **consistent** — the section never "sometimes" fires the real switcher — because the real overlay is always what is shown and its commit is always blocked while the user is in the Hub. When the user is NOT in the Hub (another app active), the switcher SHALL behave entirely normally (a real swipe switches windows).

#### Scenario: A real swipe shows the actual switcher overlay
- **WHEN** the user performs a three-finger switcher swipe while the Switcher section is focused
- **THEN** the genuine full-size switcher overlay rises and is driven by their fingers, not a section-bound scaled copy

#### Scenario: The teaching swipe never fires
- **WHEN** the user lifts after such a swipe (or swipes vertically)
- **THEN** no window is raised, no Space is changed, and Mission Control is not opened — the overlay just dismisses

#### Scenario: Outside the Hub the switcher is normal
- **WHEN** the user performs the switcher swipe while another app is active (not in the Hub)
- **THEN** the real switcher behaves normally and commits (raises the selected window)

### Requirement: Rehearse arms on the feature's opening finger count, so ordinary two-finger scroll passes through
A preview SHALL begin a rehearsal only after the feature's **opening trigger** — a three-or-more-finger contact (three opens the switcher, four the launcher and its bands) — has occurred in the current touch sequence. Until that trigger, a one- or two-finger move SHALL NOT be swallowed: it is an ordinary scroll and SHALL pass through so the Hub page scrolls normally. Once armed (the trigger seen), the preview SHALL keep driving while at least two fingers remain down (the real "trigger, then relax to two" grammar) and SHALL swallow the scroll for that armed sequence so the page does not scroll underneath the rehearsal. The gate SHALL disarm when the fingers fully lift (or the preview loses focus), restoring normal scrolling.

#### Scenario: A two-finger scroll passes through when no trigger has occurred
- **WHEN** the user moves two fingers over a focused preview without first placing a three-or-more-finger trigger
- **THEN** the preview is not driven and the gesture is not swallowed — the Hub page scrolls normally

#### Scenario: The trigger arms the rehearsal, then a relax to two keeps driving
- **WHEN** the user performs the feature's opening trigger (≥3 fingers) over the preview and then relaxes to two fingers
- **THEN** the rehearsal is armed by the trigger and keeps following the two-finger movement, and the page does not scroll for the duration of that armed sequence
