# Design — Automations: Keep Awake

## Context

The launcher fires items as one-shot effects (`LaunchService.fire`). "Keep the Mac awake for background agents, screen dark" is fundamentally a **mode**: it holds resources (a power assertion, a modified brightness) for an open-ended duration and must be cleanly torn down. This change introduces the minimal machinery for a stateful, toggle-style launcher item, and ships one automation.

## Decisions

### D1 — A new first-class `.automation(AutomationKind)` kind, not new `SystemAction`s
A dedicated Automations *category* was chosen over folding "Keep Awake" into the existing Actions browser, so the category can grow (future: Do Not Disturb, auto-dim, scheduled tasks) and so the toggle/stateful semantics are modeled distinctly from one-shot `SystemAction`s. Growth = one new `AutomationKind` case; the `LaunchItemKind.automation` wrapper and all wiring are reused. New associated value is `Codable`-synthesized and decode-safe (the `.url`/`.action` precedent), so **no `Favorites` schema bump** and existing favorites are untouched.

### D2 — "Awake-but-dark", not "sleep-and-poke"
Keep Awake holds a continuous `ProcessInfo.beginActivity([.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated])` assertion so the display never sleeps and therefore never idle-locks, and sets brightness to minimum so the screen is dark. The screen stays *on but dark*, not asleep — this is what keeps GUI-driving agents alive and avoids a lock gap. The ~5-minute heartbeat is a **safety net**, not the primary mechanism: it re-pins brightness to minimum (defeating another app or auto-brightness raising it) and re-declares user activity (`IOPMAssertionDeclareUserActivity`) to reset any idle/lock timer the display-sleep assertion doesn't cover. No `caffeinate` subprocess and no new permission — `beginActivity` is in-process (the `ModelManager` precedent) and `DisplayServices` brightness needs no entitlement (the `action-value-controls` precedent).

### D3 — First-touch-to-stop, armed only after the trackpad empties
The stop signal is the user returning and touching the trackpad — the natural "I'm back" gesture, and free to detect because the app already owns a live multitouch stream (`TouchEngine.onFrame`, which emits every frame including empty-on-lift). The subtlety: the trigger *is* a trackpad gesture (four-finger into the launcher, lift to fire). So the controller does not arm immediately. It waits for `fingerCount == 0` once (the triggering gesture fully lifted), transitions to **armed**, and stops on the next `fingerCount > 0`. This mirrors the odometer "re-baseline on contact change" landmine — the triggering gesture can never self-cancel. The stop is a pure side effect on the touch stream: it is **non-consuming**, so the same touch that stops Keep Awake still flows to the recognizer as a normal gesture.

State machine:
```
 fire → STARTING (dim+assert, awaiting empty)
        └─ fingerCount==0 once ─→ ARMED
                                  └─ fingerCount>0 ─→ STOP (restore brightness, endActivity)
 also STOP on: app quit · will-sleep · menu-bar "Stop"
```

### D4 — Guaranteed, idempotent teardown (the no-leak requirement)
The controller holds nothing while idle. On start it owns exactly: a `[CGDirectDisplayID: Float]` brightness snapshot, one `beginActivity` token, one repeating `Timer`, and an arming flag. `stop()` invalidates the timer, calls `endActivity` once, restores each snapped display, clears the flag — and is idempotent (stopping when stopped is a no-op). It is also invoked on `NSWorkspace.willSleepNotification` (if the machine sleeps anyway — e.g. lid close forces it — stand down cleanly so wake restores brightness) and on `applicationShouldTerminate` (synchronous, so brightness is restored before the process exits). The `Timer` is a plain Foundation timer doing non-animation work, so it is **not** subject to the idle-CPU-spin landmine (which is specific to SwiftUI repeating animations in retained-hidden hosting views). No SwiftUI HUD / breathing animation is added.

### D5 — Testable effect seam
`KeepAwakeController` takes an injectable `Effects` struct (active-display list, brightness get/set, activity begin/end, declare-user-active) defaulting to the real implementations. Unit tests drive the full **start → awaiting-empty → armed → stop** cycle with recording fakes: assert dim-on-start, self-cancel immunity (residual contacts before empty don't stop), arm-then-stop restores exactly the snapshot, and idempotent double-stop. The live power/brightness/lock behavior is compile-verified (`xcodebuild`) and user-run-verified in a stable-signed build.

### D6 — All active displays
Keep Awake dims **every** active display (`CGGetActiveDisplayList`), snapshotting and restoring each. Displays whose brightness can't be read (`DisplayBrightness.get == nil`, e.g. some external/DDC displays) are skipped — not dimmed, nothing to restore — never a failure. Today's `DisplayBrightness` consumer only touches `CGMainDisplayID()`; the all-displays iteration is the one net-new bit of display code.

### D7 — No opt-in setting; the item is the opt-in
Unlike features that own a global controller behind an `AppSettings` toggle (Dock previews, clipboard), Keep Awake needs no enable flag: placing the `.automation(.keepAwake)` item in a band *is* the opt-in, and it can only be fired via the launcher (which already requires the switcher/touch engine running). So there is no `observeXToggle`, nothing to apply in `start()`; the controller simply starts inactive.

## Risks / caveats

- **Lid-closed laptop sleeps regardless.** `beginActivity` cannot override a clamshell lid-close sleep (unless on power + external display). Stated in the spec; the will-sleep force-stop makes the wake state clean.
- **Dimmed-to-black recoverability.** Because brightness is pinned near-zero, a failed restore is user-visible. Mitigated by the menu-bar backup stop + force-restore on quit/sleep, and by restore being a direct synchronous `DisplayServices` set.
- **User raises brightness while active.** The heartbeat re-pins to minimum, so a manual raise is undone within ~5 min. Acceptable for v1 (the whole point is a dark screen); revisit if it annoys.
