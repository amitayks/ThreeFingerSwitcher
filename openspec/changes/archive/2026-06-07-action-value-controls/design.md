## Context

`SystemAction` is a `String`-rawValue enum; an action item is `LaunchItemKind.action(SystemAction)` with no per-item parameters. The value actions (`volumeUp/Down`, `brightnessUp/Down`) currently call `postMediaKey(...)` in `LaunchService.perform`, which steps by the OS's fixed increment. Favorites persist as one JSON blob; `FavoritesStore.load` uses `try? decode`, so any decode failure silently **resets favorites to seeded defaults** — backward-compatible decoding is mandatory.

## Goals / Non-Goals

**Goals:**
- Optional per-item absolute ("set to N%") and relative ("change by N%") control for the four value actions, editable in the inspector.
- Native, no-new-permission implementation; `nil` control preserves today's exact step behavior.
- Pure, unit-tested target math; backward-compatible model change.

**Non-Goals:**
- No value control for toggles/discrete actions (mute, play/pause, next/prev).
- No per-display brightness UI; absolute brightness targets the main display, best-effort elsewhere.
- No new permissions; no AppleScript/Automation.

## Decisions

**D1 — Carry the control in the action case: `action(SystemAction, ValueAdjustment?)`.** Mirrors how `.app(bundleURL, strategy)` carries per-item config in its kind (rather than polluting `LaunchItem`). `nil` = native step.
```swift
struct ValueAdjustment: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case absolute, relative }
    var mode: Mode
    var percent: Double      // 0...100; absolute: target level, relative: magnitude (sign from up/down)
}
```
*Alternative — store on `LaunchItem`:* trivially migration-safe (optional struct property), but breaks the per-kind-config convention and leaks an action-only field onto every item. Rejected in favor of a decode-compat **test** guarding D1.

**D2 — Backward-compatible decode.** Old data encodes `.action` as `{"action":{"_0":"volumeUp"}}`; the new optional `_1` must decode as `nil` when absent. A unit test decodes the legacy shape and asserts `nil` adjustment; if the synthesized enum `Codable` doesn't `decodeIfPresent` the optional, add a minimal custom `init(from:)` for `LaunchItemKind`.

**D3 — Native, permission-free level control.**
- *Volume:* CoreAudio — read/write `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (Float 0…1) on the default output device. Mute is left as the existing toggle.
- *Brightness:* private `DisplayServices` `DisplayServicesGetBrightness`/`SetBrightness(CGDirectDisplayID, Float)` resolved via `dlsym` (crash-safe, same pattern as `CGSPrivate`/`MissionControl`); target `CGMainDisplayID()`. Returns 0 on success.
- *Fallback:* if a level can't be read/set (symbol missing, or set fails — e.g. some external displays), fall back to `postMediaKey` stepping ≈ `round(percent / 6.25)` presses for relative; absolute with no readable level is a no-op (logged path), never a crash.

**D4 — Pure target math (tested).**
```swift
// current, percent in 0...1; returns clamped 0...1
static func targetLevel(current: Double, up: Bool, mode: ValueAdjustment.Mode, amount: Double) -> Double
//   .absolute → clamp(amount)
//   .relative → clamp(current + (up ? +amount : -amount))
```

**D5 — Inspector UI.** In the item inspector, when `case .action(let a, let adj)` and `a.isValueAdjustable`, show a Mode picker (Step / Set to % / Change by %) and, for the non-step modes, a 0–100 stepper/slider. Writes via `store.updateItem { $0.kind = .action(a, newAdj) }`. `SystemAction.isValueAdjustable` returns true for the four value actions. For `.absolute`, up/down is irrelevant (documented in help text).

## Risks / Trade-offs

- [Absolute brightness unsupported on some external/DDC displays] → best-effort on `CGMainDisplayID()`, documented; relative falls back to key-stepping; never crashes.
- [Private `DisplayServices` symbol could change/disappear] → dlsym into an optional fn-ptr; missing ⇒ fall back to stepping (degrade, never crash), exactly like the other private-API bridges.
- [Legacy-decode regression would wipe favorites] → guarded by an explicit decode-compat unit test (D2) before shipping.
