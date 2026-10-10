# Design — Keep Awake: agent curtain + trusted apps

## D1 — Trust = the event's responsible app
`CGEvent.eventSourceUnixProcessID` is 0 for hardware and the poster's PID for synthesized events. The PID is mapped to the app *responsible* for it (`responsibility_get_pid_responsible_for_pid`, dlsym, crash-safe; fallback: walk the parent chain to the first running app or enclosing `.app` bundle), cached 30 s. Trusted = this process, or the responsible app's bundle id is on `keepAwakeTrustedApps` (default `ai.shift.vex.desktop`). Unresolvable PIDs fail closed (untrusted). Verified live: a process spawned under Vex's runtime resolves to `ai.shift.vex.desktop`.

## D2 — Swallow, don't lock (the curtain)
An active `cgSessionEventTap` at the head, mask = all events (pointer, keys, modifiers, scroll, gestures — Space swipes / Mission Control — and system-defined events such as the power / Touch ID button). Trusted → pass; otherwise → return nil (swallowed) and report an intrusion. The tap re-enables itself on `tapDisabledByTimeout/UserInput` and a 2 s timer re-checks. Out of reach: the power button's hardware action, a closed lid, the raw multitouch stream (watched via `noteTouch`, which reports an intrusion instead of stopping).

## D3 — One owner check, Touch ID first
The first intrusion opens a `LAContext` check with `.deviceOwnerAuthenticationWithBiometrics` and no fallback button, so the curtain never needs to pass a click or key while the prompt is up; the finger that raised the prompt is read by it. One check at a time; 20 s timeout invalidates the context (= failure). Without biometrics: lock mode → failure (the lock screen takes over); curtain mode → `.deviceOwnerAuthentication` with pass-through ON only for that check.

## D4 — Outcomes and ordering
- success → `stop(.explicit)`: curtain down, restore, no lock.
- failure, lock mode → `stop(.input)`: monitors off → cancel check → **lock** → curtain down → watchdog off → restore keyboard → restore displays → end assertion.
- failure, curtain mode → stay curtained; ignore intrusions for 5 s (a resting palm cannot loop the prompt).
- explicit stop mid-check cancels the check; a late answer is ignored (`isActive` guard).

## D5 — Crash watchdog (fail closed)
The active tap dies with its process, which would leave the Mac open. On curtain install the app writes `Application Support/ThreeFingerSwitcher/curtain.active` and starts its own executable as `--curtain-watchdog <pid> <marker>` (handled in `runThreeFingerSwitcher()` before AppKit starts). Every 0.5 s: marker gone → exit; owner gone + marker present → `ScreenLocker.lock()` → remove marker → exit. Pure rules (`parse`, `verdict`) are unit-tested.

## D6 — Fallback when the tap is refused
No tap → the passive `InputActivityMonitor` (now trust-policy filtered) and an input-path stop that locks if the item wants lock OR curtain (curtain without a tap must not leave the Mac open).

## Risks
- Touch ID matching of a finger already resting when the prompt opens is expected but must be verified on hardware (owner test). The guard log records what tripped each check (`type14` = power/Touch ID press) for tuning.
- The password fallback (curtain mode, no biometrics) passes all input for ≤ 20 s.
- Swallowed `mouseMoved` may still move the cursor image (WindowServer); clicks and keys never land.
