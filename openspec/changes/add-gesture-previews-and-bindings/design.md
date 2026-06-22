## Context

The First Touch wizard already proves the whole interaction this change wants in the Hub:

- `FingerDotsPad` (`Onboarding/FirstTouchWizardView.swift`) — a stylized trackpad with glowing fingertip dots; already count-agnostic (`dots: [CGPoint]`).
- `FirstTouchWizardModel.attractPose(phase:)` — a **pure, unit-tested** ghost-hand path: a three-fingertip arc whose centroid ping-pongs across the pad on a ~6.5 s loop. This is the "self-playing clip" engine.
- The attract → live-hand takeover: the loop plays itself until real ≥3-finger touch arrives, then the user's contacts drive both pad and the live `SwitcherView`/`LauncherView` miniature (the same centroid→column mapping the real gesture uses).
- `WizardMotion` (`PulseHalo`, `BreathingGlowBackdrop`, `ShimmerSweep`, cascade/bloom) for the "alive" feel.

And the binding seam is already clean. `GestureRecognizer.trackCanvasResolution` emits a **raw direction** (`launcherCanvasResolve(dx:dy:)`, `±1`, axis-locked); it knows nothing about "commit"/"discard". The *entire* interpretation is one `if/else` in `AppCoordinator.launcherCanvasResolve`:

```swift
if dy < 0 { guard canvasAtTop; resolveCanvasCommit() }  // down = apply (only at top)
else if dx != 0 { discardCanvas() }                      // horizontal = discard
// dy > 0 (up) → no-op
```

So "let the user decide what each move does" is a mapping-table + UI problem; the recognizer is untouched. The Files-drill (`filesOpenWith`, lift-open, four-finger discard) and the switcher's reverse-direction toggles are the same shape.

## Goals / Non-Goals

**Goals:**
- A reusable `HubGesturePreview` that leads every gesture feature page: a stylized trackpad pad + a live overlay miniature, self-looping (macOS-Settings-style) and reacting to the user's real trackpad (onboarding-style).
- A switch-style master toggle (the Overview `featureRow` look) directly beneath the preview, writing the same persisted preference as today.
- User-configurable **resolution** gestures for the AI canvas, the Files drill, and the switcher's scrub axes — edited via per-action dropdowns, taught/rehearsed through the preview, defaulting to exactly today's behavior.
- Rehearsing a gesture in the Hub **never fires the real feature**, and a single-finger move never triggers anything.
- Pure pose driver + pure binding model in MLX-free Core, `swift test`-able.

**Non-Goals:**
- Gesture previews for **gestureless** pages (Keyboard Language, Devices, Setup, General) — deferred to a later visual refactor.
- Remapping **activation** gestures (finger counts). The "4 fingers open/dismiss the platform, 2 fingers act within it" grammar is load-bearing (CLAUDE.md) — bindings are for resolution *within* an open surface, not for which finger-count opens what.
- Unifying the canvas (swipe-to-resolve) and Files (lift-to-open) grammars into one remap — they are deliberately different (CLAUDE.md: "do not generalize it to this navigation surface"); each surface keeps its own vocabulary.
- New haptics; restyling the secondary controls (sliders/pickers/buttons keep their look/feel/type).
- Changing the recognizer's raw-direction emission.

## Decisions

**1. `HubGesturePreview` — three states over one pure driver.**
A reusable view: a live overlay miniature on top, a `FingerDotsPad` below. Driven by a generalized pose function `GesturePose.pose(phase:fingers:axis:)` — `attractPose` lifted into MLX-free Core and parameterized by **finger count** (2/3/4 fingertips) and **axis** (horizontal ping-pong, vertical, or a **scripted sequence** of keyframed excursions). The scripted form is what the band pages need: a single demo loop that plays **four-finger open → traverse to the target band → the band's in-surface gesture**, not one excursion. States:
  - **Attract** (idle): loops the surface's *currently-bound* gesture (for band pages, the full open→band→in-surface journey); the miniature reacts (launcher opens, bands step past, highlight moves, a commit flashes).
  - **Hover-demo**: when the user hovers a binding dropdown option, the loop switches to that *candidate* excursion so they see the move before choosing it.
  - **Rehearse**: real ≥2-finger touch replaces the ghost; the dots track the contacts and a bound excursion plays its **result** in the miniature (text commits / dismiss), exactly the wizard's takeover.
  *Alternative considered:* a pre-rendered video per gesture (literal macOS parity) — rejected; we already render the real overlays, and live reaction (hover + rehearse) is the whole point.

**2. Rehearse ≠ fire — Hub owns the gesture while a preview is live.**
The Hub subscribes to the same `TouchEngine` feed the wizard model uses, but only while a preview is on screen / focused. While capturing, real gesture handling is **suppressed** (the `wizardOwnsGestures` precedent in `AppCoordinator`): rehearsing swipe-down in the Hub must not open the launcher or fire an AI command. Capture is gated to **≥2 fingers** — a one-finger move is ignored entirely (no cursor-as-gesture). On the preview losing focus / the fingers lifting, real handling resumes.

**3. `GestureBindings` — a pure, persisted, per-surface mapping.**
A small MLX-free Core model. Each remappable surface has its own **action set** and **excursion vocabulary**:
  - **AI canvas** — actions `{commit, dismiss, ignore}` ← excursions `{swipeUp, swipeDown, swipeLeft, swipeRight}` (two-finger).
  - **Files drill** — actions `{open, openWith, discard}` ← excursions `{lift, plusOneFingerLift, fourFingerHorizontal}`.
  - **Switcher** — `{windowsAxisDirection, spacesAxisDirection}` ∈ `{normal, reversed}` (folds `reverseDirection` / `reverseVerticalDirection`).
Bindings persist in `AppSettings` and **default to exactly today's behavior**. The recognizer is unchanged; consumption is at the existing seam (`launcherCanvasResolve`, the Files-drill delegate calls, the switcher direction read).

**4. Conflict rule: dropdowns are mutually exclusive per surface.**
Two actions on one surface can't share an excursion. Assigning an excursion already held by another action **swaps** them (or the taken option is shown disabled) — a pure verdict in `GestureBindings` (`assign(action:excursion:)` returns the normalized binding set), unit-tested. The vocabulary **excludes reserved/invalid excursions**: single-finger anything (never a trigger), and on the canvas the sub-`canvasResolveThreshold` two-finger pan stays "read/scroll the canvas," never bindable.

**5. Defaults preserve today; load-bearing guards are binding-independent.**
The canvas **at-top commit guard** (`canvasAtTop` — a down-swipe mid-scroll is the user scrolling, not committing) is retained for *whatever* excursion is bound to `commit`. The Files discard **never terminates a running app** regardless of which excursion is bound to it. Reversing a switcher axis only flips sign, never magnitude.

**6. Switch-style master toggle; secondary controls untouched.**
Each gesture page's leading `ToggleRow` enable becomes the Overview `featureRow` row (icon + title + subtitle + `.switch`), placed under the preview. Everything below it (the existing `LabeledSlider` / `Picker` / buttons) is unchanged — same bindings, same look. This is the "below the preview, a toggle like the home page" ask, scoped to the master enable only.

**7. Per-page composition (workflow-shaped).**
The preview + toggle is added page-by-page so implementation fans out cleanly: Switcher, Launcher, Clipboard, Files, AI each get the preview + switch toggle; Files and AI additionally get their resolution-binding dropdowns; the Switcher gets its direction dropdowns. The three **band** pages (Clipboard, Files, AI) all open from the four-finger launcher and traverse to their band — their preview demos that full path (open → band → in-surface gesture). Clipboard has no own resolution binding, so it gets the preview (full path) + toggle only.

## Risks / Trade-offs

- **Rehearse leaking into real firing** → the single biggest risk; gate hard on "a preview is focused" + "≥2 fingers," reuse `wizardOwnsGestures`, and unit-test the gate's enter/exit. A missed exit would leave the real gestures dead — cover the focus-loss / lift paths.
- **Live overlay miniatures in the Hub are heavyweight** → reuse the existing views with fabricated demo models (the wizard already does this); keep them `allowsHitTesting(false)` and cap the refresh, so they idle cheaply when not rehearsed.
- **Binding the "wrong" excursion to commit re-introduces accidental commits** → keep the reserved-excursion exclusions and the at-top guard binding-independent; the conflict rule prevents double-bound excursions.
- **Switcher direction now has two homes (reverse toggles vs. binding)** → fold them: the binding is the single source; the old toggles become a view onto it (no duplicate persisted keys).
- **Gestureless pages look inconsistent until the later refactor** → accepted and explicit (out of scope); those pages keep today's header.

## Resolved Decisions (from exploration)

- **The dropdown is the only binding editor.** The rehearse state previews/reacts but never commits a binding — the user does not "bind by performing." Hover-to-demo + dropdown is the editor.
- **Band-page previews demonstrate the full path: four fingers → navigate to the band.** Clipboard, Files, and AI all begin from the four-finger launcher activation and then step across to their band; the demo loop plays that whole journey (open → traverse to the target band), and only then the band's in-surface gesture (Files lift-to-open, AI canvas resolve). The preview is not a single excursion for these pages — it is a short choreographed sequence.
- **Switcher uses a lighter abstract scene, not a live window-grid miniature.** No fabricated window data in the Hub for the switcher; launcher/AI keep their fuller miniatures (the wizard already builds demo models for those).

## Open Questions (tuning, not design)

- **Pad / miniature sizing inside a `HubSection` card.** The wizard sizes its strip for a fixed 960×640 stage and scales the real overlay views (`PlaygroundAct`'s `tourSize`/`tourScale`/`playScale`) to fit; the Hub's detail column is narrower and variable (`minWidth 540` minus the sidebar). Pick a sensible default scale/frame for the Hub and tune it in run-verify — there is no paper-derivable value. The "lighter switcher scene" decision removes the switcher from this problem (no oversized intrinsic width); only the launcher/AI miniatures need the scale dance.
