# Proposal — Keep Awake: agent curtain + trusted apps

## Why

Keep Awake is how the owner leaves the Mac working for agents (Vex computer use) while away. Real use on 2026-10-10 showed three gaps in the guard (`keep-awake-guard-effects`):

1. **The guard locked the Mac out from under the agent.** It ignored only input synthesized by *this* process. An agent's clicks come from another process (Vex's `vexcu` helper), so they looked like a stranger: the guard locked the screen, the Mac went dark, and every later agent action hit the lock screen.
2. **A lock stops the agent too.** On a locked Mac no synthetic input reaches any app. "Work inside, block the outside world" needs input blocking, not a lock.
3. **Touch ID meant two touches.** Reaching for Touch ID (a palm on the trackpad, the button press) tripped the guard, which locked first; the owner then had to touch Touch ID again.

## What Changes

- **Trusted apps (global setting, default Vex).** Input synthesized by a process whose *responsible app* is on the list (or this app) never trips the guard. Hardware input (source PID 0) and input from any other process do. Editable on the General page (running apps or any app chosen from disk).
- **The curtain (guard mode).** Once armed, an ACTIVE event tap swallows every input event from a person or an untrusted app and passes trusted apps' input, so the agent keeps working while a stranger's touch does nothing. The first blocked input (or trackpad contact) opens ONE Touch ID check. Success ends the session and restores the screen with **no lock**. Failure keeps the curtain up (5 s cooldown). If biometrics are unavailable, the system password prompt is used with input passed through for the bounded check window.
- **Lock mode runs behind the same curtain.** Input opens the Touch ID check instead of locking at once; the owner's finger ends the session without a lock; a failed check, Cancel, or 20 s without an answer locks the screen (lock before curtain removal and before restore — no gap, no flash). Lock mode never uses the password path (the real lock screen handles passwords).
- **Crash watchdog.** While a curtain is up, a second instance of the executable (`--curtain-watchdog <pid> <marker>`) locks the Mac if the app dies with the marker still present; a clean stop removes the marker.
- **Fail closed.** If the tap cannot be installed (no Accessibility), the guard falls back to the passive monitor and an input-path stop locks — also in curtain mode.
- **Guard hook + log.** Optional shell command run on `intrusion` (first per session), `auth-ok`, `auth-failed` (env `TFS_GUARD_EVENT`, `TFS_GUARD_DETAIL`); every event is logged to `~/Library/Logs/ThreeFingerSwitcher/keep-awake-guard.log`.
- **Inspector.** The lock toggle becomes a Guard picker: Off / Lock / Curtain.

## Impact

- Affected specs: `automations` (MODIFIED guard requirement, ADDED curtain/trust/watchdog requirements).
- Affected code: new `InputTrust`, `CurtainEventTap`, `KeepAwakeGuard` (authenticator, watchdog, hook, log); `KeepAwakeController` (curtain lifecycle, effects seam growth), `InputActivityMonitor` (trust policy), `Bootstrap` (watchdog entry), `LaunchItem`/`LaunchService`/`AppCoordinator`/`AppSettings`, `BandsCanvas` + `HubControls` + `HubFeaturePages`.
- No new permission (event taps ride the granted Accessibility; Touch ID via LocalAuthentication). Decode-safe item option (`curtain: Bool?`), no schema bump. Stacks on `keep-awake-guard-effects`.
