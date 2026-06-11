## 1. Core data model & persistence

- [x] 1.1 Define `InputSourceID` (a `String` typealias or thin `Codable` wrapper) and a `KeyboardLanguageRecord` Codable struct with `schemaVersion` and `map: [String: String]` (bundleID → input-source id) in `ThreeFingerSwitcherCore`.
- [x] 1.2 Implement `KeyboardLanguageStore` (`@MainActor`, `ObservableObject`) following the `FavoritesStore` pattern: injectable `UserDefaults`, JSON blob under a single key, `mutate`/`save`, forward-only `schemaVersion` stamping, empty-map default on first run.
- [x] 1.3 Add store accessors: `source(forBundleID:) -> String?`, `setSource(_:forBundleID:)`, and a read-only snapshot of the map.

## 2. Core decision logic (pure)

- [x] 2.1 Implement `KeyboardLanguagePolicy.activate(bundleID:map:globalDefault:) -> String?` — return remembered source, else global default, else nil (unseen + no default).
- [x] 2.2 Implement `KeyboardLanguagePolicy.learn(bundleID:source:into:) -> [String:String]` — return the map with `bundleID` set to `source` (the only write path).
- [x] 2.3 Keep both functions free of Carbon/AppKit so they compile and run under `swift build`/`swift test`.

## 3. Core seam for Carbon side effects

- [x] 3.1 Define an `InputSourceController` protocol in Core: `current() -> String?`, `select(_ id: String) -> Bool`, `enabledSources() -> [(id: String, localizedName: String)]`, plus a change-callback registration (`onUserChange: (() -> Void)?` or an async stream).
- [x] 3.2 Provide a `FakeInputSourceController` for tests that records `select` calls, exposes a settable `current`, and can fire the change callback on demand.

## 4. Core unit tests

- [x] 4.1 Test `KeyboardLanguagePolicy.activate`: remembered wins over default; unseen→default; unseen + no default→nil.
- [x] 4.2 Test `KeyboardLanguagePolicy.learn`: last-write-wins; independent per bundle id.
- [x] 4.3 Test `KeyboardLanguageStore` persistence/migration against an isolated `UserDefaults` suite (write→reload→same map; schemaVersion stamped forward only).
- [x] 4.4 Test the apply/learn coordination logic against `FakeInputSourceController`: activation selects the right id; redundant select is skipped; a user-change callback learns; a select-triggered callback does NOT learn (feedback guard); app with nil bundle id is ignored.

## 5. AppSettings additions

- [x] 5.1 Add `@Published var keyboardLanguageEnabled: Bool` and `@Published var keyboardLanguageDefaultSourceID: String` to `AppSettings`, each persisting to its own UserDefaults key (scalar-per-key style); defaults: disabled, empty default-source.

## 6. App-shell service (Carbon TIS)

- [x] 6.1 Implement `CarbonInputSourceController` (app target) conforming to `InputSourceController`: `current()` via `TISCopyCurrentKeyboardInputSource` + `kTISPropertyInputSourceID`; `select()` via `TISSelectInputSource` (returns success); `enabledSources()` via `TISCreateInputSourceList` filtered to selectable keyboard/IM sources with `kTISPropertyLocalizedName`.
- [x] 6.2 Register the `kTISNotifySelectedKeyboardInputSourceChanged` distributed notification and forward it as the controller's user-change signal.
- [x] 6.3 Implement `KeyboardLanguageService` (`@MainActor`): owns the store, settings, and an `InputSourceController`; observes `NSWorkspace.didActivateApplicationNotification`; on activation runs `Policy.activate` and `select` (skipping a redundant select); on user-change runs `Policy.learn` for the current frontmost app's bundle id; implements the `applying` feedback guard around programmatic selects; ignores apps with no bundle id; treats `select` failure as a logged no-op (no modal).
- [x] 6.4 Add `start()`/`stop()` that register/unregister both observers, so the service is fully inert when stopped.

## 7. Coordinator wiring

- [x] 7.1 Instantiate `KeyboardLanguageStore` and `KeyboardLanguageService` in `AppCoordinator`, injecting `CarbonInputSourceController`, the store, and `settings`.
- [x] 7.2 Start the service when `keyboardLanguageEnabled` is true and stop it when false; subscribe to the setting so toggling it live starts/stops the service.

## 8. Hub configuration UI

- [x] 8.1 Add `case keyboardLanguage` to `HubDestination` with `title` ("Keyboard Language"), `sidebarTitle` ("Language"), and a `systemImage` (e.g. `keyboard` / `globe`).
- [x] 8.2 Create the Keyboard Language Hub page (`HubFeaturePages.swift` or a new file) with exactly two controls: an enable `Toggle` bound to `settings.keyboardLanguageEnabled`, and a `Picker` for the global default bound to `settings.keyboardLanguageDefaultSourceID`, populated from `enabledSources()` by localized name (include a "None" option mapping to empty).
- [x] 8.3 Surface the feature as an opt-in row in `HubOverviewPage` consistent with Clipboard/AI.
- [x] 8.4 Wire any needed providers/callbacks through `HubContext` (e.g. an `enabledSourcesProvider` so the picker can list sources without the page importing Carbon directly).

## 9. Build & verify

- [x] 9.1 `swift build` and `swift test` pass (Core store/policy/seam + tests are MLX-free). — VALIDATOR: `swift build --target ThreeFingerSwitcherCore` clean; full `swift test` 535/535 pass.
- [x] 9.2 `xcodebuild` compile-verifies the app target (Carbon-linked shell + Hub page) — compile only, no install/sign. — VALIDATOR: `** BUILD SUCCEEDED **`; all 6 `KeyboardLanguage/*` + `CarbonInputSourceController` compiled into the MLX-linked app target (Debug, `CODE_SIGNING_ALLOWED=NO`).
- [x] 9.3 Confirm no AppKit/Carbon import leaked into the Core pure logic (policy/store/seam remain `swift build`-clean). — VALIDATOR: policy/model/store/protocol import only Foundation/Combine; Carbon confined to `CarbonInputSourceController`.

## 10. Spec sync & docs

- [x] 10.1 After implementation, run `/opsx:verify` then sync the delta into `openspec/specs/per-app-keyboard-language/`. — synced via `openspec archive`.
- [x] 10.2 Note the new feature (and its per-app, auto-learn, Hub-configured nature) in `README.md` where the other opt-in features are described. — added to the B1 repo map.
