## Context

The four-finger launcher already supports a comfortable "trigger high, navigate low" hold: `GestureRecognizer.trackLauncher` latches at four-finger begin and then lives while **two or more** contacts remain, re-baselining the step origin (`launcherContacts`) on every contact-count change, ending below two. The scroll tap consumes the two-finger movement during launcher nav via the `launcherOpen` clause in `AppCoordinator.shouldConsumeScroll`, and `refreshRowSwitchingGate` keeps the tap running while the launcher opt-in is effective.

The three-finger switcher (`trackSwitcher`) has no such relaxation: it lives only while the latched three-finger count is satisfied (`requireExactlyThree ? ==3 : >=3`) and treats any drop below that as the lift. This change brings the launcher's post-activation relaxation to the switcher, scoped to **after activation only** so the trigger stays an unambiguous three-finger swipe.

## Goals / Non-Goals

**Goals:**
- After the switcher overlay is shown, allow relaxing from three fingers to two and keep navigating the horizontal window grid and the vertical Space-rows; lift (below two contacts) commits.
- Re-baseline the step origin on contact-count change so the centroid shift from a leaving finger emits no spurious step (reuse the launcher's proven technique).
- Consume the two-finger movement while the switcher overlay is open so it does not scroll the window underneath.
- Zero behavior change for users who keep three fingers down the whole time, and zero change pre-activation.

**Non-Goals:**
- No pre-activation relaxation: a two-finger contact SHALL NOT trigger or activate the switcher (rejected Fork A / Option 1).
- No new settings toggle, no native-gesture relocation, no re-login, no new permission, no overlay-UI change.
- No change to launcher, Space-row, Mission Control synthesis, or commit/raise logic.

## Decisions

### Decision: Relax post-activation only, mirroring `trackLauncher` but bounded by activation
`trackSwitcher` splits on `activated`:
- **Pre-activation** (`!activated`): unchanged. Keep today's `target = requireExactlyThree ? ==3 : >=3`, the `tooMany` cancel, and the below-target debounce. The trigger still requires three fingers.
- **Post-activation** (`activated`): the gesture is alive while `count >= 2` (still honoring the existing `tooMany` cancel for `requireExactlyThree`, so a fourth finger cancels exactly as today). On any contact-count change, re-baseline `startCentroid`/`lastCentroid` and clear `stepAccumulator`/`stepAccumulatorY`, gated by a new `switcherContacts` field (the exact analog of `launcherContacts`). End (commit) when `count < 2`, reusing the existing `belowTargetFrames` debounce so an edge flicker to one finger does not prematurely commit.

*Why over a fully-latched launcher-style begin:* the launcher can latch liberally because four-fingers-from-rest is unmistakable; two-finger horizontal is the most common scroll gesture, so allowing the switcher to *activate* at two fingers would invite accidental triggers. Gating relaxation behind `activated` keeps the deliberate three-finger trigger and makes the relaxation pure post-trigger comfort.

### Decision: Run the scroll tap whenever the switcher is enabled; add a `switcherOpen` consume clause
`shouldConsumeScroll(fingerCount:launcherOpen:)` gains a `switcherOpen` parameter and becomes `fingerCount >= 3 || launcherOpen || switcherOpen`, with `switcherOpen` supplied as `overlay.isVisible`. `refreshRowSwitchingGate` starts the tap while `isEnabled` (in addition to the existing row/launcher-effective gates, which it now subsumes since both already require the switcher enabled).

*Why always-on-when-enabled rather than start/stop per overlay-show:* a `CGEventTap` has non-trivial creation latency; starting it at `gestureDidActivate` would risk missing the first scroll frames of the relax-to-two, and per-gesture start/stop adds races. The tap consumes nothing outside its predicate (three-finger contact is not a native scroll, and `switcherOpen` is only true during an active gesture), so an always-running tap is observationally identical to a per-gesture one while being simpler and race-free. The cost is one session event tap whenever the switcher is enabled — the same kind already run for row/launcher users.

## Risks / Trade-offs

- **Momentum scroll after commit** → As the overlay hides on lift, trailing momentum-scroll events may briefly not be consumed and nudge the background window. The launcher has the identical exposure and it has been acceptable; navigation movements are small and deliberate, so momentum is minimal. No mitigation beyond noting it.
- **Always-running scroll tap for all enabled users** → Slightly broader than today (previously only row/launcher users ran the tap). Mitigated by the predicate consuming nothing outside an active gesture, and by the tap requiring only the already-held Accessibility permission. Without Accessibility the tap simply can't consume — the same degradation path window-raising already has.
- **`requireExactlyThree` interaction** → Preserved verbatim: a fourth finger still cancels under exact-three (the `tooMany` branch runs in both phases). The relaxation only ever lowers the floor to two; it never widens the ceiling.
- **Two-finger centroid stability** → Proven by the launcher, which already navigates a finer grid at two fingers; the contact-count re-baseline absorbs the centroid jump from the leaving finger.
