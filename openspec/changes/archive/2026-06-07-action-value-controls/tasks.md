## 1. Model

- [x] 1.1 Add `ValueAdjustment` (`mode: .absolute/.relative`, `percent: Double`) — `Codable, Equatable` — to `LaunchItem.swift`
- [x] 1.2 Change `LaunchItemKind.action(SystemAction)` → `.action(SystemAction, ValueAdjustment?)`
- [x] 1.3 Add `SystemAction.isValueAdjustable` (true for `volumeUp/Down`, `brightnessUp/Down`) and an `isIncrease`/up helper
- [x] 1.4 Update the 3 `.action(` sites: `LaunchService.fire`, `FavoritesEditorView` ActionBrowser construction, `LaunchItemTests`

## 2. Pure target math (tested)

- [x] 2.1 Add `static func targetLevel(current:up:mode:amount:) -> Double` (clamped 0…1) to `LaunchService`
- [x] 2.2 Unit-test it: absolute clamps & ignores direction; relative adds/subtracts by direction & clamps at 0/1

## 3. Native level control (no new permission)

- [x] 3.1 Volume via CoreAudio: get/set `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (0…1) on the default output device
- [x] 3.2 Brightness via private `DisplayServices` `Get/SetBrightness(CGDirectDisplayID, Float)` — dlsym crash-safe (mirror `CGSPrivate`); target `CGMainDisplayID()`
- [x] 3.3 `perform(_:adjustment:)`: when adjustment is set, read current → `targetLevel` → set; else keep `postMediaKey` stepping
- [x] 3.4 Fallback: if read/set unavailable or fails, step the media key ≈ `round(percent/6.25)` times (relative) / no-op absolute; never crash

## 4. Editor

- [x] 4.1 In the item inspector, for `.action` items where `isValueAdjustable`, add a Mode picker (Step / Set to % / Change by %) + a 0–100 stepper for the non-step modes
- [x] 4.2 Persist via `store.updateItem { $0.kind = .action(action, newAdjustment) }`; help text noting absolute ignores up/down

## 5. Backward-compatible decode

- [x] 5.1 Test: decode legacy `.action` JSON (`{"action":{"_0":"volumeUp"}}`) → succeeds with `nil` adjustment (favorites not reset)
- [x] 5.2 Not needed — 5.1 passed: synthesized `Codable` `decodeIfPresent`s the optional `_1`, and `encodeIfPresent` omits it when nil (new encoding == legacy shape). No custom Codable required.

## 6. Verify

- [x] 6.1 `swift build` + `swift test` green
- [ ] 6.2 On-device (user-run stable-signed build): set volume to 30% (absolute) and +40% (relative); same for brightness; confirm a Step item is unchanged; confirm older favorites still load
