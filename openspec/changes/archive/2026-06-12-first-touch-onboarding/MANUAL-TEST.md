# Manual test — first-touch-onboarding

The wizard choreographs two restarts (an app relaunch, a re-login) and lives on TCC state, so the
agent's `swift test` (614 green) covers the machine/plan/marker logic but NOT these end-to-end
paths. Run on a real machine with a fresh build installed by **you** (`INSTALL=1
./scripts/build-app.sh` — never an agent-built .app; ad-hoc signing voids the very TCC grants under
test).

To simulate a fresh install (without nuking real TCC grants, which you can also do via
`tccutil reset Accessibility|ScreenCapture <bundle id>` for the full experience):

```bash
defaults delete com.keisar.ThreeFingerSwitcher firstRunStage 2>/dev/null
for k in didPromptNativeGesture didPromptSpacesRearrange didPromptVerticalGesture didPromptLauncher; do
  defaults delete com.keisar.ThreeFingerSwitcher $k 2>/dev/null; done
```

(Adjust the domain if the bundle id differs — check `mdls -name kMDItemCFBundleIdentifier /Applications/ThreeFingerSwitcher.app`.)

## 1. The spikes (design risks — confirm first)

- [ ] **(a) Touch frames pre-permission.** Fresh TCC (Accessibility + Screen Recording reset),
      launch, reach the Hand act. Put three fingers down: do the finger dots appear and does the
      strip follow your hand? If frames don't flow, the act must remain a clean self-playing scene
      (attract loop) with no error or dead state.
- [ ] **(b) Wizard window vs overlays.** With the wizard frontmost: the window takes key (buttons
      clickable), three-finger swipes do NOT open the real switcher overlay, no Mission Control
      fires, and after finishing the wizard normal overlay behavior returns.
- [ ] **(c) ASID.** `getaudit_addr` returns rc=0 with a stable ASID per session (confirmed in-shell
      during development). Verify across a logout/login the ASID CHANGES, and across Fast User
      Switching (switch away + back) it does NOT.

## 2. Fresh-machine run-through (the golden path)

- [ ] Launch → Overture (icon + line, ~3 s, no alerts of any kind), auto-advances to the Hand.
- [ ] Hand act: attract loop plays immediately; three fingers take over (haptic tick on takeover);
      absolute mapping (hand position = strip position). Continue.
- [ ] Accessibility act: copy explains BEFORE asking; Grant opens the OS prompt + System Settings;
      flipping the toggle in System Settings turns the act granted within ~1 s **without** manual
      refresh; the demo cards become your real windows (icons + titles); seal + tick.
- [ ] **The strip stays alive through both permission acts**: three fingers keep driving the scrub
      on the Accessibility AND Screen Recording acts (including right after the cards become real
      windows) — the upgrade transforms a scene that is still under your hand, never a frozen frame.
- [ ] Screen Recording act: Grant; relaunch via **Relaunch now** — the app quits and reopens
      itself, NO quit-time "Restore the trackpad setting?" or Spaces restore fires, and the wizard
      resumes ON the Screen Recording act now showing live thumbnails in the strip.
- [ ] **Every card gets a preview at the reveal** — including windows fully covered by the wizard
      and windows on other Spaces (the reveal force-captures on the cold cache; two retry sweeps
      catch stragglers within ~2 s). No card should stay icon-only until you "visit" its window.
- [ ] Lanes act: 3F-horizontal row reads "The switcher" (included); fixed-Spaces pre-checked when
      auto-rearrange is on; check Space-rows + Launcher → Claim. Verify with `defaults read
      com.apple.AppleMultitouchTrackpad`: `ThreeFingerHorizSwipeGesture=2`,
      `ThreeFingerVertSwipeGesture=0`, `FourFingerHorizSwipeGesture=2`,
      `FourFingerVertSwipeGesture=0` (both domains), `com.apple.dock mru-spaces=0` (Dock restarted
      once), and the three backup slots hold PRE-wizard values.
- [ ] Re-login act: **Later** → Playground with the launcher demo of your seeded bands;
      hold-to-continue charges, ticks at the dwell duration, release fires. Optional feature cards
      write the same prefs as the Hub (verify a toggle in Hub ▸ Overview matches). Cards and copy
      keep clear margins from the window edges (the tour is boxed; nothing overflows). Curtain
      shows the amber "lanes go live after log-out" ribbon + Open at Login. Finish.
- [ ] **Playground with lanes already live** (post-re-login resume, or replay on a configured
      machine): real four-finger gestures drive the embedded tour — slide steps items/bands with
      the product's coarse/fine feel, dwell charges + ticks, lift resets and **never fires** an
      item; the copy invites trying it ("your four fingers work right here"). With lanes NOT yet
      live, the tour is static and the copy says "once the lanes are live".
- [ ] **Playground arrives whole**: the launcher is on screen in the act's very first frame — no
      split-second pop-in after the background and cards.
- [ ] **Completing the contract converts the button**: slide to an item, hold to the tick, lift —
      the headline flips to "That's the whole trick" and the hold-button becomes a plain Continue.
- [ ] **Feature toggles re-seed the tour live**: flipping Clipboard on adds the Clipboard band
      (with labeled example entries while history is empty; real entries once any exist); flipping
      it off removes it. Flipping AI on shows the seeded AI band if no AI command survives in the
      favorites (if the favorites already hold AI items, the band is simply already there — the
      opt-in never gates item visibility, per spec).
- [ ] **Keyboard language reaches browsers immediately**: enable the master toggle (wizard card or
      Hub) — per-site is on by default (Accessibility reader, no permission); switch language on a
      site in Chrome, change sites, come back — it restores **without any app relaunch**. Toggling
      per-site off/on in the Hub starts/stops host reading in the running session.
- [ ] **Relaunch reopens reliably**: the Screen Recording act's Relaunch (and Hub ▸ Setup's
      Relaunch app) quits AND reopens the app; if it ever fails, `/tmp/tfs-relaunch.log` holds the
      breadcrumbs (waiting → opening → done).
- [ ] `firstRunStage=completed` and all four `didPrompt*` keys set; relaunching shows NO wizard and
      NO legacy alerts.
- [ ] Log out, log in: the one-time **"Your gestures are live"** toast appears (once); Space-rows
      and the launcher now engage (markers cleared — Setup page shows green, not amber).

## 3. The interruption matrix

- [ ] Quit mid-flow (e.g. on the Accessibility act) → relaunch resumes the SAME act.
- [ ] Close the wizard window mid-flow → next launch resumes; Hub ▸ Setup shows **Resume the
      welcome tour**.
- [ ] On the re-login act choose **Log Out Now** → macOS confirm appears (⇧⌘Q path); cancel it,
      quit the app, relaunch (same session) → wizard resumes ON the re-login act (the app relaunch
      must NOT fake effectiveness — the features stay gated).
- [ ] Then really log out/in → wizard resumes at the Playground with the lanes live.

## 4. Degradations

- [ ] Skip every permission and decline the lanes → wizard completes; switcher scrubs but commits
      are inert with NO mid-gesture OS prompt (first-contact gate); after completion, a commit
      without Accessibility DOES prompt (safety net).
- [ ] No-trackpad Mac (or trackpad disabled): wizard runs scripted end-to-end, no errors.
- [ ] MDM-style failure (hard to fake; optionally `chflags`-protect a plist or test on a managed
      Mac): lanes apply shows the in-place orange notice, no modal, features stay off.
- [ ] Intel or low-RAM Mac: the AI optional card states Apple Silicon honestly; enabling on
      unsupported hardware defers to the existing AI unavailable handling.

## 5. Existing-install migration & replay

- [ ] Upgrade an install that has any `didPrompt*` flag (or all permissions granted): launch shows
      NO wizard; `firstRunStage` silently becomes `completed`.
- [ ] Hub ▸ Setup ▸ **Replay the welcome tour**: acts render done-states (permissions sealed, lanes
      showing green/done rows); no setting is written unless a new choice is made; finishing
      returns to completed.
- [ ] Hub ▸ Setup live-status: leave the page open, toggle a permission in System Settings → the
      row updates within ~1 s. The **Relaunch app** button reopens the app with the Hub where it
      was.

## 6. Single-feature paths still work (substrate regression)

- [ ] From Hub ▸ Setup, enable Space-rows alone (launcher off): `FourFingerVertSwipeGesture=2`
      (Mission Control parked on four fingers).
- [ ] Enable the launcher afterwards: `FourFingerVertSwipeGesture=0`, `FourFingerHorizSwipeGesture=2`
      — and restoring the launcher alone returns the four-finger keys to their pre-launcher values.
- [ ] Quit with a horizontal backup present (wizard NOT mid-relaunch): the "Restore the trackpad
      setting?" offer still appears.

## 7. The motion pass (design D10 — feel checks, post-choreography)

Everything here is presentation; a failure is a regression in `Onboarding/WizardMotion.swift` or
the act wiring, never in the state machine. Watch for the *absence* of cuts: at no point in the
whole run should anything appear, disappear, or change in a single frame.

- [ ] **The stage breathes in/out.** First presentation: the window rises ~14 pt while fading in
      (no pop). Finishing on the curtain: the window drifts up and fades out. Closing mid-flow via
      the red button is allowed to be instant (that path is "later", not the finale).
- [ ] **Overture**: icon blooms first under a soft breathing halo, then the name, then the line —
      three distinct beats; the REAL menu-bar mark breathes a few times in the same window.
- [ ] **The ghost hand**: before touching the trackpad, three faint fingertips sweep the stylized
      pad continuously and the strip's highlight follows THEM (pad and strip in lockstep, ~6.5 s
      per sweep). On real touch: ghosts vanish, dots brighten with halos, the pad border warms to
      accent, a glow breathes under the strip, a band of light sweeps the strip, haptic ticks —
      one single felt moment.
- [ ] **Acts unfold, never appear**: every act's headline → line → content → actions bloom
      top-to-bottom; lane rows and feature cards ripple in one after another.
- [ ] **Grants transform, never swap**: on the AX grant the headline crossfades, a light sweep
      washes the strip as the cards become real, the seal stamps in with an expanding ring, and
      the Grant/Skip buttons morph into Continue (scale+fade, no jump cut). Same on SR (the
      faces-arrived sweep plays once, shortly after thumbnails start landing).
- [ ] **Choices glow**: flipping a lane on strikes through the "now", lights the "after", nudges
      the arrow, and warms the row's edge; feature cards get an accent edge + soft lift when on.
- [ ] **Waiting breathes**: the re-login door glyph pulses gently in a halo (calm, no urgency);
      progress dots morph (active stretches into a glowing capsule; performed acts keep a tint).
- [ ] **The playground graduates**: the hold-button inflates slightly with its charge, pops + glows
      at the tick; completing the real contract in the tour (slide–hold–lift) sweeps light across
      the launcher and morphs the hold-button into a plain Continue.
- [ ] **Curtain**: the Ready seal lands with ring + halo + tick, content staggers in, and the
      menu-bar mark breathes again as the copy says where the app lives.
- [ ] **The lanes-live toast** (post-re-login): drifts down into place, rests, lifts away — never
      pops in/out.

## 8. Body-safety regression (the permSR→lanes crash)

The gesture-state reads spawn `/usr/bin/defaults` and pump a nested run loop; they must never run
inside a SwiftUI render. Both former crash sites:

- [ ] On the granted Screen Recording act, click **Continue** → the lanes act slides in and blooms
      normally (previously: SIGSEGV — window vanishes, "screen goes blank").
- [ ] Leave Hub ▸ Setup open for 2+ minutes (the permission poll re-renders it every second),
      then bounce to System Settings and back → the Native gesture / Spaces cards re-read on
      return, no crash, no beachball. The two cards may show "Checking…" for one frame on entry.

## 9. Flow refinements (completion is the gesture — design D12)

- [ ] **Hand act**: while the ghost hand plays, the only button is a quiet "Continue without the
      trackpad". Put three fingers down, scrub, lift → you land on the Accessibility act with NO
      click, and your fingers still drive the strip there. A three-finger tap that never slid does
      NOT advance — a quiet Continue appears instead.
- [ ] **One click per grant**: grant Accessibility in System Settings → seal + sweep, the
      Grant/Skip buttons morph away, and ~1.5 s later the wizard is on the Screen Recording act by
      itself. Same after the SR grant/relaunch: the reveal plays (~2.5 s), then the lanes act
      arrives — at no point is a wizard Continue click needed between the permission acts.
- [ ] **Lanes default on**: all three switches arrive ON; the copy says why and that switching
      off is one flick; "Claim the lanes" remains the single consent action.
- [ ] **Playground plays the real thing**: put four fingers down → the half-size demo MORPHS to
      near-actual size in place (corners stay rounded — no square clipping) while the cards and
      button dim behind it; slide steps items (the band list/grid contract), hold ticks, lift
      settles it back into its slot — and an armed lift converts the hold-button to Continue.
      Known caveat until the re-login: macOS still owns the native four-finger gestures, so a
      vertical four-finger swipe may also pull up Mission Control over the wizard.
- [ ] **Lane toggle in the playground**: the "Four-finger launcher" row reflects the lanes-act
      choice; toggling ON writes the relocation (caption flips to "Claimed — goes live at your
      next log-in"), OFF quietly restores the backup — no modal either way.
- [ ] **Tour bands**: exactly flame (every app from your bands, deduped) + display (12 window
      actions, two full rows) — plus sparkles only while the AI card is on, clipboard only while
      the Clipboard card is on; flipping the cards adds/removes those bands live.
