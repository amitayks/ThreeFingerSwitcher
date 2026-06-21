## Why

The Hub's feature pages explain their gestures only in prose. The app already *has* the perfect teaching surface — the First Touch wizard's demo strip: a stylized trackpad with a ghost hand that loops the gesture, then yields to the user's real fingers and reacts live. Today that lives only in onboarding. Bring it into the Hub: every gesture-driven feature page leads with the same live preview (exactly how macOS System Settings ▸ Trackpad shows a looping clip of each gesture), with the feature's master toggle — styled like the Overview "home page" switches — directly beneath it.

And once the gesture is on screen as a live, reactable object, the next step is obvious: **let the user decide what each move does.** The resolution gestures inside an open surface (the AI canvas, the Files drill, the switcher's scrub axes) are remappable today only in code. The recognizer already emits a *raw direction* (`launcherCanvasResolve(dx:dy:)` reports `±1`); the entire interpretation ("down = commit, horizontal = discard, up = ignore") is one hardcoded `if/else` in `AppCoordinator`. Turning that into a user-chosen mapping is a settings + UI change, not a gesture-engine rewrite — and the preview is the natural editor: **hover a binding and it demos that move; perform the move on your trackpad and the scene reacts.**

## What Changes

- **Live gesture preview on every gesture feature page.** A reusable `HubGesturePreview`: a stylized trackpad pad (lifted from the wizard's `FingerDotsPad`) under a live miniature of the real overlay (`SwitcherView` / `LauncherView` / `AICommandCanvasView`), driven by a generalized, self-looping `attractPose` (finger-count + axis parameterized). Three states: **attract** (loops the currently-bound gesture), **hover-demo** (loops a candidate binding the user is hovering), **rehearse** (the user's real ≥2-finger touch drives the dots and the scene reacts).
- **Switch-style master toggle under the preview.** Each gesture page's leading enable becomes the Overview `featureRow` look (icon + title + subtitle + `.switch`), sitting directly beneath the preview. The existing secondary controls (sliders, pickers, buttons) are **unchanged**.
- **Configurable resolution-gesture bindings** for three remappable surfaces — the AI canvas resolve (`{↑ ↓ ← →} → {commit, dismiss, ignore}`), the Files drill resolve (`open / Open-With / discard`), and the switcher scrub direction (windows ⇄ / Spaces ⇅, folding the existing reverse toggles). Bindings are persisted, default to **exactly today's behavior**, and are edited via per-action dropdowns next to the preview.
- **Rehearse-does-not-fire isolation.** While a Hub preview is being rehearsed on the real trackpad, the live recognizer does **not** also open the launcher / fire the command — the Hub captures touch for the demo and suppresses real handling (the wizard's `wizardOwnsGestures` precedent), gated to **≥2 fingers** (a one-finger move never triggers anything).
- **No new permission, no gesture relocation, no re-login.** Reuses the existing touch feed and overlay views. Gestureless pages (Keyboard Language, Devices, Setup, General) are **out of scope** here — left for a later visual refactor.

## Capabilities

### New Capabilities

- `hub-gesture-previews`: the reusable, self-looping live gesture preview surface in the Hub — stylized trackpad + live overlay miniature, the attract / hover-demo / rehearse states, ≥2-finger gating, and rehearse-does-not-fire isolation.
- `gesture-bindings`: the persisted, user-configurable mapping of **resolution** gestures → actions for the remappable surfaces — per-surface vocabularies, mutual-exclusivity (conflict) rules, reserved/invalid excursions (single-finger never; sub-threshold two-finger scroll stays "read"), and defaults equal to today's behavior.

### Modified Capabilities

- `configuration-hub`: each gesture feature page leads with a live gesture preview and a switch-style master toggle; remappable pages add binding dropdowns; the existing tunables and their look/feel/type are preserved.
- `launcher-overlay`: the AI-canvas swipe-to-resolve and the Files-drill resolution consult the user's configured binding instead of a hardcoded direction map; defaults preserve today's grammar, and the canvas's at-top commit guard is retained whichever excursion is bound to commit.
- `switcher-overlay`: the scrub direction (windows / Space-rows) reads from the configured binding; defaults preserve the current reverse-direction behavior.
- `tunable-settings`: new persisted gesture-binding settings, defaulting to today's behavior, surfaced in the Hub.

## Impact

- **Code:** new `HubGesturePreview` + a self-looping pose driver (generalized from `FirstTouchWizardModel.attractPose`) and a Hub-local live-touch subscription with rehearse suppression; new pure `GestureBindings` model (MLX-free Core) + persisted `AppSettings` properties; each gesture feature page (`HubFeaturePages.swift`, `HubFilesPage.swift`) gains the preview + switch toggle (+ dropdowns where remappable); `AppCoordinator.launcherCanvasResolve` and the Files-drill / switcher-direction sites consult the binding.
- **Reuse, not rebuild:** `FingerDotsPad`, `attractPose`, `WizardMotion` (`PulseHalo` / `BreathingGlowBackdrop` / `ShimmerSweep`), and the real overlay views are reused; the recognizer's raw-direction emission is unchanged.
- **MLX-free Core:** the pose driver, the binding model, and the conflict rules are pure and `swift test`-able; the live preview + touch subscription need the real app (compile-verify via `xcodebuild`, run-verify by the user).
- **Out of scope:** gestureless pages, activation finger-counts (the "4 open / 2 act" grammar stays fixed), and any new haptics.
