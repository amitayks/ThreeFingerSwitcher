# Design — First Touch

## Context

The app's first-run experience today is the inverse of the product. The product is tactile, immediate, and reversible; the first run is textual, modal, and permanent. From `AppCoordinator.start()` (AppCoordinator.swift:285-290) a fresh install fires up to four sequential one-shot `NSAlert`s (horizontal gesture, Spaces order, Space-row switching, launcher — each `didPrompt*` flag set *before* the alert shows, so "Not now" is forever), then falls back to `showHub(selecting: .setup)` if permissions are missing. The engine is already running (`settings.enabled` defaults true), so the user's first real swipe fires the Accessibility prompt **mid-gesture** (AppCoordinator.swift:571-574). Screen Recording requires an app restart that no UI mentions and no helper performs. Each gesture relocation applies piecemeal, colliding on the shared four-finger keys and producing up to three "restart to finish" moments. Nothing marks completion.

Three load-bearing facts make a radically better experience cheap:

1. **Touch works pre-permission.** The multitouch read (OpenMultitouchSupport) flows without any TCC grant on macOS 26, and the engine starts at launch regardless of permissions.
2. **The overlays are embeddable.** `SwitcherView`/`LauncherView` are pure presentation over plain `ObservableObject` models. `SwitcherModel` accepts arbitrary `[[WindowInfo]]` (value structs, `axElement` optional) with thumbnails injected as `NSImage`s; `LauncherModel` accepts AppKit-free `LaunchItem`s. The dwell driver is ~20 lines in `LauncherOverlayController.startDwell/arm` (306-333).
3. **One re-login can cover every relocation.** All trackpad flips are independent `defaults` writes that become effective together at the next login; `mru-spaces` needs only a Dock restart.

Constraints inherited from the spec corpus: explicit consent before any system-setting write; absent-aware backup/restore; lazy Calendar/Reminders/Contacts (never at launch or opt-in); no new prompts for AI selection/vision; Liquid Glass with graceful fallback; MDM-blocked writes degrade non-fatally; relocations are never reverted on quit/logout; agents verify with `swift build`/`swift test` only.

## Goals / Non-Goals

**Goals:**

- A first run the user *plays*: their fingers drive the real overlay views before anything is asked of them.
- Every permission ask is preceded by its payoff and followed by a visible, immediate upgrade.
- All system-setting changes converge into **one consent moment and one re-login**.
- The flow survives — and choreographs — both restarts it needs (app relaunch for Screen Recording, re-login for relocations), resuming at the right act with the right words.
- Honest everywhere: what changes, what's backed up, what's reversible, what a re-login is for, how big the AI model is.
- Existing users never see the wizard uninvited; the legacy prompts never double-fire.

**Non-Goals:**

- Not a tutorial system or in-app help framework — one first-run performance plus a replay entry.
- No changes to gesture recognition, the overlays' runtime behavior, or the launch/AI pipelines.
- No localization pass in this change (copy is authored in English; structure doesn't preclude it).
- No new permission usage of any kind; no Calendar/Reminders/Contacts contact in the wizard, ever.
- No Intel-specific AI path (the AI card states the Apple Silicon requirement honestly and otherwise hides/defers).

## Decisions

### D1 — A dedicated chromeless window, not a Hub page

The wizard is its own borderless-feel window (`.titled` + `.fullSizeContentView`, hidden title bar, movable by background, activating, ~960×640, non-resizable), built from the `HubGlass` idiom so it *is* the product's material. The Hub is an instrument panel; a first-run performance needs a stage — the Hub's sidebar chrome, 940×580 minimums, and "configuration" framing would suffocate it.

This supersedes the single-window mandate (`configuration-hub` spec.md:10) and the "not a separate Setup/Onboarding window" clause (`permissions-onboarding` spec.md:19) — both amended by this change's spec deltas. The carve-out is narrow: the wizard is a **transient first-run/replay surface, not a configuration surface**; every toggle it writes is the same persisted preference the Hub owns, and the Hub remains the only place to *configure* anything.

*Alternative considered:* a `HubDestination.welcome` page inside the Hub — zero new window code, no spec delta. Rejected: the act structure (full-bleed scenes, finger dots, embedded demos) fights the sidebar/detail layout, and opening "a settings window" as the first brand moment is precisely the failure being fixed.

### D2 — Attract mode that hands over to the user's hand

Act I doesn't *wait* for the user's fingers — a scripted demo loop plays immediately (the simulated strip scrubbing itself, self-evidently alive). The moment real touch frames arrive with ≥3 contacts, the script yields and the user's actual fingers drive the scrub; soft glass dots track their fingertips. This sidesteps the one hard unknown (whether OpenMultitouchSupport delivers frames pre-permission on every machine): if frames never come, the act still works as cinema; if they come, it becomes magic. No detection heuristics, no failure state, no timeout.

Implementation seam: the wizard subscribes to `TouchEngine` frames (finger count + normalized positions) through a narrow read-only feed exposed by the coordinator — it does not touch the `GestureRecognizer` path, so the runtime latching rules (CLAUDE.md landmines) are untouched. While the wizard is frontmost and onboarding is incomplete, gesture commits are inert (see D8).

### D3 — The demo is the real product views over sample models

The wizard embeds `SwitcherView` and `LauncherView` directly, fed by fabricated models:

- **Pre-Accessibility:** `SwitcherModel.setRows` with fabricated `WindowInfo` and pre-rendered gradient "window" art injected via `setThumbnail` (keyed by arbitrary `CGWindowID`s). Stylized, deliberately not fake screenshots — art, not deception.
- **Post-Accessibility:** the same strip re-fed from a real `WindowService.snapshot()` — the cards become *their* windows (icon + title), the upgrade rendered in place with a single transition.
- **Post-Screen-Recording (after relaunch):** the same strip again, now with live thumbnails. Three states of one scene; each grant visibly transforms it.
- **Launcher tour:** `LauncherModel.setBands` with the user's actual seeded bands (`FavoritesStore` already seeds defaults + the AI band on fresh install), `.sfSymbol`/`.emoji` icons avoiding NSWorkspace/QuickLook lookups where sample data is needed.

The dwell driver (`startDwell`/`arm`) is extracted from `LauncherOverlayController` into a small shared helper used by both the controller and the wizard, so the charge timing can never drift between tutorial and product. The charge visual (`SelectionSquare`'s linear tint ramp + the `.alignment` haptic tick) doubles as the wizard's **hold-to-continue** affordance — the user learns dwell-to-arm by *using it to advance the wizard*.

### D4 — One `RelocationPlan`: final values computed once, pristine backups first

Act III collects the user's feature choices (switcher core — always; Space-row switching; four-finger launcher; fixed Spaces order) and compiles them into a single `RelocationPlan` value type in `NativeGesture/`:

| Chosen features | 3F-horiz | 3F-vert | 4F-horiz | 4F-vert |
|---|---|---|---|---|
| core only | 2 | untouched | 1 (full-screen swipe moves to 4F) | untouched |
| core + space-rows | 2 | 0 | 1 | 2 (MC on four fingers) |
| core + launcher | 2 | untouched | 2 (freed) | 0 (freed) |
| core + both | 2 | 0 | 2 | 0 (MC via app synthesis) |

(both trackpad domains in lockstep; `mru-spaces=false` + Dock restart folded in when chosen — instant, no re-login.)

The plan applies as: **snapshot pristine values of every key the plan touches → store them into the existing per-feature backup slots (absent-aware) → write final values once**. This fixes both existing defects: the four-finger key collision (horizontal writes `4F-horiz=1` while the launcher needs `2`; vertical writes `4F-vert=2` while the launcher needs `0`) and the first-write-wins backup pollution when relocations chain. Per-feature backup slots are kept (not one blob) so the Setup page's individual Restore buttons keep working unchanged; the horizontal backup is upgraded to absent-aware as part of this (the one non-absent-aware outlier).

The pure plan computation (`chosen features → key values + backup tokens`) is a nonisolated value-type function, unit-tested exhaustively under `swift test`, mirroring the existing static decision funcs in `VerticalGestureConfig`/`FourFingerGestureConfig`.

*Alternative considered:* sequencing the existing per-feature mutators from the wizard. Rejected: it reproduces the collision and backup pollution by construction.

### D5 — A durable pending-re-login marker keyed on the audit session ID

Today "effective" is `isFree && !changedThisSession` with `changedThisSession` in-memory only — an app relaunch without re-login yields a false-positive "effective" and the feature engages while the OS still owns the gesture. Replace the proxy with a persisted marker:

- At relocation write time, persist the current **audit session ID** (ASID, via `getaudit_addr` — public API; the ASID is unique per login session) alongside a `relocationPendingRelogin` flag.
- On launch: pending **stays pending** while the current ASID equals the stored one (same login session — relaunches don't lie anymore); when the ASID differs (a real re-login happened), clear the marker.
- `is…Effective` becomes `isFree && !pendingRelogin`. The wizard's "awaiting re-login" act and the Setup page's amber states read the same marker, so the "log out and back in" message survives app relaunches and disappears exactly when it's true.

*Alternative considered:* `kern.boottime` (only detects reboot, not logout/login) and private session dictionaries (`CGSSessionCopyCurrentDictionary` — avoid adding private API where a public one exists).

### D6 — A self-relaunch helper for the Screen Recording step

Screen Recording's TCC grant takes effect only after the process restarts; today the README says so and the app doesn't. The wizard's Screen Recording pane gains **Relaunch now**: persist wizard state (D7), spawn a detached relauncher (`/usr/bin/open` against `Bundle.main.bundleURL` from a short-lived detached process, the inverse of `LaunchService`'s proven quit-poll-reopen at LaunchService.swift:584-625), then `NSApp.terminate`. On the post-relaunch launch the wizard resumes on the same act — now rendering live thumbnails into the demo strip as the reveal. The helper is also exposed to the Hub Setup page (same closure), retiring the undocumented manual dance everywhere.

### D7 — The wizard is a persisted state machine

A small value-type state machine, persisted via `AppSettings` (one key, codable), with stages:

```
fresh ─▶ overture ─▶ hand ─▶ permAX ─▶ permSR ─▶ awaitingRelaunch(SR)
                                                        │ (relaunch)
   curtain ◀─ playground ◀─ awaitingRelogin ◀─ lanes ◀──┘
      │                          │ (re-login: ASID change clears D5 marker)
   completed                     └─ "Later" → resumes at playground with an
                                    amber "lanes pending" ribbon; the re-login
                                    payoff plays on the next post-login launch
```

Rules: every stage is resumable (launch checks `wizardState` before anything else in the first-run gate); closing the window mid-flow is "Later", never abandonment — the next launch resumes at the same act, and the Hub Setup page shows **Resume the welcome tour** while incomplete. Transitions between acts use the switcher's own asymmetric slide+fade (`SwitcherView.swift:59-66` pattern); state transitions are pure and unit-tested, including the two restart edges.

Completion: sets a single `firstRunCompleted` flag **and** all four legacy `didPrompt*` keys (so the retired `maybePrompt*` path can never fire even if re-enabled by a downgrade). Migration for existing installs: on first launch with the new build, if any `didPrompt*` flag is set or all required permissions are already granted, `firstRunCompleted` is set silently — existing users never see the wizard uninvited. Replay (from Setup) runs the same machine from `overture` with grants/relocations already satisfied — acts render in their "done" states and the run never re-writes settings without fresh consent.

### D8 — The wizard owns first contact; the mid-gesture AX prompt dies

While `firstRunCompleted` is false, `gestureDidCommit` must not fire `AXIsProcessTrustedWithOptions(prompt)` — a committed swipe without Accessibility is simply inert (the overlay still scrubs; commit is a no-op). The wizard is the only surface that requests Accessibility during first run, at the moment the demo scene is about to transform. After completion, the existing mid-gesture prompt path is retained as a safety net for the "granted then revoked" case.

### D9 — Live permission status, finally

`PermissionsService` gains `startPolling()/stopPolling()` (1 s timer) plus a `didBecomeActiveNotification` refresh. The wizard's permission acts poll while visible — a grant flips the scene within a second of the user clicking the toggle in System Settings, with the checkmark-seal animation and haptic tick landing as confirmation. The Hub Setup page adopts the same polling while visible, which finally satisfies the existing "Setup reflects live status" scenario that today only refreshes `.onAppear`.

### D10 — Craft: one motion system, authored as a performance

Material: `HubGlass` everywhere (glassEffect on macOS 26+, `.ultraThinMaterial` fallback). The runtime overlays keep their existing vocabulary untouched (0.12–0.16 s easeOut pops, 0.24–0.32 s easeInOut container moves, the asymmetric slide+fade); the wizard layers its own performance vocabulary over that base, defined once in `Onboarding/WizardMotion.swift` so every act draws from the same well and nothing cuts:

- **The river** — acts transition on a settle spring (response 0.55, damping 0.86), drifting out the top and rising from the bottom (the switcher's Space-row direction) with a slight scale breath; the window itself rises and fades in on first presentation and exhales out on completion (AppKit animator).
- **The cascade** — within each act, headline → supporting line → content → actions bloom top-to-bottom on staggered delayed springs (`wizardCascade`); repeated items (lane rows, feature cards, curtain elements) ripple in on their own indexed bloom (`wizardBloom`). Copy whose meaning changes in place (a headline reacting to a grant) crossfades via `contentTransition`, never cuts.
- **Arrival** — moments that become true land on an under-damped spring (response 0.38, damping 0.72) with a radiating `RippleRing` and the single `.alignment` haptic tick: a grant's seal, the hold-button arming, the Ready seal. Button sets morph (scale+fade) when their state graduates (request → Continue, hold → Continue).
- **Transformation** — every in-place upgrade of the demo scene is *seen* happening: the model bumps a `sceneUpgradePulse` and the view answers with a band of light swept across the strip (`ShimmerSweep`) — the hand taking over, sample cards becoming real windows, faces arriving, the tour contract completing.
- **The ghost hand** — the attract loop is choreography, not a stepper: three faint fingertips sweep the stylized trackpad continuously (30 Hz, pure `attractPose(phase:)`, unit-tested) and the strip's highlight follows the *same* centroid→column mapping the user's real fingers will use, so pad and strip demonstrate the exact gesture they invite. Real touch brightens the dots, warms the pad border, blooms a breathing glow under the strip, and sweeps the scene — the script yields to the hand as one visible event.
- **Waiting breathes** — pending states use the AI canvas's sparkle-pulse idiom generalized (`PulseHalo`, `TimelineView`-driven): the overture's brand halo, the re-login door, the curtain's seal. The *real* menu-bar mark pulses on the overture and the curtain ("the app lives in your menu bar" — shown, not told).
- **Choice glows** — a lane or feature card the user switches on warms in place (accent edge, strikethrough/arrow/text re-light, soft lift) so every yes is visible at a glance.

Haptics: still only the `.alignment` tick, reserved for arrival. Gesture hints reuse the canvas footer idiom. No new colors beyond band tints. Springs are deliberate and confined to the wizard's motion system — the overlays' runtime feel is unchanged; the wizard is the product's stage voice, and the curves above are its register.

### D11 — Optional features are offered, never pushed

The Playground act presents Clipboard, AI commands, and Keyboard Language as three quiet cards with honest one-line costs ("records what you copy, stays on this Mac", "downloads a multi-gigabyte model once, Apple Silicon only", "no permission, no re-login"). Toggling writes the same `AppSettings` keys as the Hub. AI enablement defers entirely to the existing in-context machinery (the model download UI and the launcher's "unavailable canvas" already specced) — the wizard never blocks on a download and never prompts for EventKit/Contacts. Skipping everything is a first-class path to the Curtain.

### D12 — Completion is the gesture: finished steps advance themselves

(Post-ship refinement.) Anywhere the user just *did* the thing an act teaches, the act flows on by itself — a Continue click after a completed gesture is friction the wizard exists to remove:

- **The hand act completes by the product's own contract** — scrub, then lift. The lift advances to the Accessibility act (the strip stays live under the rising hand there); no button is shown while the hand plays. A quiet "Continue without the trackpad" remains for the cinema path, and re-appears after a lift that never scrubbed (no dead-ends).
- **A grant is the click.** When Accessibility lands, the act seals, the scene transforms, and after a short beat (1.4 s) the wizard flows to Screen Recording on its own — one click in System Settings, zero clicks here. Same for Screen Recording (2.4 s — the reveal beat, faces streaming in), including at entry on the post-relaunch resume and on replay.
- **The playground plays the actual launcher.** Four fingers down and the demo MORPHS to (near-)actual size in place — driven by the raw touch feed until the lanes are effective (the same step/dwell/lift contract via `launcherTour*`; the recognizer takes over when they are), with everything else dimming into the wings. The lift settles it back into its slot; an armed lift completes the contract and the hold-button graduates to Continue. Caveat (accepted): until the re-login, the OS still owns the native four-finger gestures, so a vertical four-finger swipe may also trigger Mission Control over the wizard.
- **The four-finger lane is claimable in the playground** — a lane row with a toggle, right where the launcher makes its case, for the user who opted out earlier and changed their mind mid-play. ON applies the same unified relocation; OFF quietly restores the backup (no modal). MDM failure surfaces inline on the row.
- **The tour's bands are a fixed, didactic set** (`WizardTourBands`, pure + tested): *flame* — every app across the user's bands, deduped; *display* — the twelve window-management actions (4 halves, 4 quarters, maximize/center/minimize/full-screen: two exact rows of six); *sparkles* — only when AI is on (the user's own commands, else the seeded set); *clipboard* — only when history is on. Nothing more.

The lanes/playground/curtain acts keep explicit buttons: those acts decide things (consent, options), and decisions are clicked, not inferred.

## Risks / Trade-offs

- **[Touch frames may not flow pre-permission on some configurations]** → D2's attract-mode design makes live input an enhancement, not a dependency; the act is complete as a scripted scene. A spike on a clean macOS 26 VM/machine validates the live path before polish work.
- **[A second window class in a one-window app]** → The carve-out is spec-explicit and narrow (transient, non-configuration); the wizard reuses `HubContext`-style closure wiring and the `present()` activation dance (AppCoordinator.swift:1358-1365) rather than inventing window machinery.
- **[Unified plan vs. per-feature restore]** → Mitigated by keeping per-feature backup slots filled from the pristine snapshot; individual Restore buttons behave identically to today, now with uncorrupted values.
- **[ASID detection edge cases (e.g., Fast User Switching keeps sessions alive)]** → The marker errs pending-side: same ASID ⇒ still pending, which is the safe direction (feature stays gated). Switching to another user and back never falsely clears it because the original session keeps its ASID.
- **[MDM-managed Macs block the writes]** → The plan applies per-key with verification reads; failures surface in-wizard as a calm non-fatal state on the lanes act (feature stays off, System Settings pointer), mirroring the existing per-feature degradation.
- **[Replay could re-consent already-applied relocations]** → The state machine renders "done" states from live detection (same closures the Setup page uses); apply steps are skipped unless the user changes a choice, and any change is a fresh consent.
- **[Wizard regressions are TCC-sensitive and can't be fully verified by agents]** → All logic (state machine, plan computation, marker lifecycle, model drivers) is MLX-free pure Swift under `swift test`; the TCC-touching seams (prompts, relaunch, defaults writes) stay thin and behind closures, with a `MANUAL-TEST.md` covering the two restart edges end-to-end on a real machine.

## Migration Plan

1. Land the substrate first (no UX change): `RelocationPlan` + pristine-snapshot backups, ASID pending marker (wired into the existing `is…Effective` gates), absent-aware horizontal backup, `PermissionsService` polling, relaunch helper. Each is independently testable and improves the existing Setup page on its own.
2. Land the wizard module + the `start()` gate swap (legacy `maybePrompt*` calls removed; `didPrompt*` flags written on completion; silent-completion migration for existing installs).
3. Hub Setup page: replay/resume entry + live polling adoption.
4. Rollback: the gate swap is a single call site; reverting restores the legacy alert flow, and the substrate improvements stand alone safely. Existing-user defaults are only ever written in the completion/migration direction (flags set, never cleared).

## Open Questions

- **Copy voice.** The act copy ("Your windows, under your fingers", lane names, consent language) needs a single authored pass — the existing alert copy is honest and reusable as the consent baseline, but the wizard deserves better than recycled dialog text. Owner: whoever implements, with a dedicated copy review before ship.
- **Default lane choices.** RESOLVED (post-ship refinement): every lane defaults ON — together they are the app at its best, the act says so plainly, and opting out is one flick of an always-visible switch. The original off-by-default recommendation undersold the product to the people it was made for; honesty is preserved by the copy (what changes, what's backed up, one log-out) and the single explicit "Claim the lanes" consent action.
- **Demo art.** The pre-permission gradient "windows" need actual design (3–4 stylized cards). Keep them abstract — art, not fake apps.
