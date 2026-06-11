## Why

Windows/PC lets you set a keyboard input language per window; macOS has no equivalent — the input source is global, so a user who works in Hebrew in WhatsApp and English in their editor must re-toggle the language by hand on every app switch. ThreeFingerSwitcher already observes app activations and persists per-app state, so it is the natural place to remember each app's language and restore it automatically.

## What Changes

- Add an opt-in **per-app keyboard language** feature: ThreeFingerSwitcher remembers the keyboard input source last used while each application was frontmost, and re-selects it automatically the next time that application becomes frontmost.
- **Auto-learn only**: the remembered source for an app is updated implicitly whenever the user changes the input source while that app is front. There is no per-app override list to maintain.
- **Global default**: a user-chosen input source is applied to any application the app has no memory for (apps first seen after launch, or never recorded). Configurable; defaults to off-impact until set.
- **Durable per-app memory**, keyed by bundle identifier, that survives both the *target* app quitting and ThreeFingerSwitcher relaunching (UserDefaults JSON, same pattern as Favorites/Clipboard).
- **Hub configuration**: a new "Keyboard Language" page in the configuration Hub with exactly two controls — an enable toggle and the global-default source picker — plus an Overview feature row (opt-in, like Clipboard/AI).
- Feature is **off by default**; when disabled, the app never reads or writes the input source.

## Capabilities

### New Capabilities
- `per-app-keyboard-language`: Remember and auto-restore the keyboard input source per application (bundle id), auto-learned from user changes, with a user-chosen global default for unseen apps and a Hub enable/default-source configuration surface.

### Modified Capabilities
<!-- None. The feature is additive: it introduces a new capability and a new Hub page without changing the requirements of existing capabilities. -->

## Impact

- **New code (Core, MLX-free, unit-tested):** `KeyboardLanguageStore` (bundle id → input-source id, JSON in UserDefaults) and a pure `KeyboardLanguagePolicy` (activate/learn decisions). An `InputSourceController` protocol seam so the Carbon side effects are faked in tests.
- **New code (app shell, `xcodebuild`-verified):** `KeyboardLanguageService` — the only Carbon **Text Input Source (TIS)** code; owns the `NSWorkspace.didActivateApplication` and `kTISNotifySelectedKeyboardInputSourceChanged` observers and wraps `TISSelectInputSource` / `TISCopyCurrentKeyboardInputSource` behind `InputSourceController`.
- **AppSettings:** two new persisted scalars — `keyboardLanguageEnabled`, `keyboardLanguageDefaultSourceID`.
- **Hub:** new `HubDestination.keyboardLanguage` page + wiring through `HubContext`; one Overview feature row.
- **AppCoordinator:** instantiate the service, start/stop it with the enable toggle, inject the store + settings.
- **Frameworks:** links Carbon (`Carbon.HIToolbox` / TIS) in the app shell. No new third-party dependencies.
- **No behavior change** for existing features; nothing runs until the user enables the toggle.
