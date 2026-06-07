## Context

This is a rolling bug-fix change for the four-finger launcher's favorites section. Each bug is captured as its own spec delta + task block so the change reads as an ordered changelog; archiving it later folds every delta into the affected specs at once.

**Bug #1 — current state.** `LaunchService.fireApp(_:strategy:)` (`LaunchService.swift:278`) resolves a running app to one of three relocation outcomes via `SpaceWindowMover.relocate(pid:)`:

```
relocate(pid) → .broughtHere  (a window is on the current Space)   → activate + raise
              → .failed        (windows exist only off-Space)       → goToWindow(pid)
              → .noWindows      (no windows anywhere)               → app.activate()   ← bug
```

The `.noWindows` branch (`LaunchService.swift:337-339`) assumes `NSRunningApplication.activate()` will make the app recreate a window. It will not: `activate()` only fronts the process. macOS only recreates a window in response to the `applicationShouldHandleReopen(_:hasVisibleWindows:)` event, which is sent by a Dock-icon click or by `NSWorkspace.openApplication` on an already-running app. The *not-running* path already does the right thing — it calls `launch(bundleURL:newInstance:)` (`LaunchService.swift:283`), which is exactly `NSWorkspace.openApplication`. The windowless-running path simply never reaches it.

## Goals / Non-Goals

**Goals:**
- A running-but-windowless app fired under `bring-existing-here` (or `smart`'s single-window fallback) produces a usable window on the current Space, with no Space switch and no teleport.
- Keep the change minimal and aligned with the existing teleport-safety invariants; reuse the same workspace-reopen mechanism the not-running path uses.

**Non-Goals:**
- No change to the on-Space focus path (`.broughtHere`) or the off-Space go-to-window path (`.failed`).
- No change to `SpaceWindowMover`'s classification logic.
- Not adding effect-path unit tests (the launch effect path is on-device-verified, per the `LaunchService` file header); Bug #1 needs no logic-test change.
- Not addressing the `.failed`→`goToWindow` snapshot-disagreement edge (a possible future bug entry in this rolling change, out of scope here).

## Decisions

**D1 — Reopen via the workspace in `.noWindows`, not `activate()`.**
Replace the `app.activate(options: [])` in the `.noWindows` branch with `launch(bundleURL:newInstance:false)` (i.e. `NSWorkspace.openApplication` with `createsNewApplicationInstance = false`, `activates = true`). This is the Dock-click equivalent that fires the reopen handler. "Running but windowless" then behaves identically to "not running" — both want a fresh window from the workspace.

*Alternative considered — `makeNewWindow(for:)` (press File ▸ New Window / ⌘N):* rejected as the primary mechanism. `⌘N` semantics vary by app (in Xcode it is "New File", not a window) and require an app with a meaningful new-window command; reopen is the correct, app-agnostic "give me my default window" signal.

**D2 — Thread the bundle URL into `bringExistingHere`.**
`bringExistingHere` currently takes only `NSRunningApplication`. The reopen needs a bundle URL target. The URL is already in scope in `fireApp` (`guard case let .app(bundleURL, _)`), so pass it down (`bringExistingHere(app, bundleURL:)`). Preferred over reading `app.bundleURL` so the reopen targets the same bundle the item was configured with (avoids surprises if `app.bundleURL` differs).

## Risks / Trade-offs

- [`activates = true` on reopen brings the app forward] → Intended: the user fired the item to get to that app; fronting it on the current Space is the desired outcome, and there is no off-Space window to teleport to.

## Bug #2 — some apps ignore reopen while windowless

On-device, the Bug #1 reopen fixed Xcode (and apps like it) but **not** apps that ignore the reopen event while fully windowless — notably Mac Catalyst apps such as Shortcuts, whose scene-based lifecycle doesn't reconnect a window from a plain reopen. Those apps only got a window from a fresh launch.

**Decision (D3) — non-destructive escalation ladder in `.noWindows`.** The single reopen becomes `reopenWindowlessApp(_:bundleURL:)`:
1. Reopen via `NSWorkspace.openApplication` (covers Xcode/Safari/Finder/Preview/TextEdit).
2. After ~0.5s, check `windowCount(pid:)` (count of `kAXWindowsAttribute`). If still zero, call `makeNewWindow(for:)` — press File ▸ New Window, else synthesize ⌘N.

The delay does double duty: it lets a *working* reopen land first so we don't double-open a window, and it gives the app's menu time to become the active one after reopen activates the app (so the menu-press / ⌘N targets a live responder).

*Rejected — auto quit+relaunch for stubborn apps:* would fix even Shortcuts, but it is destructive and violates the non-destructive contract of `smart`/`bring-existing-here` (quitting a windowless background app could kill in-flight work — a player, a download, a live connection). Apps that respond to neither reopen nor a new-window command remain the explicit job of `quit-and-reopen-here`.

**Residual risk:** if a stubborn app (possibly Shortcuts) also has no working File ▸ New Window / ⌘N while windowless, the non-destructive ladder still can't produce a window; the user must set that item to `quit-and-reopen-here`. This is accepted by design rather than reaching for an automatic quit. (To be confirmed on-device — task 2.6.)

## Bug #3 — Next/Previous Space action silently does nothing

The launcher's Next/Previous Space actions synthesize the OS shortcut ⌃→ / ⌃← (the app **cannot** switch Spaces directly — `WindowService.swift:398` documents that `CGSManagedDisplaySetCurrentSpace` is gated to Dock's privileged connection and dead for a SIP-on unentitled process; the app only switches Spaces as a side effect of raising a window that lives there, which can't reach an empty adjacent Space). So the synthesized shortcut is the only viable mechanism, and it was firing but not switching.

**Diagnosis (on-device signals).** Physical ⌃←/→ switches Spaces, and the symbolic-hotkey plist shows Move-left/right-a-space `enabled = 1` (with no custom `value`, so the system *default* mask is in force). Other `postKey(…, toPid: nil)` actions work (screenshots), so the system-wide synthesis path is healthy. The single differentiator: Space uses an **arrow** key, screenshots use a number key.

**Decision (D4) — synthesize a faithful arrow press for arrow-key system shortcuts.** On macOS the arrow keys are function keys, so a genuine arrow event carries **both** `kCGEventFlagMaskNumericPad` **and** `kCGEventFlagMaskSecondaryFn` (Fn) alongside the modifier, and the default Space-switch hotkey matches only such an event. The fix posts `[.maskControl, .maskNumericPad, .maskSecondaryFn]` for `.nextSpace`/`.previousSpace` (factored as `spaceSwitchFlags`). Non-arrow shortcuts are left unchanged (they need none of this — proven by screenshots working).

*Iteration note:* a first attempt added only `.maskNumericPad` (the canonical single-flag fix) on the theory that Fn might be a *significant* modifier that could break the match. On-device that still did nothing, confirming the matcher requires the event to fully resemble a real arrow press — so Fn was added too. `.maskControl`-only and `.maskControl + .maskNumericPad` both verified non-working on-device.

## Bug #4 — front window not focused after a Space switch

With Bug #3 fixed, Next/Previous Space switches Spaces, but (like the native shortcut) the destination's front window is visually front yet **not key** — the user must click before typing.

**Decision (D5) — settle, then raise the OS's own front window.** `LaunchService` gains an injected `onSpaceSwitch` hook fired right after the ⌃→/⌃← post. `AppCoordinator` polls `SpaceService.currentModel().currentSpaceIDs` until it changes (bounded ~1.6s so a no-neighbour ⌃→ doesn't loop or steal focus), then `windowService.raise(...)` the front window of **`NSWorkspace.frontmostApplication`** on the new Space. `raise()` is the same battle-tested current-Space focus path (AX raise + activate + watchdog) the switcher uses, so it reliably establishes key focus.

**Confirmed root cause (on-device `=== trace ===`):** the user runs **Stage Manager**. After a Space switch, `NSWorkspace.frontmostApplication` is frequently **`WindowManager`** (the Stage Manager daemon), not a real app — the log showed `cleanup frontmost=WindowManager(27487) foundFrontmostWin=false`, so the frontmost-app path focused nothing. (An earlier z-order attempt without a settle delay also misfired because z-order isn't settled mid-transition.) **Final approach:** detect the flip by polling `currentSpaceIDs`, wait ~0.45s for the transition to finish, then raise the **first switchable window in the destination Space's front-to-back z-order** (`SpaceService.windowsInSpace` mapped through `snapshot()`, which already excludes `WindowManager`/agents/non-standard subroles). This ignores `frontmostApplication` entirely. The same diagnostics confirmed the mechanism works when the right window is chosen (Switch 1 focused Chrome Remote Desktop, watchdog PASS).

*Why poll then settle:* the flip fires near the transition *start*; acting then gets steamrolled and reads stale z-order/frontmost. Polling finds the flip; the +0.45s lets the WindowServer (and the Stage Manager front-steal that lands ~300ms post-switch) settle before we raise.

*Known limitation:* multi-display `currentSpaceIDs` is a set; we raise the first front window found across the current Spaces — fine for single-display, revisit if needed.

## Bug #5 — launcher lingers on the destination Space

The launcher panel is `.canJoinAllSpaces`, and `LauncherOverlayController.end()` fired the armed item via `onFire` *before* its `defer { hide() }` ran. So for a Space-switch item the ⌃→ was posted while the panel was still visible, and the all-Spaces panel was carried onto the destination Space (lingering until the WindowServer reconciled).

**Decision (D6) — hide before fire, plus a decisive post-settle re-hide.** First, reorder `end()` to `hide()` (orderOut) **before** `onFire`. Safe (the panel is non-activating; `.action(.closeFrontWindow)`'s target is captured at open time), but on-device this alone did **not** stop the lingering — the WindowServer's Space-switch transition re-materialises the all-Spaces panel on the destination Space after the pre-fire orderOut. So the decisive fix lives in the D5 settle poll: once the Space change is detected (transition done), `AppCoordinator` calls `launcherOverlay.hide()` again, and that post-transition orderOut sticks.

*Rejected — `.moveToActiveSpace` instead of `.canJoinAllSpaces`:* could avoid the panel ever being a member of the destination Space, but its semantics for a reused non-activating panel are uncertain (it may key off app activation, which an accessory's non-activating panel never does), risking the panel failing to appear at all. The window switcher's overlay also uses `.canJoinAllSpaces` successfully, so we keep it.

**Confirmed root cause + final fix (Decision D7).** The on-device `=== trace ===` showed `launcherVisible=false` at *every* stage — so the pre-fire `orderOut` ran, yet the panel still appeared on the destination Space. An orderOut'd `.canJoinAllSpaces` panel leaves a **rendered ghost** on the Space you switch to; further `hide()` calls are no-ops because AppKit already considers it hidden. The fix is to **destroy** the panel in `hide()` — `orderOut` + `close()` + `panel = nil` (with `isReleasedWhenClosed = false` so ARC owns the lifetime) — so it's removed from the WindowServer entirely; `show()` recreates it fresh on the current Space (the model state persists on the controller). The post-settle re-hide (D6) is now redundant but harmless (the panel is already nil).
