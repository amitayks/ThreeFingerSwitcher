## 1. Model (`LaunchItem.swift`)

- [x] 1.1 Add `AutomationKind` enum (`String, Codable, Equatable, CaseIterable, Identifiable`) with one case `keepAwake` + `title`/`symbol`/`detail` metadata
- [x] 1.2 Add `LaunchItemKind.automation(AutomationKind)` case (doc-comment: toggle, not one-shot; decode-safe precedent)
- [x] 1.3 Add `.automation` to `LaunchItem.isConsequential` (→ false, like `.action`)

## 2. Fire dispatch + seam (`LaunchService.swift`)

- [x] 2.1 Add an injected `onAutomation: (AutomationKind) -> Void` closure (default no-op), mirroring `onAICommand`
- [x] 2.2 Add the `.automation(kind)` branch in `fire(_:inBand:)` → `onAutomation(kind)`

## 3. Display brightness — all displays (`Windows/DisplayBrightness.swift`)

- [x] 3.1 Add `activeDisplays() -> [CGDirectDisplayID]` (via `CGGetActiveDisplayList`) so Keep Awake can dim/restore every display

## 4. KeepAwakeController (new, MLX-free Core)

- [x] 4.1 `KeepAwakeController` (`@MainActor`) with an injectable `Effects` seam (active displays, brightness get/set, begin/end activity, declare-user-active) defaulting to real impls (`DisplayBrightness`, `ProcessInfo.beginActivity`, `IOPMAssertionDeclareUserActivity`)
- [x] 4.2 State: idle / awaiting-empty / armed; `isActive`; owns brightness snapshot, activity token, heartbeat `Timer`
- [x] 4.3 `toggle()`, `start()` (snapshot+dim all, begin activity, start ~300s heartbeat, awaiting-empty), `stop()` (invalidate timer, end activity once, restore snapshot, idempotent)
- [x] 4.4 `noteTouch(fingerCount:)` arming: awaiting-empty + count==0 → armed; armed + count>0 → stop() — non-consuming, self-cancel-immune
- [x] 4.5 Heartbeat tick: re-pin all displays to min + declare user active
- [x] 4.6 `onActiveChanged` callback (for the menu-bar rebuild)

## 5. Wiring (`AppCoordinator.swift`, `AppDelegate.swift`)

- [x] 5.1 Own `private lazy var keepAwakeController` (real effects)
- [x] 5.2 `LaunchService(onAutomation:)` → route `.keepAwake` to `keepAwakeController.toggle()`
- [x] 5.3 Feed the touch stream: in `touchEngine.onFrame`, call `keepAwakeController.noteTouch(fingerCount:)` (non-consuming; recognizer path untouched)
- [x] 5.4 Force-stop in `handleWillSleep()` (before the `isEnabled` guard) and expose `keepAwakeActive` + `stopKeepAwake()`; wire `onActiveChanged` → `onStateChange`
- [x] 5.5 `AppDelegate.applicationShouldTerminate` force-stops so brightness restores before exit

## 6. Editor surface (`Hub/BandsCanvas.swift`)

- [x] 6.1 `SourceCategory.automations = "Automations"` + `symbol` + `hint` ("Browse")
- [x] 6.2 `categoryBrowser` → `.automations: AutomationBrowser { add($0) }`; drop `.automations` from the never-reached immediate-add `EmptyView` group
- [x] 6.3 New `AutomationBrowser` view (mirrors `ActionBrowser`) enumerating `AutomationKind.allCases`, adds `.automation(kind)`
- [x] 6.4 Add `.automation` to `naturalIcon(for:)` (nil group) and `kindLabel(_:)` ("Automation")

## 7. Menu-bar backup (`App/StatusItemController.swift`)

- [x] 7.1 Conditional group: when `coordinator.keepAwakeActive`, add a "Keep Awake — Active ✓" item that stops it

## 8. Tests (`Tests/ThreeFingerSwitcherTests/`)

- [x] 8.1 `KeepAwakeControllerTests` with recording fake `Effects`: start dims all + begins activity; residual contacts before empty do NOT stop (self-cancel immunity); arm-then-touch stops + restores exact snapshot + ends activity once; idempotent double-stop; heartbeat re-pins
- [x] 8.2 `AutomationItemCodableTests`: `.automation(.keepAwake)` item + `AutomationKind` round-trip; legacy favorites (no automation) decode (no schema bump)

## 9. Verify

- [x] 9.1 Core logic executed & green via an **isolated SwiftPM package** (the real `KeepAwakeController` + `DisplayBrightness` + `AutomationKind`, `.swiftLanguageMode(.v5)`): 13 tests pass. NOTE: the repo's committed `main` HEAD does **not** build standalone — it references ~dozens of types/members (`MediaRuntime`, `NotchSessionEngine`, `VideoProvider`, `FullPotentialCapability`, …) that live only in the user's **uncommitted** working tree (453 pre-existing errors), so full-target `swift test` can't run on this base. 6 of 7 edited files are byte-identical to HEAD; the AppCoordinator edit anchors were verified present in the WIP version too.
- [ ] 9.2 `xcodebuild` compile-verify the app/GemmaRuntime target — blocked by the same non-building base; re-run once the user's WIP is committed
- [ ] 9.3 On-device (user-run, stable-signed): add Keep Awake to a band, fire it → all displays dim + Mac won't sleep/lock; walk away, return, first touch restores brightness; quit while active restores brightness; menu-bar shows Active + Stop
