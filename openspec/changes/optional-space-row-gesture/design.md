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

### D2. Reuse the `defaults`-on-trackpad-domains mechanism

Add a config type for the vertical keys — either a sibling of `TrackpadGestureConfig` (e.g. `VerticalGestureConfig`) or an extension of it — operating on the same two domains (`com.apple.AppleMultitouchTrackpad`, `com.apple.driver.AppleBluetoothMultitouch.trackpad`). Reassign three-finger vertical → off and four-finger vertical → on, with a JSON backup of prior values, exactly like `disableThreeFingerHorizontal()`/`restore()`.

*Alternative considered — private CGS/SkyLight gesture APIs:* rejected; the `defaults` approach is already proven in this codebase and avoids fragile private symbols.

### D3. Lifecycle managed like `spaces-rearrange-config`, not like the horizontal prompt

The horizontal flow is a one-shot consent + manual restore-on-quit offer. Because the vertical change is bound to a toggle the user flips on/off, manage it like `manageSpacesRearrange`: apply on launch when the opt-in is set, restore the exact prior value on quit, reapply on relaunch. `AppCoordinator` observes the toggle (`dropFirst` to skip the persisted initial value) and calls apply/restore.

### D4. Avoid the re-login seam by gating emission on "applied & effective," not on "flag set"

If the reassignment needs a re-login to take runtime effect (as the horizontal one does), then between "user enables the toggle" and "user logs back in" the OS vertical gesture is still live. If we started emitting row steps the instant the flag flipped, the bug would reappear in that window. So **row-step emission is gated on the change being effective**, not merely on the flag.

Two candidate gates, chosen after the D-OQ1 spike resolves whether the change is live or needs re-login:
- **If live:** post the trackpad-driver notification, then enable emission immediately.
- **If re-login required:** persist the flag and apply the system change now, but only enable row-step emission starting at the **next launch** (by which point the user has re-logged-in). Surface the re-login warning in the toggle's UI, mirroring `needsReloginWarning`.

### D5. Recognizer change is minimal and behavior-preserving when off

`GestureRecognizer` keeps its axis-lock untouched. The only change: vertical accumulation / `emitRowStep` is skipped unless the (effective) opt-in is on. When off, post-activation vertical motion is ignored by us and left entirely to the OS — restoring the original "fresh vertical yields to the OS" guarantee for the whole gesture, not just pre-activation.

## Risks / Trade-offs

- **[Re-login required for the change to take effect]** → D4 gates emission so row-switching only goes live once the OS gesture is actually relocated; UI warns the user, mirroring the horizontal flow's existing pattern.
- **[Wrong/incomplete defaults keys — vertical may not behave like horizontal]** → D-OQ1 spike confirms the exact keys and whether the `com.apple.dock` Mission Control / App Exposé bools are also needed before implementation; the horizontal code is the template but vertical may pair up+down on a single key.
- **[User loses native three-finger Mission Control / App Exposé]** → opt-in and off by default; consent dialog and onboarding clearly state the gesture moves to four fingers and is restored on quit.
- **[Managed Macs (MDM) block the write]** → reuse the existing non-fatal warning pattern from `applySpacesRearrange`; the feature simply doesn't engage and row-stepping stays gated off.
- **[Stale backup if the app crashes before restore]** → reuse the absent-aware / JSON-backup approach already proven in `SpacesRearrangeConfig` / `TrackpadGestureConfig`; reapply-on-launch keeps the system in the intended state while the opt-in is on, and restore is idempotent.

## Open Questions

- **D-OQ1 (blocking, first task):** Confirm the exact vertical defaults keys and semantics. Candidates: `TrackpadThreeFingerVertSwipeGesture` / `TrackpadFourFingerVertSwipeGesture` in both trackpad domains, possibly plus `com.apple.dock` `showMissionControlGestureEnabled` / `showAppExposeGestureEnabled`. Determine (a) whether up (Mission Control) and down (App Exposé) are one key or two, and (b) whether the change is live or needs re-login. This decides D4's gating branch.
- **Naming:** persisted key and user-facing label ("Space-row switching" vs. "Two-axis switching"). Cosmetic; not blocking.
- **Restore-on-quit UX:** auto-restore silently (like `spaces-rearrange`) vs. offer-to-restore (like the horizontal prompt). Leaning silent auto-restore for consistency with the bound-toggle model.
