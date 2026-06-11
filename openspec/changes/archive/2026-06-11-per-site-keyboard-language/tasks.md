## 1. Browser registry & context resolution (Core, pure)

- [x] 1.1 Add `BrowserRegistry` in `Sources/ThreeFingerSwitcher/KeyboardLanguage/`: a pure table mapping bundle id → `{ supported: Bool, scriptFamily: .safari/.chromium }` for `com.apple.Safari`, `com.google.Chrome`, `com.brave.Browser`, `com.microsoft.edgemac`, `company.thebrowser.Browser` (Arc), `com.vivaldi.Vivaldi`. `isSupported(_:) -> Bool` and `family(for:)`.
- [x] 1.2 Add a pure `ContextKey` helper: `make(bundleID:host:) -> String` returning `bundleID` when host is nil/empty and `"\(bundleID)|\(host)"` otherwise. Single source of truth for the key shape (used by resolver, learn, apply).
- [x] 1.3 Add a pure `HostNormalizer`: lowercase, strip a leading `www.`, drop trailing dot; given a registrable-domain-only string (Safari AX) leave it as-is. Unit-testable, no I/O.

## 2. Host provider seam (Core)

- [x] 2.1 Define `HostProvider` protocol: `func host(forBrowser bundleID: String) -> String?` (nil = unknown/none/skip). Mirror the `InputSourceController` seam style.
- [x] 2.2 Implement `AXHostProvider` (default): read the frontmost browser window's address-bar AX element value and parse to a host via `HostNormalizer`. Guards: return nil when the address bar is focused/being edited, and when the window is private/incognito (best-effort AX subrole/title heuristic). Return nil (→ app-level context) when no clean host resolves.
- [x] 2.3 Implement `AppleEventsHostProvider` (opt-in): in-process Apple Events to get the active tab URL (Chrome family: `URL of active tab of front window`; Safari: `URL of current tab of front window`), parse host via `HostNormalizer`. On a not-permitted/any error, return nil so the caller falls back to AX. Skip private windows. — VALIDATOR fix: targets the *actual* bundle id (per-Chromium-fork), not a hardcoded Chrome.
- [x] 2.4 Provide a `FakeHostProvider` for tests (returns scripted hosts per bundle id; togglable nil).

## 3. Engine generalization (Core)

- [x] 3.1 Introduce a `ContextResolver` that, given the frontmost bundle id, returns the context id: bundle id for a normal app; `ContextKey.make(bundleID:host:)` using the active `HostProvider` when `BrowserRegistry.isSupported` and the per-site sub-toggle is on. Injectable provider + a `perSiteEnabled` flag.
- [x] 3.2 Generalize `KeyboardLanguageService`: `handleActivation(bundleID:)` → `handleContextChange(contextID:)` resolved via `ContextResolver` (`frontmostBundleID` → `currentContextID`; `lastActiveBundleID` → `lastActiveContextID`; added `reevaluate()`). Learn/apply logic unchanged.
- [x] 3.3 Ensure the existing per-app tests still pass with the generalized engine (non-browser path behavior-identical). — VALIDATOR: full `swift test` 549/549, per-app KL tests green.

## 4. Within-browser poll signal (Core)

- [x] 4.1 Add `BrowserContextMonitor` (Timer-based, `pollInterval` ~0.5s, `isPaused`, `start()/stop()`), mirroring `ClipboardMonitor`. Runs only while a supported browser is frontmost; each tick re-resolves and calls the service's context-change handler on change.
- [x] 4.2 Start/stop the monitor as the frontmost app enters/leaves a supported browser (cheap per-tick `isSupportedBrowserFront` guard) so it never polls when no browser is front.

## 5. Settings (Core)

- [x] 5.1 Add `@Published var keyboardLanguagePerSiteEnabled: Bool` (default false) and `@Published var keyboardLanguageAllowBrowserControl: Bool` (default false) to `AppSettings`, scalar-per-key, not reset in `resetToDefaults()`. Provider selection (AX vs Apple Events) keys off `allowBrowserControl`.

## 6. Coordinator wiring (Core)

- [x] 6.1 In `AppCoordinator`, build the `ContextResolver` with the chosen `HostProvider` (Apple Events when `allowBrowserControl`, else AX) and inject it into `KeyboardLanguageService` (via `currentContextID`); swap the provider in place when `allowBrowserControl` flips.
- [x] 6.2 Instantiate `BrowserContextMonitor`; gate it on `keyboardLanguagePerSiteEnabled && keyboardLanguageEnabled`; add `observeKeyboardLanguagePerSiteToggle()` (+ react to `allowBrowserControl`) alongside the existing observe*Toggle() sinks.
- [x] 6.3 When `allowBrowserControl` is on, the Automation permission is triggered lazily on first read, degrading to AX until granted.

## 7. Hub UI (Core)

- [x] 7.1 On `KeyboardLanguagePage`, add a "Per-site language in browsers" `Toggle` bound to `settings.keyboardLanguagePerSiteEnabled` (disabled unless the parent feature is on), footnote explaining host-level on Chrome/Chromium and domain-level on Safari.
- [x] 7.2 Add an "Allow browser control (exact per-site, incl. Safari)" `Toggle` bound to `settings.keyboardLanguageAllowBrowserControl`, copy noting it asks to control your browser via Automation.

## 8. Tests (Core, MLX-free)

- [x] 8.1 `BrowserRegistry`: supported set membership; Firefox/unknown → unsupported.
- [x] 8.2 `ContextKey` + `HostNormalizer`: key shape with/without host; lowercase, `www.` strip, trailing-dot, Safari registrable-domain passthrough.
- [x] 8.3 `ContextResolver` against a `FakeHostProvider`: browser + host → `bundle|host`; browser + nil host → bundle only; unsupported browser → bundle only; per-site-off → bundle only.
- [x] 8.4 Service per-site coordination (regression for the user scenario): Chrome `keep.google.com` learns Hebrew, navigating to `mail.google.com` applies/learns English, returning to `keep.google.com` restores Hebrew — driven via resolver + fake host provider + fake input controller.
- [x] 8.5 Safari degradation: AX provider returning the registrable domain collapses subdomains to one entry (defined behavior); Apple Events provider returning the exact host distinguishes them.
- [x] 8.6 Guards: typing-in-address-bar (provider returns nil) → app-level context, no per-site write; private window (provider nil) → skipped.

## 9. Build & verify

- [x] 9.1 `swift build --target ThreeFingerSwitcherCore` and `swift test` pass (MLX-free). — VALIDATOR: Core build clean; full `swift test` 549/549.
- [x] 9.2 `xcodebuild` compile-verifies the app target (Apple Events + AX readers link) — compile only, no install/sign. — VALIDATOR: `** BUILD SUCCEEDED **` after the Chromium-targeting fix; AX + Apple Events readers linked into the MLX app target.
- [x] 9.3 Confirm the non-browser per-app path is behavior-identical (existing per-app tests green). — VALIDATOR: per-app KL tests unchanged and green.

## 10. Spec sync & docs

- [x] 10.1 After implementation, run `/opsx:verify`, then sync the delta into `openspec/specs/per-site-keyboard-language/`. — synced via `openspec archive`.
- [x] 10.2 Note the per-site browser behavior (host-level; AX default vs Apple Events opt-in; Safari difference; privacy guards) in `README.md` alongside the per-app feature. — added to the B1 repo map.
