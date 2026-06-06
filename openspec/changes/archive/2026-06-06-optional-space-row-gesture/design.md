## Context

The app reads the trackpad **passively** via `OpenMultitouchSupport` (an `MTDevice`-style snoop). It never consumes touches, so macOS's own three-finger recognizers run in parallel on the exact same fingers. The horizontal conflict was already solved structurally: `TrackpadGestureConfig` permanently reassigns the OS's three-finger horizontal "Swipe between full-screen applications" to four fingers, so the WindowServer stops claiming it.

The vertical axis was left to the OS on purpose — `TrackpadGestureConfig`'s comment says *"Mission Control / App Exposé live on the Vert keys, which we never touch,"* and the consent dialog promises *"Mission Control and App Exposé … are not affected."* But the later Space-row feature made `GestureRecognizer.update()` map post-activation vertical travel to `gestureDidStepRow`. So once the overlay is up, vertical finger motion feeds **both** our row-stepper and the OS's still-enabled Mission Control / App Exposé recognizers. When the vertical component crosses the OS's independent velocity/distance threshold, macOS fires Mission Control (up) or App Exposé (down) and steals the gesture. It's intermittent because slow, deliberate row changes (`rowStepDistance = 0.12`) stay under the OS threshold while quick flicks trip it.

Hard constraints discovered while exploring:
- **No runtime per-overlay suppression.** Trackpad-gesture `defaults` do not apply live (the existing horizontal code notes a re-login is generally required), and even if they did, a toggle would race the in-flight gesture.
- **No event interception.** The Mission Control swipe is recognized inside the WindowServer and is not exposed as a consumable `CGEvent`.

So the only robust lever is the same one used for horizontal: reassign the native three-finger vertical gesture to four fingers. The cost is real — the user loses native three-finger Mission Control / App Exposé — so it must be **opt-in**.

Existing patterns to mirror:
- `SpacesRearrangeConfig` — opt-in flag (`manageSpacesRearrange`) that applies a system setting on launch, restores it on quit, reapplies on relaunch, with an absent-aware backup. `AppCoordinator` observes the toggle and drives apply/restore.
- `TrackpadGestureConfig` — backup/restore of trackpad keys across the two trackpad domains via `/usr/bin/defaults`, with a `needsReloginWarning`.

## Goals / Non-Goals

**Goals:**
- Eliminate the native vertical gesture stealing the swipe while the switcher is active.
- Make Space-row switching a single opt-in that binds the recognizer feature and the system change together, so the conflict seam can never exist.
- Default to **off**: out of the box, native Mission Control / App Exposé keep working on three fingers and the app never uses the vertical axis.
- Faithfully back up and restore the user's prior trackpad vertical-gesture setting (apply-on-launch / restore-on-quit / reapply-on-relaunch).

**Non-Goals:**
- Suppressing the OS vertical gesture only while the overlay is visible (infeasible — see Context).
- Intercepting/consuming touch events (infeasible).
- Changing horizontal window switching or the horizontal `TrackpadGestureConfig` behavior.
- A custom Mission Control / App Exposé replacement — we only relocate them to four fingers; the OS still provides them there.

## Decisions

### D1. One opt-in binds the feature and the system change

A single persisted flag (working name `manageVerticalGesture`, surfaced as "Space-row switching") gates **both**:
1. whether `GestureRecognizer` emits vertical row steps, and
2. whether the native three-finger vertical gesture is reassigned to four fingers.

They cannot be independently enabled. This is the core fix: today's bug is exactly the state "row-stepping on, native vertical still owned by OS," and binding makes that state unrepresentable.

*Alternative considered — keep them as two independent settings:* rejected. Any combination where row-stepping is on but the native gesture is still claimed reproduces the bug; an independent pair invites exactly that misconfiguration.

*Alternative considered — drop vertical row-switching entirely (navigate rows by horizontal roll-over or a modifier):* rejected for now because it discards a built feature, but noted as the fallback if the trackpad reassignment proves unreliable across macOS versions.

### D2. Free three-finger vertical via `TrackpadThreeFingerVertSwipeGesture = 0` (CONFIRMED by empirical diff)

An empirical before/after diff on a real Mac (toggling System Settings ▸ Trackpad ▸ More Gestures ▸ Mission Control from three → four fingers, then `defaults` diff) settled this authoritatively. Switching the native vertical swipe from three to four fingers changes **exactly two keys and nothing else**:

```
com.apple.AppleMultitouchTrackpad          TrackpadThreeFingerVertSwipeGesture: 2 → 0
com.apple.driver.AppleBluetoothMultitouch.trackpad  TrackpadThreeFingerVertSwipeGesture: 2 → 0
```

What this proves:
- **`TrackpadThreeFingerVertSwipeGesture` is the lever.** `2` = three-finger vertical enabled (Mission Control up + App Exposé down owned by the OS); `0` = three-finger vertical disabled (freed). It controls *both* up and down together — Mission Control and App Exposé are a single linked finger-count setting in System Settings.
- **`TrackpadFourFingerVertSwipeGesture` stays `2`** — four-finger vertical remains enabled, so Mission Control / App Exposé keep working on four fingers. We don't need to write it (only ensure it's enabled).
- **The `com.apple.dock` keys are pure on/off booleans** (`showMissionControlGestureEnabled` / `showAppExposeGestureEnabled` both stayed `1`), *not* finger-count. We never touch them — Mission Control / App Exposé stay enabled, just on four fingers.
- **Runtime effect needs a re-login.** The stored value flips to `0` immediately, but three-finger vertical kept firing until logout (observed directly). So this is the re-login path (D4), exactly like the horizontal `TrackpadGestureConfig`.

So `VerticalGestureConfig` is modeled on `TrackpadGestureConfig` (two trackpad domains, `/usr/bin/defaults`, JSON backup) with `SpacesRearrangeConfig`'s absent-aware restore: back up the prior `TrackpadThreeFingerVertSwipeGesture` / `TrackpadFourFingerVertSwipeGesture` values, write three-finger `= 0` and ensure four-finger `= 2`, and restore the exact prior values. No `killall Dock` (that's a Dock-domain mechanism and these are trackpad-domain keys; it would not apply them anyway).

*Alternative considered — `com.apple.dock` keys as the finger-count lever:* refuted by the diff (they stayed `1` through the three→four switch; they are booleans).

*Alternative considered — private CGS/SkyLight gesture APIs:* rejected; the `defaults` approach is already proven in this codebase and avoids fragile private symbols.

### D3. Lifecycle: persist while the opt-in is on; restore only on explicit opt-out (NOT on quit)

The opt-in flag is the source of truth, and `AppCoordinator` observes it (`dropFirst` to skip the persisted initial value) to apply on enable / restore on disable, plus apply-on-launch when the flag is set.

The one critical departure from `spaces-rearrange-config`: **the relocation is never restored on quit.** `spaces-rearrange` can safely round-trip per session because `mru-spaces` applies *live* (`killall Dock`). The vertical change needs a **re-login**, and logout quits the app — so a quit-time restore would rewrite the value back on the very logout that applies it, and the feature could never become effective (the apply-on-launch would re-dirty it every session, keeping `isEffectivelyFree` permanently false). Instead this follows the **horizontal `TrackpadGestureConfig`** model: the freed value persists across logout/quit while the opt-in is on, and is reverted only on an intentional user action — toggling the opt-in off (`handleVerticalGestureToggle`) or the menu Restore. `reapply-on-relaunch` is a no-op once the value already reads `0`, so on the post-re-login launch nothing is written, `changedThisSession` stays false, and the gate turns on.

### D4. Gate emission on "applied & effective," not on "flag set" (re-login path, confirmed)

Row-step emission is gated on the relocation being **effective**, not merely on the flag, so the conflict can't reappear in the window where row-stepping is live while the OS still owns three-finger vertical.

The empirical diff (D2) confirmed the change needs a **re-login** to take runtime effect — the stored value flips to `0` immediately but three-finger vertical kept firing until logout. So the gate must not trust "stored value == freed" alone on the session that applied it.

Mechanically `VerticalGestureConfig.isEffectivelyFree` = `isFree (stored value reads 0) && !changedThisSession`. On the launch that applies the relocation, `changedThisSession` is true → not yet effective → warn (mirroring `needsReloginWarning`) and keep row stepping off. On the next launch (after the user has logged back in), the value already reads `0` and nothing is changed this session → effective → the coordinator sets `GestureRecognizer.rowSwitchingEnabled = true`. If the user had already freed three-finger vertical in System Settings (so it's effective at launch with no change this session), row switching engages immediately. This is the same detect-and-warn contract the horizontal gesture already uses.

### D5. Recognizer change is minimal and behavior-preserving when off

`GestureRecognizer` keeps its axis-lock untouched. The only change: vertical accumulation / `emitRowStep` is skipped unless the (effective) opt-in is on. When off, post-activation vertical motion is ignored by us and left entirely to the OS — restoring the original "fresh vertical yields to the OS" guarantee for the whole gesture, not just pre-activation.

## Risks / Trade-offs

- **[Re-login required for the change to take effect]** → D4 gates emission so row-switching only goes live once the OS gesture is actually relocated; UI warns the user, mirroring the horizontal flow's existing pattern.
- **[Wrong/incomplete defaults keys — vertical may not behave like horizontal]** → D-OQ1 spike confirms the exact keys and whether the `com.apple.dock` Mission Control / App Exposé bools are also needed before implementation; the horizontal code is the template but vertical may pair up+down on a single key.
- **[User loses native three-finger Mission Control / App Exposé]** → opt-in and off by default; consent dialog and onboarding clearly state the gesture moves to four fingers and is restored on quit.
- **[Managed Macs (MDM) block the write]** → reuse the existing non-fatal warning pattern from `applySpacesRearrange`; the feature simply doesn't engage and row-stepping stays gated off.
- **[Stale backup if the app crashes before restore]** → reuse the absent-aware / JSON-backup approach already proven in `SpacesRearrangeConfig` / `TrackpadGestureConfig`; reapply-on-launch keeps the system in the intended state while the opt-in is on, and restore is idempotent.

## Open Questions

- **D-OQ1 (spike — FULLY RESOLVED via empirical diff):** A before/after `defaults` diff on a real Mac (System Settings ▸ Trackpad ▸ More Gestures ▸ Mission Control, three → four fingers) is authoritative:
  - **Lever:** `TrackpadThreeFingerVertSwipeGesture` in both trackpad domains, `2` (three-finger enabled) → `0` (freed). It controls Mission Control (up) and App Exposé (down) together — they are a single linked finger-count setting.
  - **Four-finger:** `TrackpadFourFingerVertSwipeGesture` stays `2`; Mission Control / App Exposé keep working on four fingers. The `com.apple.dock` keys stayed `1` — confirmed pure on/off booleans, not finger count, never touched.
  - **Live vs re-login:** **re-login required** — stored value flips immediately but three-finger vertical kept firing until logout (observed directly). → re-login path in D4 (detect-and-warn, defer emission).
  - No residual: an earlier (refuted) hypothesis that the Dock keys carry finger count came from low-confidence external sources; the on-machine diff overrides it.
- **Naming:** persisted key and user-facing label ("Space-row switching" vs. "Two-axis switching"). Cosmetic; not blocking.
- **Restore-on-quit UX:** auto-restore silently (like `spaces-rearrange`) vs. offer-to-restore (like the horizontal prompt). Leaning silent auto-restore for consistency with the bound-toggle model.

## Update — runtime-ownership approach (validated by spike; supersedes the disable-only design)

The disable-only approach shipped and killed the original *stealing*, but real-device testing surfaced two unacceptable side effects, all rooted in one fact: **disabling the OS three-finger vertical turns it into a plain scroll.**

1. Idle three-finger up/down no longer opens Mission Control / App Exposé — and the user wants idle MC to keep working without a horizontal pre-trigger.
2. During the overlay, that scroll leaks to the window under the cursor (the background scrolls), because the passive touch read doesn't consume it.
3. Three-finger movement became a generic scroll.

The settings toggle is global all-or-nothing, so it can't express "Mission Control when idle, ours when the overlay is open." The resolution is to **own the three-finger gesture at runtime**. Two assumptions were spiked and **proven live on-device**:

- **(A) Synthesize Mission Control / App Exposé ourselves** — `CoreDockSendNotification("com.apple.expose.awake")` (Mission Control) / `("com.apple.expose.front.awake")` (App Exposé). The symbol lives behind Carbon; `import Carbon` does NOT force-load it, so it must be `dlopen`'d explicitly (mirroring the crash-safe `CGSPrivate` dlsym pattern).
- **(B) Consume the three-finger scroll** — a session `CGEventTap` on `scrollWheel` (`.defaultTap`, head-insert) sees and swallows it. Probe in the signed app: `active(consume)`, 825 events, scrolling suppressed.

**Permission finding (better than expected):** the active consuming tap needs **only Accessibility** — which the app already holds for window raising. **Input Monitoring is NOT required** (probe: Accessibility YES / Input Monitoring NO → active tap created + consumed). The earlier "needs Input Monitoring" reading was an artifact of an ad-hoc build with broken Accessibility. So: no new permission or onboarding burden.

### Architecture (D5-revised)
Keep the OS three-finger vertical disabled (state 0 → scroll; the existing `manageVerticalGesture` machinery, one-time re-login), then own the whole gesture at runtime — the tap can only intercept *scroll*, which is exactly what state 0 produces:

- **horizontal** → window switcher (existing);
- **3 fingers + vertical + overlay open** → row-switch; the tap consumes the scroll so the background doesn't move;
- **3 fingers + vertical + idle** → synthesize Mission Control (up) / App Exposé (down) via CoreDock; the tap consumes the scroll so it doesn't also scroll.

Components: `ScrollEventTap` (built, validated) consumes scroll while ≥3 fingers are down; `GestureRecognizer` gains an idle-vertical path that emits a "trigger Mission Control / App Exposé" intent instead of yielding; `AppCoordinator` feeds live finger-count + overlay state into the tap's consume predicate and routes the idle-vertical intent to a `MissionControl` helper (CoreDock). The one-time re-login (state 0) is still required, but everything else is runtime — no per-use re-login, idle MC restored, no background scroll, Accessibility-only.

### Build/sign constraint (process note)
The agent's sandboxed shell has **no keychain access**, so it can only produce ad-hoc builds — which break TCC (Accessibility) and the app. In-app testing must use a **stable-signed** build produced from the user's own Terminal (`INSTALL=1 ./scripts/build-app.sh`, which auto-uses the `ThreeFingerSwitcher Dev` cert). Agent does code + `swift build`/`swift test`; user installs to test.
