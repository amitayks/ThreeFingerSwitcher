## 1. Private API layer (crash-safe)

- [x] 1.1 New `CGSPrivate.swift`: `dlsym(RTLD_DEFAULT, …)` optional function pointers for `CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSManagedDisplayGetCurrentSpace`, `CGSCopyWindowsWithOptionsAndTags`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`; `import Carbon` for `GetProcessForPID`/`ProcessSerialNumber`. Typedefs `CGSConnectionID=UInt32`, `CGSSpaceID=UInt64`. Expose a `cgs` accessor + `offSpaceSupported: Bool` (false if any symbol is nil).
- [x] 1.2 In `AXPrivate.swift`: add `dlsym`-resolved `_AXUIElementCreateWithRemoteToken` and `bruteForceWindows(pid:budgetMs:)` — 20-byte token (`pid + Int32(0) + Int32(0x636f636f) + Int64(id)`), iterate `0..<1000` within 100 ms, keep `kAXStandardWindowSubrole`/`kAXDialogSubrole`, map via `axWindowID`.
- [x] 1.3 Startup preflight: evaluate `cgs.offSpaceSupported` once (in `AppCoordinator.start()`/`enable()`) and log when off-Space support is disabled.

## 2. Space model

- [x] 2.1 New `Spaces.swift`: ordered `spaceID→index` map + `currentSpaceIDs: Set` from `CGSCopyManagedDisplaySpaces` (read per-display `"Spaces"` `id64`, `"Current Space"`; confirm via `CGSManagedDisplayGetCurrentSpace`).
- [x] 2.2 `buildWindowToSpacesMap()`: per `spaceID` call `CGSCopyWindowsWithOptionsAndTags(cid, 0, [spaceID], 2, …)`, invert into `[CGWindowID:[CGSSpaceID]]`. Computed once per snapshot.

## 3. Window model + enumeration

- [x] 3.1 `WindowInfo.swift`: make `axElement` `AXUIElement?`; add `isOnCurrentSpace: Bool`, `spaceID: CGSSpaceID?`.
- [x] 3.2 `WindowService`: keep the current enumeration body verbatim as `legacySnapshot()`.
- [x] 3.3 Rewrite `snapshot()`: guard `AXIsProcessTrusted()`; `if !cgs.offSpaceSupported { return legacySnapshot() }`. Else build Space model + window→Spaces map; per-candidate `isOnCurrentSpace`; current-Space element via per-pid `kAXWindowsAttribute` cache + `isSwitchable()`; off-Space element via `bruteForceWindows(pid)` cached per pid per snapshot.
- [x] 3.4 Title resolution: AX `kAXTitle` → `kCGWindowName` (current-Space) → app name. Filtering: `isSwitchable()` when an element is acquired, else CG `layer==0 && alpha>0 && bounds≥1×1 && regular pid`. Cross-check owner pid via the AX element where available (FB18327911).
- [x] 3.5 Ordering: `mru.rank(pid)` asc → current-Space-first → CG z-order → `spaceID` index tiebreak. Fix the false header comment.

## 4. Raise

- [x] 4.1 Rewrite `raise(_:)`: re-resolve element at commit (cheap `kAXRoleAttribute` probe, guard `kAXErrorInvalidUIElement`; if invalid → current-Space re-walk `kAXWindowsAttribute`, off-Space re-acquire via brute force).
- [x] 4.2 Current-Space + valid element → existing public path (`kAXRaiseAction` + `kAXMain` + app `kAXFocusedWindow` + `activate()`), no Space switch.
- [x] 4.3 Off-Space → guarded `GetProcessForPID(&psn)` (reject zero PSN) + `_SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)` + `makeKeyWindow(psn,wid)` + **mandatory** `AXUIElementPerformAction(kAXRaiseAction)`. Degrade to `activate()` + `kAXRaiseAction` if PSN/SLPS unavailable.
- [x] 4.4 `makeKeyWindow(psn:wid:)` helper: two `SLPSPostEventRecordTo` records — `bytes[0x04]=0xf8`, `bytes[0x3a]=0x10`, wid at `0x3c`, `0xff` fill (16 bytes) at `0x20`, `bytes[0x08]=0x01` then `0x02`.

## 5. Thumbnails / wiring

- [x] 5.1 `ThumbnailService`: no functional change; add a comment that off-Space windows are expected and blank-on-first-composite is acceptable.
- [x] 5.2 `AppCoordinator`: ensure it compiles against optional `axElement`; no logic change.

## 6. Build & on-device test matrix

- [x] 6.1 `swift build` (macOS 15 target) clean; assemble bundle.
- [x] 6.2 (a) Window on another desktop Space appears, raises with ONE switch, and keyboard focus actually lands.
- [x] 6.3 (b) Native-fullscreen app appears + raises; (c) window/fullscreen-Space opened BEFORE app launch appears + raises.
- [x] 6.4 (d) Settings/agent windows get real key focus (not just z-order); (e) current-Space behavior unchanged.
- [ ] 6.5 (f) Screen Recording denied → off-Space windows listed icon + app-name only; (g) window closed mid-gesture → raise no-ops.
- [ ] 6.6 (h) Simulate a missing dlsym symbol → app launches, off-Space disabled, legacy current-Space path works.
