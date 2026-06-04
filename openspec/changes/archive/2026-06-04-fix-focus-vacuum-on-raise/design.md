## Context

A 5-agent research workflow diagnosed an intermittent system-wide input freeze (cursor moves; clicks/scroll/keyboard dead; fixed only by Mission Control). Verified high-confidence root cause: **`raise()` leaves a frontmost app with no key window** (a focus vacuum). The WindowServer routes pointer/keyboard/scroll to the focused app's key window; with no key window there is nowhere to route, so events are dropped. The cursor still moves (WindowServer-drawn, focus-independent); the gesture still works (multitouch read passively via OpenMultitouchSupport, bypassing HID routing); Mission Control forces focus re-arbitration, which is why only it clears the freeze. Secure-input and event-tap causes were ruled out by grep (we have none).

## Goals / Non-Goals

**Goals:**
- After every raise, exactly one app is frontmost **with a key window** — no focus vacuum, on current- or off-Space.
- Remove the overlay-panel configuration that perturbs WindowServer focus arbitration.

**Non-Goals:**
- Changing enumeration, the gesture, or the grid.
- Eliminating the (separate, documented) physical finger-lift-at-edge behavior.

## Decisions

### D1 — Always end raise() with activate() (the fix)
Unify both branches into one sequence that cannot leave a focus vacuum:
1. If `cgs.offSpaceRaiseSupported`: `GetProcessForPID` (reject zero PSN) → `_SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)` → `makeKeyWindow` (returns Bool).
2. If an AX element resolved: `AXUIElementPerformAction(kAXRaiseAction)` + set `kAXMainAttribute` + set the app's `kAXFocusedWindowAttribute`.
3. **Always** finish with `NSRunningApplication(pid)?.activate()`.
The trailing `activate()` lets AppKit establish key state even if the byte protocol failed or the element was stale — closing the race. The off-Space branch no longer early-returns after the SkyLight handshake.
- *Why not bare `activate()` alone (today's current-Space path)?* On macOS 14+ a lone `activate()` from an `.accessory` app can deactivate the previously-key app without establishing a new key window — the exact vacuum. The SkyLight handshake + AX focus + trailing activate together establish key state reliably.

### D2 — makeKeyWindow reports success
Check both `SLPSPostEventRecordTo` return values; return `true` only if both succeed. A failed post no longer silently fronts a process with no key window — the caller falls through to AX + activate.

### D3 — Non-interfering panel config
`level`: `.screenSaver` → `.popUpMenu` (renders above the menu bar / context menus — all a transient overlay needs). `collectionBehavior`: drop `.stationary` (Exposé-exempt — opts the window out of Mission-Control handling, the mechanistic link to "only Mission Control fixes it"), leaving `[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`. Matches AltTab's known-good config.

### D4 — Defensive teardown + modal hygiene
`hide()` becomes idempotent and also runs on app `resignActive`; the recognizer reset (→ cancel → hide) runs when the touch engine stops, so a stalled multitouch stream can't leave the panel ordered-in. Each `NSAlert.runModal()` in the accessory app is preceded by `NSApp.activate(ignoringOtherApps: true)` so the modal is key/frontmost rather than spinning a nested modal loop owned by a non-frontmost app.

## Risks / Trade-offs

- **[Trailing activate() on off-Space could double-front]** → Both the SkyLight handshake and activate() target the same app/window, so they reinforce rather than conflict; the Space switch still happens once.
- **[`.popUpMenu` lower than `.screenSaver`]** → Still above normal windows and the menu bar; a transient switcher never needs the screen-saver band.
- **[Hard to prove a race is fixed]** → Verification is a sustained rapid-switch session (dozens of commits, current- and off-Space) with no Mission-Control rescue; optional env-gated logging confirms a non-nil focused window after each raise.
