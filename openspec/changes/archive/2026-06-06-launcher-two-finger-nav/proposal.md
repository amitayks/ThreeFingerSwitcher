## Why

Holding four fingers down while scrubbing to an item and then dwelling is the most awkward part of the launcher's ergonomics — four splayed fingers are tiring and imprecise for the fine selection the dwell-to-arm commit needs. The hand naturally wants to relax to two fingers once the launcher is open. We can let it: four fingers *open* the launcher, then the user **drops to two fingers** to navigate comfortably, lifting below two to fire (when armed) or dismiss. This keeps the launcher's best traits — instant open, and the auto-dismiss-on-lift that makes a stray flick harmless — while making the actual selection feel like effortless two-finger scrolling.

## What Changes

- **Drop-to-two-finger navigation.** Once a four-finger swipe has activated the launcher, the gesture **continues while at least two fingers remain down** instead of requiring all four. Two-finger centroid travel drives item stepping (horizontal) and context stepping (vertical), identical to the four-finger steps. Keeping four fingers down works exactly as before — dropping to two or three is purely optional and additive.
- **Graceful finger-count hand-off.** Lifting from four to two passes transiently through **three fingers** (the switcher's count) and shifts the touch centroid as fingers leave. The recognizer treats the launcher gesture as **latched** for its lifetime: a mid-gesture count change never re-routes to the switcher or cancels, and the tracking origin is **re-baselined** on each count change so navigation doesn't jump.
- **Lift-to-commit redefined as "below two fingers."** The launcher still ends on lift; "lift" now means the contact count drops **below two**. On end it fires the armed item (dwell-to-arm unchanged) or dismisses — the auto-dismiss-on-lift behavior is **preserved exactly**.
- **No persistent / modal launcher.** The launcher is deliberately *not* made sticky. It stays a held gesture (now two-or-more fingers) so the lift-to-dismiss safety remains; the overlay never lingers after the hand leaves the trackpad. (Explicitly out of scope per product decision.)
- **Scroll ownership extends to two fingers while open.** The session scroll tap must swallow **two-finger scroll while the launcher overlay is open** (today it consumes only for ≥3 fingers), so two-finger navigation doesn't scroll the app underneath. It reverts to normal two-finger scrolling the instant the launcher closes.

## Capabilities

### New Capabilities

<!-- None — this is an ergonomic enhancement to the existing launcher gesture. -->

### Modified Capabilities

- `gesture-recognition`: the four-finger launcher gesture is **latched** at activation and then driven by **two-or-more** fingers (not four): item/context steps come from the ≥2-finger centroid with origin re-baselining on every contact-count change; the transient three-finger count during a four→two lift never re-routes to the switcher or cancels; the gesture **ends when the count drops below two**, firing the armed item or dismissing.
- `runtime-gesture-ownership`: the scroll tap's consume predicate is extended so it also swallows scroll **while the launcher overlay is open** (covering two-finger scroll during navigation), reverting to the `≥3`-fingers-only rule when the launcher is closed; normal two-finger scrolling is unaffected at all other times.

## Impact

- **Modified code:**
  - `Gesture/GestureRecognizer.swift` — the launcher branch: keep the gesture alive while `≥2` contacts remain; re-baseline the step origin on contact-count change; end on `<2`; ensure the latched launcher mode ignores the count crossing 3 (no switcher hand-off, no cancel mid-gesture).
  - `TouchInput/ScrollEventTap.swift` — consume predicate becomes `fingerCount ≥ 3 || launcherOverlayOpen`.
  - `App/AppCoordinator.swift` — expose an "launcher overlay open" signal to the tap's consume predicate; confirm the launcher overlay lifecycle (show on activate, end on `<2`) is unchanged otherwise.
- **No new permissions, no system-settings changes** beyond what the launcher already does. Uses the existing passive multi-touch read (`currentFingerCount` is already tracked) — no new private APIs.
- **Builds on (now archived) `four-finger-launcher`.** Assumes its recognizer latching, launcher overlay, dwell-to-arm commit, and the session scroll tap are present.
- **Risks to de-risk in design:** the four→three→two transition (centroid jump + transient switcher count), precise scoping of the two-finger consume so normal scrolling is never broken, and confirming a quick four-finger flick that drops below two before arming still dismisses harmlessly.
- **Tests:** recognizer latches launcher mode and keeps tracking through a count drop (4→3→2) without emitting switcher intents or cancelling; ≥2-finger steps emit item/context intents with re-baselined origin; end fires on `<2`; the tap consume predicate covers the launcher-open case while leaving two-finger scroll alone when closed.
