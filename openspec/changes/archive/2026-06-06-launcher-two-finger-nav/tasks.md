## 1. Recognizer: latched launcher gesture driven by two-or-more fingers

- [x] 1.1 In `Gesture/GestureRecognizer.swift`, keep the latched launcher gesture alive while the live contact count is `≥ 2` after activation; never re-evaluate the latched mode or cancel on contact-count changes (the transient three-finger count during a four→two lift must NOT hand off to the switcher).
- [x] 1.2 Re-baseline the item/context step reference origin (and clear any in-progress sub-step carry) on every contact-count change, measuring subsequent travel from the centroid of the remaining contacts — so relaxing or adding fingers emits no step.
- [x] 1.3 End the launcher gesture (emit the existing `launcherDidEnd` intent) when the contact count drops below two; leave dwell/arm/fire ownership in `LauncherOverlayController` unchanged.
- [x] 1.4 Keep the all-four-fingers-held path byte-for-byte unchanged (activation + four-finger navigation must not regress); confirm three-finger switcher behavior is untouched.

## 2. Runtime ownership: consume two-finger scroll while the launcher is open

- [x] 2.1 Extend the scroll tap consume predicate in `App/AppCoordinator.swift` from `currentFingerCount >= 3` to `currentFingerCount >= 3 || launcherOverlay.isVisible`, so two-finger navigation is captured while the overlay is open and reverts to `≥3`-only when it closes.
- [x] 2.2 Confirm the tap start/stop lifecycle is unchanged (only the consume rule widens); two-finger scrolling passes through whenever the launcher is closed.

## 3. Tests

- [x] 3.1 `GestureRecognizer` test: an active launcher gesture fed frames going 4→3→2 emits NO switcher intents and does not cancel (stays a launcher gesture).
- [x] 3.2 `GestureRecognizer` test: a contact-count change accompanied by a centroid shift emits no item/context step (origin re-baselined); movement *after* the new baseline emits the expected steps.
- [x] 3.3 `GestureRecognizer` test: the gesture emits `launcherDidEnd` when contacts drop below two; assert it is not emitted while `≥ 2` contacts remain.
- [x] 3.4 Consume-rule test: extract the consume decision to a pure helper and assert it is true at two fingers when the overlay is open, false at two fingers when closed, and unchanged for `≥ 3` fingers.

## 4. Manual verification (stable-signed build)

- [x] 4.1 Open the launcher with four fingers, relax to two, navigate items/context — smooth, no jump at the hand-off, no background scrolling.
- [x] 4.2 The four→two transition (passing through three fingers) never flips to the switcher and never cancels the launcher.
- [x] 4.3 Dwell-to-arm then lift (below two) fires the armed item; a quick flick that drops below two before arming dismisses harmlessly.
- [x] 4.4 With the launcher closed, two-finger scrolling works normally everywhere (no consumed scroll).
- [x] 4.5 Holding four fingers for the whole gesture still works exactly as before.
