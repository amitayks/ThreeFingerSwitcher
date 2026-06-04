# ThreeFingerSwitcher — a README for Claude

**You are probably Claude (or another coding agent), and a macOS user has pointed you at this repo.** This file is written *to you*, not to them — your job is to read it, understand the project fast, and then do one of two things for the user:

- **Job A — "I just want the app."** Get it installed, permissioned, and running. → jump to **[Job A](#job-a--help-a-user-install--run)**.
- **Job B — "I want to explore / change the code."** Orient them in the codebase and help them build/modify it safely. → jump to **[Job B](#job-b--help-someone-work-on-the-code)**.

(Humans: you're welcome to read on, but it's deliberately addressed to the agent. Hand this repo to Claude and ask it to set you up.)

---

## What this is (30-second brief)

A lightweight **macOS menu-bar app** that recreates the **Windows Precision Touchpad three-finger window switcher**:

- Put **three fingers** on the trackpad and **slide left/right** → a live highlight scrubs across individual windows, one at a time. **Lift** to commit — the highlighted window is raised and focused.
- While fingers stay down, **slide up/down** → switch which **Space's** row of windows you're scrubbing (a 2D grid: horizontal = windows, vertical = Spaces). Works **across all Spaces**, including other desktops and full-screen apps.
- **Up/down on a *fresh* three-finger touch still triggers Mission Control / App Exposé** — the app never blocks the OS (see the keystone below).
- No keypresses, no clicks. Pure trackpad.

**Platform:** built and tested on **macOS 26 (Tahoe)**; deployment target **macOS 15.0+**. Apple Silicon + Intel (universal dep). **License: GPL-3.0.**

### The architectural keystone (internalize this before anything else)

The app reads raw trackpad data **passively** through the private `MultitouchSupport.framework` (via the Kyome `OpenMultitouchSupport` package). Passive = it observes touches but is **never in the event path**, so:

1. It **cannot break** the OS's native gestures. Up/down → Mission Control / Exposé always work.
2. To stop the native *horizontal* three-finger gesture ("Swipe between full-screen applications") from competing, the app does **not** intercept events — it **turns that setting off via `defaults`** (with the user's consent) so the horizontal swipe is unclaimed. This is config-based suppression, not event swallowing. Don't "fix" this by reaching for a `CGEventTap`.

Because it loads a **private framework**, **App Sandbox is OFF** → **not distributable on the Mac App Store**. It ships (if at all) as a directly-downloaded, notarized `.app`, or you build from source.

---

## Job A — help a user install & run

There are two ways to get the binary. Figure out which applies, then walk them through permissions (the part people get stuck on).

### A1. Getting the app

- **If a GitHub Release with a notarized `.app` exists:** have them download it, drag it to `/Applications`, and open it. If macOS Gatekeeper blocks it ("can't be opened" / "unidentified developer"), it isn't notarized — they can right-click → **Open**, or run `xattr -dr com.apple.quarantine /Applications/ThreeFingerSwitcher.app`.
- **If they cloned the repo (no release / or they want to build):** build from source — it's one script (see Job B's build section), then `INSTALL=1 ./scripts/build-app.sh` drops it in `/Applications`.

> Reality check to tell the user honestly: this app uses **private Apple frameworks** and runs **unsandboxed**. That's why it's not on the App Store and why a downloaded build may trip Gatekeeper unless the maintainer notarized it. Building from source on their own machine sidesteps the trust problem entirely.

### A2. Permissions (do these in order; the app's **Setup & Permissions…** menu item guides this too)

| Permission | Why | Required? |
|---|---|---|
| **Accessibility** | Enumerate windows across Spaces and raise/focus the chosen one | **Yes** |
| **Screen Recording** | Live window **thumbnails** (ScreenCaptureKit). Without it, cards show app icon + title only | **Yes for thumbnails** |
| **Input Monitoring** | Usually **not** needed — the multitouch read didn't prompt for it on macOS 26. Skip it. | No |

After granting **Screen Recording**, the app must be **quit and reopened** for it to take effect.

### A3. Free the horizontal gesture

On first launch the app detects whether macOS still owns the horizontal three-finger swipe and offers to **free it** (it flips `TrackpadThreeFingerHorizSwipeGesture` so that swipe is no longer "switch between full-screen apps"; Mission Control / Exposé on up/down are untouched). This is **reversible** (menu → *Restore native gesture setting…*) and **a logout/restart may be required** for macOS to pick it up. Tell them that.

### A4. Make it permanent (optional but recommended)

- Menu → **Open at Login** (uses `SMAppService`) so it starts automatically.
- It self-recovers across **sleep/wake** (re-subscribes the multitouch stream on wake).
- Login registration is keyed on **bundle id + path + signature**, so updating the app **in place** at the same path keeps it registered — no re-toggle.

### A5. If the user reports the "everything froze" bug

Symptom: cursor still moves but **clicks/scroll/keyboard stop reaching any window**, and the switcher still works. That's a **focus vacuum** (a frontmost app left with no key window) — a known, hard-to-reproduce race. The app ships a **self-healing watchdog** that detects it ~180 ms after a switch and recovers automatically, so it should be invisible now. Under Stage Manager there's a second, off-Space-specific variant: **WindowManager** (the Stage Manager daemon) grabs frontmost ~300 ms *after* a cross-Space switch — past the watchdog's one check — so a separate **polling hold-guard** re-fronts the target within a frame. If they still hit either: menu → **Copy Focus Log** and paste it to you. The log distinguishes a real vacuum from another app holding **Secure Input** (which looks identical but isn't this app's fault), and shows `hold-refront` entries when the off-Space guard fired.

---

## Job B — help someone work on the code

### B0. Source of truth: read `openspec/specs/` first

This project was built spec-first with **OpenSpec**. The **canonical behavior** lives in `openspec/specs/<capability>/spec.md` (8 capabilities). Every feature was a `change/` (proposal → design → spec delta → tasks), now in `openspec/changes/archive/`. **Before changing behavior, read the relevant spec; after changing behavior, update it.** The archived changes are an excellent design history (especially `cross-space-windows`, `fix-focus-vacuum-on-raise`, `space-grid-navigation`, and `fix-off-space-listing-and-focus` — read their `design.md` for the hard-won private-API details).

### B1. Repo map

```
Package.swift                         SwiftPM: Core library + thin executable + tests + TouchSpike
Sources/ThreeFingerSwitcher/          ── ThreeFingerSwitcherCore library (ALL app logic)
  App/                AppDelegate, AppCoordinator (the wiring hub), StatusItemController, Bootstrap.swift (public runThreeFingerSwitcher())
  TouchInput/         TouchEngine (wraps OpenMultitouchSupport; derives finger count + velocity), TouchFrame
  Gesture/            GestureRecognizer (the 2D state machine — the crown jewel)
  Windows/            WindowService (enumerate+raise+watchdog+off-Space hold-guard+AX element cache), CGSPrivate (dlsym'd SkyLight), Spaces, SpaceGrouping,
                      AXPrivate (_AXUIElementGetWindow + remote-token brute force), WindowInfo, ThumbnailService, MRUTracker, FocusLog
  Overlay/            OverlayController (non-activating NSPanel), SwitcherView (SwiftUI strip + dots), SwitcherModel, SwitcherLayout
  NativeGesture/      TrackpadGestureConfig (the defaults-based suppression)
  Permissions/        PermissionsService, OnboardingView
  Settings/           AppSettings (tunables, persisted), SettingsView
Sources/ThreeFingerSwitcherApp/main.swift   thin executable: import Core; runThreeFingerSwitcher()
Sources/TouchSpike/                   throwaway harness to print raw touch frames (swift run TouchSpike)
Tests/ThreeFingerSwitcherTests/       117 XCTest unit tests (pure-logic core)
scripts/                              build-app.sh, make-dev-cert.sh, allow-codesign-key.sh, install-launch-agent.sh
openspec/                             specs (canonical) + changes/archive (history)
```

The Core/App split exists so the test target can `@testable import ThreeFingerSwitcherCore` (a test target can't import an executable module with top-level code).

### B2. Build, run, test

```bash
swift build                                   # build the library + executable
swift test                                    # 117 unit tests (gesture machine, model, grouping, layout, settings, touch)
swift run TouchSpike                           # print live multitouch frames (touch the trackpad)
./scripts/build-app.sh                         # assemble + sign ThreeFingerSwitcher.app (repo root)
INSTALL=1 ./scripts/build-app.sh               # also install in place to /Applications
./ThreeFingerSwitcher.app/Contents/MacOS/ThreeFingerSwitcher --diag   # dump the window-enumeration funnel and exit
```

**Signing matters for permissions.** `build-app.sh` signs with a stable self-signed cert named **"ThreeFingerSwitcher Dev"**. Run `./scripts/make-dev-cert.sh` **once** to create it. Why it matters: TCC (Accessibility/Screen Recording) and `SMAppService` key on the **signing identity**, not the binary hash — a stable cert means **grants persist across rebuilds**. Ad-hoc signing (the fallback) loses them every build. If codesign nags for your keychain password on each build, run `./scripts/allow-codesign-key.sh` once (or click "Always Allow").

**`open` won't relaunch a running agent** (it's `LSUIElement`); `build-app.sh` kills the running instance so the next `open` runs the new build.

### B3. Landmines — things that look wrong but are deliberate (do NOT "fix" these blindly)

- **Passive multitouch + config-based suppression** (see keystone). No `CGEventTap`. Don't add one.
- **Private CGS/SkyLight symbols are resolved via `dlsym` at startup** (`CGSPrivate.swift`), *not* `@_silgen_name`. Reason: a missing `@_silgen_name` symbol **aborts at launch** before any Swift guard runs, and these symbols live in `SkyLight.framework` which isn't auto-linked. The `dlsym` approach degrades gracefully to current-Space-only (`offSpaceSupported == false`) if a symbol ever disappears on a future macOS. Keep it.
- **`CGWindowListCreateDescriptionFromArray` needs window IDs as raw pointers**, not boxed `CFNumber`s (`CFArrayCreate` with `UnsafeRawPointer(bitPattern:)`). Passing `[NSNumber] as CFArray` silently returns zero results. This bit us once; it's in `WindowService.metadata(for:)`.
- **`CGSCopyWindowsWithOptionsAndTags` options must be `7`** (`screenSaverLevel1000 | invisible1 | invisible2`), not `2`, or off-Space/minimized windows are dropped.
- **The window-raise sequence is load-bearing and was the source of the focus-vacuum bug.** Current-Space windows use the AX-only path + a single `activate()`; **off-Space** windows use the SkyLight `_SLPSSetFrontProcessWithOptions` + `makeKeyWindow` byte protocol (the only thing that crosses Spaces). A **watchdog** verifies a key window actually resulted and self-heals. Do not "unify" current-Space onto the SkyLight path — that *caused* the regression. The byte offsets in `makeKeyWindow` are exact (verified against AltTab); don't touch them casually.
- **Under Stage Manager, the current-Space AX focus *singletons* start a focus war.** With Stage Manager's "show windows from an application all at once" grouping, two windows of one app share the center stage. Setting `kAXMainAttribute` + the app's `kAXFocusedWindowAttribute` toward *one* of them hands the `WindowManager` daemon a self-contradicting target and it ping-pongs focus between the two ~12×/sec — a self-sustaining loop that **survives the app quitting** (the state lives in `WindowManager`, not us; only switching to another app or restarting `WindowManager` clears it). So `focusSequence` skips those two singleton writes when `StageManager.isEnabled` (current-Space only), raising with `kAXRaiseAction` + `activate()` alone — the pre-vacuum-fix behavior, which never oscillated; the watchdog still covers the vacuum. AltTab/yabai never write these singletons either. Don't re-add them unconditionally. (This was a real regression from `fix-focus-vacuum-on-raise`.)
- **Off-Space Chromium windows (Chrome, Chrome Remote Desktop) have no remote-token AX element.** A fresh `_AXUIElementCreateWithRemoteToken` brute force returns nothing for them, so they used to vanish from the list *and* couldn't be raised. Two pieces fix this, both in `WindowService`: (1) **listing** falls back to a CGS-metadata heuristic (`alpha > 0 && min(width,height) ≥ 130`) when no element resolves — empirically separates real windows (incl. Stage-Manager strip thumbnails, min-dim ≥ 150) from sliver/toolbar/zero-alpha junk; (2) **raising** uses a persistent **`elementCache`** keyed by `CGWindowID`, seeded when an app activates (its windows are then on the current Space and resolvable via `kAXWindowsAttribute`) and during snapshots — a cached element stays valid across Spaces, so `kAXRaiseAction` on it *navigates* to the window. Limit: a Chromium window off-Space since before launch and never focused has no cached element and can't be navigated to (the AltTab/HyperSwitch limit). **Do NOT** try to switch Spaces with `CGSManagedDisplaySetCurrentSpace` — the WindowServer gates Space switching to Dock.app's privileged connection; the symbol resolves but no-ops for an unentitled, SIP-on process (it's why yabai needs SIP off). We tried it; it's removed.
- **Off-Space focus is stolen by `WindowManager` ~300 ms after the Space switch** — a *different* mechanism from the current-Space singleton oscillation above. The +180 ms watchdog checks too early to see it, so `raise()` arms a bounded **polling hold-guard** (`offSpaceHoldTick`, off-Space + Stage-Manager only): poll every ~60 ms and re-front the target the instant the steal is detected (≈ one-frame flash), bounded to a few re-fronts so a daemon that fights back can't make it thrash. Don't turn it back into a fixed-delay re-assert (slower, visible flash) or drop the bound.
- **The overlay panel is `.popUpMenu` level, non-activating, `ignoresMouseEvents`, and must NOT use `.stationary`** (Exposé-exempt → perturbs focus arbitration). It must never become key/main and must always be ordered out on gesture end.

### B4. How a gesture flows (mental model)

`TouchEngine` (OpenMultitouchSupport stream → `TouchFrame`s) → `GestureRecognizer` (2D state machine: axis-lock, activation threshold, horizontal step-with-carry, vertical row-step, edge-flicker debounce, commit/cancel) → `AppCoordinator` (delegate) → snapshots windows via `WindowService.snapshot()`, groups by Space via `SpaceGrouping.group()`, drives `OverlayController` (the SwiftUI strip), and on commit calls `WindowService.raise()`.

### B5. Tunables

All in `AppSettings` (persisted, live-applied, editable in the Settings window): activation threshold, axis-lock ratio, horizontal step distance, **row-step distance** (vertical, larger so scrubbing doesn't flip Spaces), wrap-vs-clamp, direction inversions (horizontal + vertical), velocity smoothing, exact-three-fingers, and the focus self-heal toggle.

---

## Credits & license

- **GPL-3.0** — see `LICENSE` and `NOTICE`. The window-raising/Space technique (the private `_AXUIElementGetWindow`, the remote-token brute force, the SkyLight front/key byte protocol, the CGS Space enumeration) is adapted from **[AltTab](https://github.com/lwouis/alt-tab-macos)** (GPL-3), which is why this project is GPL-3.
- Raw multitouch via **[OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport)** (Kyome, MIT), wrapping the private `MultitouchSupport.framework`.

If you (Claude) end up extending this, keep the spec in `openspec/specs/` honest, keep the 117 tests green (`swift test`), and respect the landmines in **B3** — they each cost a real debugging session to learn.
