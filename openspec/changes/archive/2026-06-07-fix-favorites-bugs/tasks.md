<!-- Rolling change: each bug gets its own numbered group. Append new groups (and matching
     spec deltas) as further favorites-section bugs are found; archive only when the section
     is judged stable. -->

## 1. Bug #1 — "Go to its window" silently fails for a running, windowless app

- [x] 1.1 In `LaunchService.fireApp(_:strategy:)`, pass the item's `bundleURL` into `bringExistingHere` (e.g. `bringExistingHere(app, bundleURL:)`)
- [x] 1.2 In `bringExistingHere`'s `.noWindows` branch, replace `app.activate(options: [])` with `launch(bundleURL: bundleURL, newInstance: false)` (workspace reopen → fires the app's reopen handler → fresh window on the current Space)
- [x] 1.3 Update the `.noWindows` branch comment to state the reopen rationale (activate() fronts the process but does not recreate a window; only NSWorkspace.openApplication / a Dock click sends the reopen event)
- [x] 1.4 Confirm the `.broughtHere` and `.failed` branches are unchanged (no regression to on-Space focus or off-Space go-to-window)
- [x] 1.5 Verify it compiles: `swift build`
- [x] 1.6 On-device (user-run): Xcode windowless-in-background now reacts correctly to all scenarios (user-confirmed). Surfaced Bug #2: apps that ignore reopen (e.g. Shortcuts) still don't open a window — see group 2.

## 2. Bug #2 — some apps ignore reopen while windowless (e.g. Shortcuts)

- [x] 2.1 Add `reopenWindowlessApp(_:bundleURL:)`: reopen via the workspace, then after a short delay check `windowCount(pid:)` and, only if still zero, fall back to `makeNewWindow(for:)` (non-destructive escalation, no double-open when reopen worked)
- [x] 2.2 Add `windowCount(pid:)` AX helper (count of `kAXWindowsAttribute`) to detect whether the reopen produced a window
- [x] 2.3 Point `bringExistingHere`'s `.noWindows` branch at `reopenWindowlessApp` and update its comment
- [x] 2.4 Keep the escalation non-destructive — never auto-quit; truly-stubborn apps remain the job of the explicit `quit-and-reopen-here` strategy
- [x] 2.5 Verify it compiles: `swift build`
- [ ] 2.6 On-device (user-run stable-signed build): with Shortcuts (and other Catalyst apps) running windowless in the background and the item set to "Go to its window", fire it and confirm a window now appears; confirm apps that already worked (Xcode) don't get a spurious second window

## 3. Bug #3 — Next/Previous Space action does nothing

- [x] 3.1 Diagnose: physical ⌃←/→ works and screenshot keystrokes work, but the arrow-based Space action doesn't → synthetic arrow events lack the numeric-pad flag the default Space hotkey mask requires
- [x] 3.2 In `LaunchService.perform`, synthesize a faithful arrow press for `.nextSpace` (⌃→) / `.previousSpace` (⌃←): `spaceSwitchFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]`. (First tried `.maskNumericPad` only; on-device that still did nothing, so the Fn flag was added — see design D4.)
- [x] 3.3 Confirm non-arrow keystroke actions (screenshots, lock screen) are untouched
- [x] 3.4 Verify it compiles: `swift build`
- [x] 3.5 On-device (user-confirmed): Next/Previous Space switches the Space in each direction
- [x] 3.6 Not needed — 3.5 passed with the faithful arrow flags

## 4. Bug #4 — front window not actually focused after a Space switch

- [x] 4.1 Add an injected `onSpaceSwitch` hook to `LaunchService`, called right after the ⌃→ / ⌃← is synthesized (no-op by default / in tests)
- [x] 4.2 Wire it in `AppCoordinator` to `focusFrontWindowAfterSpaceSwitch()`
- [x] 4.3 Poll for the active Space to change (`SpaceService.currentModel().currentSpaceIDs`), bailing after ~1.6s so a no-neighbour ⌃→ doesn't steal focus
- [x] 4.4 On settle, raise the destination's front window via the switcher's robust `windowService.raise` (establishes real key focus)
- [x] 4.4a Fix wrong-app focus: the first cut picked the per-Space z-order head (`windowsInSpace`, options 7) which includes invisible/agent windows → focused the wrong app. Switch to `NSWorkspace.frontmostApplication`'s front window (the OS's authoritative front), retrying until frontmost reflects the new Space
- [x] 4.5 Verify it compiles + tests pass: `swift build`, `swift test`
- [x] 4.4b Both 4.4/4.4a regressed on-device ("back to step one") — root cause: cleanup fired on the Space-flip *instant* (transition start), so the rest of the WindowServer transition steamrolled the raise and frontmost/CGS were stale. Fix: after detecting the flip, wait ~0.45s for the transition to FINISH, then raise the frontmost app's front window (fallback `app.activate()`). Added `TFS-SPACE` NSLog diagnostics
- [x] 4.4c Settle-delay still failed on-device. Switched diagnostics from NSLog to the existing file dump: `FocusLog.shared.note(...)` lines (prefixed `SPACE:`) now appear in the `=== trace ===` section of "Write Diagnostics → /tmp"
- [x] 4.4d Stage Manager → `frontmostApplication` is `WindowManager` right after a switch. Tried z-order selection next: correct on single-window Spaces but picked the WRONG window on multi-window Spaces (chose 'Code' when another app was intended)
- [x] 4.4e Tried polling `frontmostApplication` until a **regular** app. Diagnostics: works for a single-window Space (settles attempt 0), but for a MULTI-window Space `frontmostApplication` stays `WindowManager` (policy=accessory) for all 25 attempts and NEVER yields — it won't become a real app until that app's window is key (circular). Dead end.
- [x] 4.4f Final approach: focus `windowService.snapshot().first(where: isOnCurrentSpace)` — the app's own **MRU-top** window on the new Space (independent of the WindowManager limbo; matches what the OS keeps visually front), raised after a 0.45s settle so it lands after the Stage-Manager front-steal
- [x] 4.6 On-device (user-confirmed): the destination's front window is focused/typeable (correct app) on both single- and multi-window Spaces under Stage Manager
- [x] 4.7 Removed the temporary `SPACE:` trace notes and the `FocusLog.note()` buffer (reverted `FocusLog` to its prior shape)

## 5. Bug #5 — launcher lingers on the destination Space after a Space-switch action

- [x] 5.1 Diagnose: the panel is `.canJoinAllSpaces`, and `end()` fired the action before its `defer { hide() }`, so the ⌃→ carried the still-visible panel onto the new Space
- [x] 5.2 In `LauncherOverlayController.end()`, order the panel out (`hide()`) BEFORE calling `onFire`
- [x] 5.2a On-device, pre-fire hide alone did NOT stop the lingering (the Space-switch transition re-materialises the all-Spaces panel). Decisive fix: re-`hide()` the launcher from the D5 settle poll once the Space change is detected (post-transition orderOut sticks)
- [x] 5.3 Verify it compiles: `swift build`
- [x] 5.2b Re-hide on the flip instant also failed (transition re-materialised the panel after).
- [x] 5.2c Diagnostics showed `launcherVisible=false` at every stage yet the panel still appeared → an orderOut'd `.canJoinAllSpaces` panel leaves a rendered GHOST on the destination Space. `hide()` now DESTROYS the panel (`orderOut` + `close()` + `panel = nil`, `isReleasedWhenClosed = false`); `show()` recreates it fresh on the current Space
- [x] 5.2d Destroy-on-hide alone still ghosted (close() isn't flushed before the ⌃→ is processed, so the all-Spaces panel is baked into the transition). Final fix: drop `.canJoinAllSpaces` entirely — the recreated-per-show panel is now bound to only the current Space, so it cannot appear on the destination Space
- [x] 5.4 On-device (user-confirmed): the launcher no longer appears on the destination Space; it still dismisses normally and re-opens on the next gesture
