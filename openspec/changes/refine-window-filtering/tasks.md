# Tasks — refine-window-filtering

## 1. The pure filter (Core)

- [x] 1.1 `Windows/WindowFilter.swift`: `WindowCandidate` (role, subrole, title, size, hasCloseButton, isMinimized), `WindowAppRule` (`include`/`strict`/`exclude`, Codable), `WindowFilterPolicy` (relaxed, includeMinimized, appRule?), `WindowFilterVerdict` (`listed` / `dropped(reason)`), `WindowDropReason`.
- [x] 1.2 `WindowFilter.verdict(_:policy:)`: exclude → minimized gate → window-role gate → include-rule shortcut (degenerate floor only) → strict path (byte-identical to the old gate) → relaxed three-tier (known-real allowlist / known-junk denylist / discriminators: title ∨ chrome ∨ ≥100pt; degenerate floor 40pt).
- [x] 1.3 `WindowFilter.dedupe`: collapse (pid, trimmed title, integral frame, isMinimized) groups keeping min-rank (z or id); exempt pids set (include-rule apps).

## 2. Service integration

- [x] 2.1 `WindowService`: `bundleKey(for pid:)` cache (bundleIdentifier ?? executable name); `policy(for pid:)`; `candidate(for element:)` (one title/chrome/subrole read per window).
- [x] 2.2 `isSwitchable` routes through `WindowFilter.verdict` (pid via `AXUIElementGetPid`); `isPreviewable` same with minimized forced included.
- [x] 2.3 Dedup in `snapshot()` (rows before ordering, z-ranked), `legacySnapshot()`, and `currentSpaceWindows(forApp:)` (id-ranked).
- [x] 2.4 `bruteForceWindows` acquisition pre-filter widens to any-window-role for `include`-rule pids (call sites pass the flag per pid).
- [x] 2.5 `inspectorSnapshot()` → `[WindowInspectorEntry]`: all regular apps' current-Space elements, verdict + dedup marking via the same filter.

## 3. Settings

- [x] 3.1 `AppSettings.windowAppRules: [String: WindowAppRule]` — `persistCodable`/`loadCodable`, `Defaults` (empty), `Keys`, init read, `resetToDefaults` line.

## 4. Hub inspector

- [x] 4.1 `HubContext.inspectWindows: () -> [WindowInspectorEntry]`; wire in `AppCoordinator.makeHubContext`.
- [x] 4.2 `SwitcherPage`: "Window inspector" `HubSection` — grouped by app, verdict badges, per-app rule picker bound to `settings.windowAppRules`, Refresh button + on-appear load, no timers.

## 5. Tests + verify

- [x] 5.1 `WindowFilterTests`: strict parity (standard/missing listed, nonstandard dropped, minimized gate); relaxed monotonicity (small standard window listed); discriminators (titled/chromed small unknown listed; untitled chromeless 61pt dropped; 372pt unknown listed); junk subroles dropped; degenerate floor; per-app include/strict/exclude; dedupe (clones collapse to frontmost, distinct titles/frames kept, exempt pids kept, cross-pid kept).
- [x] 5.2 `AppSettingsTests`: `windowAppRules` default empty, round-trip persistence, reset clears.
- [x] 5.3 `swift build` + `swift test` green.
- [x] 5.4 `openspec validate refine-window-filtering --strict`.
- [ ] 5.5 In-app (signed build — user's Terminal): Finder copy-progress window appears; AirDrop send popup shows one card per real window; inspector lists verdicts and a rule change takes effect. _(Needs the user.)_
- [ ] 5.6 Sync deltas into the three specs and archive. _(After 5.5.)_
