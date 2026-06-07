## Why

The launcher's value-changing system actions (Volume Up/Down, Brightness Up/Down) only nudge by the OS's fixed step. Users want to bind a precise level — "set volume to 30%" — or a custom delta — "change brightness by 40%" — from a single launcher item, instead of firing the step action repeatedly.

## What Changes

- Each value action item gains an optional **value control**, editable in its inspector:
  - **Step** (default, unchanged): synthesize the native media/brightness key — today's behavior.
  - **Set to N%** (absolute): set the level directly to N%.
  - **Change by N%** (relative): add/subtract N percentage points; Up adds, Down subtracts.
- Implement absolute/relative volume via **CoreAudio** (virtual main volume) and brightness via the private **DisplayServices** get/set, both resolved crash-safely and **without any new permission** (consistent with the existing native-action rule). Where a level can't be read/set (e.g. some external displays), fall back to key-stepping.
- Scope: the four value actions — `volumeUp`, `volumeDown`, `brightnessUp`, `brightnessDown`. Toggles (mute, play/pause) and discrete actions are unaffected.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `launch-actions`: the "Built-in system actions" requirement gains an optional per-item value control (absolute set / relative change) for the volume and brightness actions, performed natively without a new permission; absent the control, the actions keep their current native-step behavior.

## Impact

- **Model:** `LaunchItemKind.action(SystemAction)` → `.action(SystemAction, ValueAdjustment?)` (new `ValueAdjustment` value type). Backward-compatible decoding is required (old favorites omit the second value) and covered by a test, so existing favorites don't reset.
- **Code:** `LaunchService.perform` (compute + apply target; CoreAudio volume; private DisplayServices brightness), `FavoritesEditorView` (inspector control + ActionBrowser construction), `LaunchItem.swift` (`ValueAdjustment`, `SystemAction.isValueAdjustable`). Pure target math is factored out and unit-tested.
- **Permissions:** none added (CoreAudio + private DisplayServices via dlsym; no Automation/Apple-Events).
- **Risk:** absolute brightness on external/DDC displays may be unsupported → documented fallback to stepping.
