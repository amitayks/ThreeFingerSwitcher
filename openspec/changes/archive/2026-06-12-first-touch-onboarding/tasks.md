# Tasks — first-touch-onboarding

Order follows the design's migration plan: substrate first (each step independently shippable and testable under `swift test`), then the wizard, then the Hub adoption. Agent verification is `swift build` / `swift test` + `xcodebuild` compile-only throughout; the two restart edges (relaunch, re-login) are manual-test items.

## 1. Substrate — unified relocation plan

- [x] 1.1 Add `RelocationPlan` to `NativeGesture/`: a pure value type compiling chosen features (core, space-rows, launcher, fixed-spaces) into final key values for both trackpad domains per the design's D4 table, plus the set of keys touched. Unit-test all 8 feature combinations, including the shared four-finger key resolutions.
- [x] 1.2 Implement plan application: snapshot pristine prior values of every touched key (absent-aware) into the existing per-feature backup slots **before any write**, then write final values once; verification reads per key with non-fatal MDM degradation reporting which features failed. Unit-test backup pristineness under combination and individual-restore-after-combined-apply.
- [x] 1.3 Make `TrackpadGestureConfig`'s horizontal backup absent-aware (record absent keys, delete on restore), matching the other three configs. Unit-test round-trip of a previously-absent key.
- [x] 1.4 Route the existing single-feature consent paths (Hub Setup enable buttons, settings observers) through `RelocationPlan` with a one-feature plan, so there is exactly one write path. Keep per-feature restore behavior identical.

## 2. Substrate — durable pending-re-login marker

- [x] 2.1 Add a login-session identity reader (audit session ID via `getaudit_addr`) behind a small seam (protocol + real/fake implementations) in Core.
- [x] 2.2 Persist a pending-re-login marker (flag + ASID at write time) when any relocation plan writes trackpad keys; clear it on launch when the current ASID differs. Replace the `changedThisSession`-based `isEffectivelyFree` proxies so `is…Effective` gates and all "needs re-login" surfaces read the persisted marker. Unit-test: relaunch-same-session stays pending; new-session clears; Fast-User-Switch (same ASID) stays pending.
- [x] 2.3 Migration: existing installs with relocations already applied and no marker must not regress to pending (absent marker + freed keys ⇒ effective). Unit-test.

## 3. Substrate — live permissions and self-relaunch

- [x] 3.1 Add `startPolling()/stopPolling()` (≈1 s timer) and a `didBecomeActiveNotification` refresh to `PermissionsService`; polling runs only while a permission surface is visible. Unit-test the polling lifecycle with a fake clock/status source.
- [x] 3.2 Add a self-relaunch helper (detached `/usr/bin/open` of `Bundle.main.bundleURL` + `NSApp.terminate`, after persisting state), exposed as a coordinator closure for both the wizard and the Hub Setup page.
- [x] 3.3 Gate the mid-gesture Accessibility prompt in `gestureDidCommit` on first-run completion: while incomplete, a commit without Accessibility is inert (no OS prompt); after completion the existing safety-net behavior is kept. Unit-test the gate decision.

## 4. Wizard state machine and shell

- [x] 4.1 Create `Onboarding/` in Core: `FirstRunState` (codable stage machine per design D7 — overture/hand/permAX/permSR/awaitingRelaunch/lanes/awaitingRelogin/playground/curtain/completed) persisted via `AppSettings`; pure transition functions including the relaunch and re-login resume edges and close-as-later. Unit-test every transition and resume path.
- [x] 4.2 Completion + migration semantics: completing sets `firstRunCompleted` and all four legacy `didPrompt*` flags; on launch, an existing install (any `didPrompt*` set or all required permissions granted) auto-completes silently. Unit-test both.
- [x] 4.3 Build the wizard window: chromeless activating window (`.titled` + `.fullSizeContentView`, hidden title bar, movable by background, ~960×640, non-resizable), `HubGlass` material with fallback, presented via the `present()` dance; a `WizardContext` mirroring `HubContext` wired in `AppCoordinator` (permissions, relocation plan apply, live gesture state, relaunch helper, open-at-login, touch feed).
- [x] 4.4 Swap the `start()` first-run gate: remove the four `maybePrompt*` calls and the `showHub(selecting: .setup)` fallback; insert the single wizard gate (resume-aware). Keep the prompt methods callable from the Hub.
- [x] 4.5 Act-to-act navigation with the asymmetric slide+fade transition; persisted stage advances on each act completion.

## 5. The acts

- [x] 5.1 Overture: brand frame (icon, one line), auto-advance. (Menu-bar mark pulse initially descoped, then delivered in the motion pass — see 8.4: the real status-item mark breathes on the overture and the curtain.)
- [x] 5.2 The Hand: embed `SwitcherView` over a fabricated `SwitcherModel` (sample `WindowInfo` rows + pre-rendered gradient card art via `setThumbnail`); scripted attract loop; live takeover from the coordinator's read-only touch-frame feed (≥3 contacts ⇒ script yields, finger dots track, strip scrubs from real motion); cinema-only fallback when no frames flow. Extract the dwell driver from `LauncherOverlayController` into a shared helper (controller + wizard) without behavior change — `swift test` stays green.
- [x] 5.3 Permission acts: Accessibility then Screen Recording panes — explain-before-ask copy, grant button (OS prompt + deep-link), live polling while visible, checkmark-seal + haptic on detection; on AX grant re-feed the demo strip from a real `WindowService.snapshot()`; SR pane offers Relaunch-now via the helper and resumes on the same act post-relaunch, then renders live thumbnails.
- [x] 5.4 Claim the Lanes: trackpad-map feature selection (core always-on; fixed-spaces pre-checked; space-rows/launcher opt-in) with live state from the existing closures; single consent card enumerating every change + backup/restore reassurance; apply via `RelocationPlan`; MDM failures surface in-place non-fatally; then the re-login step (Log out now / Later) writing the persisted pending marker.
- [x] 5.5 Playground: launcher tour embedding `LauncherView` over the user's seeded bands, hold-to-continue affordance built on the shared dwell helper (charge + `.alignment` tick); quick-add adapted to a menu-bar tip (while the wizard is key the app itself is the front app, so Add-Front-App would target the wizard); optional-feature cards (Clipboard / AI / Keyboard Language) with honest cost copy, writing the same `AppSettings` keys, AI deferring to the existing download machinery without blocking; skip-all is first-class.
- [x] 5.6 Curtain: Open at Login offer (existing closure incl. /Applications guidance), "Ready" seal, where-things-live pointers; pending-re-login ribbon when "Later" was chosen; completion per 4.2.
- [x] 5.7 Post-re-login acknowledgment: on the first launch in a new session after relocations were applied (marker just cleared), surface the "lanes are live" moment (resume `awaitingRelogin` → `playground`, or a one-time toast when the wizard already completed).

## 6. Hub adoption

- [x] 6.1 Setup page: adopt `PermissionsService` polling while visible (retire the manual-refresh-only behavior); add the Resume/Replay welcome-tour entry; point its Screen Recording guidance at the relaunch helper.
- [x] 6.2 Replay safety: replay runs the machine from overture with done-states rendered from live detection; no setting is written without a fresh user action. (The testable nucleus — beginReplay/resume/migration/marker reads — is covered in FirstRunStateTests + ReloginMarkersTests; the done-state rows are direct live-closure reads in view code.)

## 7. Verification and spec hygiene

- [x] 7.1 Full agent verification: `swift build` + `swift test` green (existing 559 + new tests); `xcodebuild` compile-only for the app target.
- [x] 7.2 Write `MANUAL-TEST.md` for the change: fresh-machine run-through (attract→live takeover, AX upgrade, SR relaunch resume, combined apply + single re-login resume, Later path, MDM/no-trackpad degradations, existing-install silent migration, replay).
- [x] 7.3 Spike confirmations recorded in the change (MANUAL-TEST.md §1; ASID probe confirmed in-shell — rc=0, stable per session): (a) touch frames pre-permission on a clean machine, (b) wizard window key-taking alongside non-activating overlays, (c) ASID behavior across logout/login and Fast User Switching.
- [x] 7.4 After implementation: sync the spec deltas into `openspec/specs/` (first-run-onboarding new; permissions-onboarding, configuration-hub, native-gesture-config, spaces-rearrange-config updated) and update README Job A to describe the wizard flow.

## 8. The motion pass — the wizard as one performance (design D10, authored)

Design-only refinement: every state change in the wizard routes through one motion system (`Onboarding/WizardMotion.swift`); behavior, copy, and the state machine are untouched. `swift build`/`swift test` green throughout (the choreography's pure nuclei — `attractPose`, the scene-pulse hooks — are unit-tested).

- [x] 8.1 Motion system: settle-spring act river (slide+fade+scale breath), per-act content cascade (`wizardCascade`), item ripple (`wizardBloom`), arrival spring + `RippleRing` + haptic for seals/arming, `ShimmerSweep` for in-place scene transformations, `PulseHalo`/`BreathingGlowBackdrop` for waiting/live states, crossfading copy (`contentTransition`) everywhere a headline changes meaning.
- [x] 8.2 The ghost hand: the attract loop re-choreographed from a 0.9 s column stepper to a continuous 30 Hz sweep — three faint fingertips on the pad whose centroid drives the strip through the *same* mapping as real touch; takeover brightens dots, warms the pad, blooms the under-strip glow, sweeps the scene, ticks the haptic. Pure `attractPose(phase:)` unit-tested (bounds, three fingertips, full-strip coverage).
- [x] 8.3 Scene transformations announced: `sceneUpgradePulse` bumped on hand-takeover, the real-windows upgrade, and the faces-arrived reveal (once, post-seed) — the view answers each bump with a light sweep across the demo strip. Unit-tested.
- [x] 8.4 The stage and the world: wizard window rises+fades in on first presentation and exhales out on completion (AppKit animator); the lanes-live toast drifts in/lifts away instead of popping; the real menu-bar mark breathes on the overture and the curtain (`pulseMenuBarMark` closure → `StatusItemController.pulseMark`).
- [x] 8.5 Acts: overture three-beat bloom under a brand halo; permission action rows morph request→Continue on grant; lane rows/feature cards ripple in and warm when chosen; re-login door breathes (waiting idiom); playground hold-button inflates with its charge, pops+glows when armed, and morphs into Continue when the tour contract completes (with a sweep over the tour); curtain seal lands with ring+halo and staggered finale.
- [x] 8.6 **Body-safety invariant (crash fix).** The gesture-state context closures (`trackpadClaimed`/`spacesAutoRearrangeOn`/`launcherLive`) shell out to `/usr/bin/defaults` and block on `waitUntilExit`, which pumps a *nested run loop* — calling them from a SwiftUI `body` re-enters the AppKit update cycle mid-render and segfaults (observed: SIGSEGV in UpdateCycle from `LanesAct.body` on the permSR→lanes transition — the "blank screen on Continue"). Fixed by snapshotting all live state into published model properties in `prepareStage` (wizard) / event handlers (Hub Setup: appear, post-action, app-active) so `body` never spawns a process; contract documented on `WizardContext`. Snapshot lifecycle unit-tested.

## 9. Flow refinements — completion is the gesture (design D12)

Every step the user completes advances itself; the playground plays the real launcher. `swift build`/`swift test` green; the new model paths (lift-advance, grant beats, raw four-finger drive, lane toggle) and `WizardTourBands` are unit-tested.

- [x] 9.1 Hand act auto-advance: scrub + lift → the Accessibility act, no Continue while the hand plays; quiet fallback for the cinema path and the lifted-without-scrub edge.
- [x] 9.2 Grant auto-advance: a detected grant seals, transforms the scene, and flows on after its beat (AX 1.4 s, SR 2.4 s — the reveal), including at-entry (post-relaunch resume, replay). The granted-state Continue buttons are gone; request buttons morph away on grant.
- [x] 9.3 Lanes default ON (`LaneChoices`: spaceRows/launcher/fixedSpaces all true) with copy that says why and how to opt out; design Open Question resolved.
- [x] 9.4 Playground live play: four fingers morph the demo to (near-)actual size and drive it via the raw touch feed (`handleTourTouch` — step thresholds, dwell, lift; never fires); recognizer drives instead once lanes are live; everything else dims during play; the lift settles the morph back and an armed lift converts the hold-button to Continue. The `.clipped()` corner-squaring on the demo container is gone (the border now matches the real launcher).
- [x] 9.5 Playground lane row: the four-finger claim/restore toggle lives next to the demo (unified apply on, quiet restore off, inline MDM failure, honest pending/live captions).
- [x] 9.6 Tour bands fixed composition (`WizardTourBands`): flame (all apps across bands, deduped) + display (the 12 window actions) + AI when on (own commands, else seeded) + clipboard when on — nothing more.
