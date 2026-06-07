## 1. Recognizer: post-activation relaxation in `trackSwitcher`

- [x] 1.1 Add a `switcherContacts` field to `GestureRecognizer` (analog of `launcherContacts`); seed it in `begin(_:)` from `frame.fingerCount`.
- [x] 1.2 Split `trackSwitcher` on `activated`: keep the existing pre-activation branch (three-finger `target`/`tooMany`/below-target debounce) byte-for-byte so the trigger and pre-activation cancel are unchanged.
- [x] 1.3 In the post-activation branch, keep the gesture alive while `count >= 2` (still running the existing `tooMany` cancel for `requireExactlyThree`, so a 4th finger cancels as today); on any `count != switcherContacts`, re-baseline `startCentroid`/`lastCentroid` and clear `stepAccumulator`/`stepAccumulatorY`, then call `update(frame)`.
- [x] 1.4 End (commit) the post-activation gesture when `count < 2`, reusing the `belowTargetFrames` debounce (`count == 0 || belowTargetFrames >= 2`) exactly like `trackLauncher`.
- [x] 1.5 Confirm `update(_:)` needs no change (it gates on `activated` and accumulates from the re-baselined centroid); verify two-finger vertical still routes through the existing `rowSwitchingEnabled` row-step path.

## 2. Scroll tap: consume rule + run gate

- [x] 2.1 Add a `switcherOpen` parameter to `AppCoordinator.shouldConsumeScroll(fingerCount:launcherOpen:)` → `fingerCount >= 3 || launcherOpen || switcherOpen`.
- [x] 2.2 In the `scrollTap.consumePredicate` closure, pass `switcherOpen: self.overlay.isVisible` alongside the existing `launcherOpen: self.launcherOverlay.isVisible`.
- [x] 2.3 In `refreshRowSwitchingGate`, run the tap while the switcher is enabled (start when `isEnabled`, in addition to the existing row/launcher-effective conditions, which it now subsumes); ensure it still stops when the switcher is disabled.

## 3. Tests

- [x] 3.1 Update `ScrollConsumeRuleTests` for the new `switcherOpen` parameter; add cases: consumes at two fingers when `switcherOpen` is true; passes through at two fingers when both `launcherOpen` and `switcherOpen` are false; `≥3` still consumes regardless.
- [x] 3.2 Add `GestureRecognizerTests` cases mirroring the launcher relaxation tests: after a three-finger horizontal activation, relaxing to two fingers keeps emitting window-steps; a contact-count change emits no spurious step then steps after the new baseline; lift below two contacts commits; two contacts keep the gesture alive (no premature commit). (Also updated two edge-flicker tests whose old "two fingers = below-target" premise the relaxation changes.)
- [x] 3.3 Add a guard test that a two-finger contact never activates the switcher (trigger still requires three fingers) and that dropping below three before activation cancels.

## 4. Build & spec sync

- [x] 4.1 `swift build` and `swift test` green (do not assemble/sign/install the `.app` from the agent shell — per CLAUDE.md).
- [x] 4.2 After implementation, run `/opsx:sync` (or `openspec`) to fold the `gesture-recognition` and `runtime-gesture-ownership` deltas into the main specs, then archive the change.
