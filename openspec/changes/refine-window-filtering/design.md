# Design — refine-window-filtering

## D1. A pure filter, facts at the boundary

`WindowFilter` (new, Core) is a pure decision function: `verdict(_ candidate: WindowCandidate, policy: WindowFilterPolicy) -> WindowFilterVerdict`. `WindowService` gathers the AX facts once per window into a `WindowCandidate` (role, subrole, title, AX size, has-close-button, minimized) and derives the `WindowFilterPolicy` from settings + the app's rule. This mirrors the project's existing pure-brain pattern (`DockHoverModel`, `FilesNavigationModel`): AX/CGS reads stay in the service; every listing decision is unit-testable without AX.

The verdict carries a typed drop reason (`appExcluded`, `minimized`, `notAWindow`, `degenerateSize`, `junkSubrole`, `phantom`, `nonStandardSubrole`) — reasons are the inspector's vocabulary, so the filter and the inspector can never disagree about *why* a window is absent.

## D2. Relaxed mode: three tiers, monotonic over strict

The old relaxed gate **replaced** the subrole check with `both dims ≥ 100`, so it dropped small standard windows strict mode admits (the Finder copy-progress window). The redesign makes relaxation monotonic — strict's admissions are a subset:

1. **Known-real subroles** — `AXStandardWindow`, `AXDialog`, `AXSystemDialog` — always list (no size/title/chrome test beyond the degenerate floor). This is the allowlist half: a subrole macOS itself uses for real user-facing windows is trusted outright.
2. **Known-junk subroles** — `AXFloatingWindow`, `AXSystemFloatingWindow` — always drop. True palettes/HUDs; the layer-0 gate already catches most, this catches layer-0 oddballs.
3. **Unknown/missing subroles** (foreign toolkits: Qt emulators, Xcode's welcome window) — the discriminators decide: **non-empty title OR close-button chrome OR min side ≥ 100** (the legacy scalar, demoted from sole gate to one of three signals). A window failing all three is a phantom frame.

A **degenerate floor** (min side < 40) drops sliver/zero frames before the tiers. Strict mode takes none of this — its verdicts are byte-identical to today (standard subrole, or missing subrole → listed), so the default-config user sees no listing change except dedup.

Calibration: the emulator toolbar (61×515, untitled, chromeless, unknown subrole) drops at tier 3; the emulator device window (short side 372) lists at tier 3 via size; the Finder progress (~430×90, titled + chrome) lists at tier 1 or 3 regardless of its reported subrole.

## D3. Dedup keys on identity, not similarity

Phantom duplicates are *exact* clones: same pid, same title, same frame. The dedup key is `(pid, trimmed title, integral AX frame, isMinimized)`; the survivor is the frontmost (lowest z in `snapshot()`; lowest window id in the Dock path, where z is unavailable and the clones are visually indistinguishable anyway). Keying on exact identity keeps false positives implausible — two *real* same-app windows share a title only when they also occupy literally the same integral frame, i.e. perfectly stacked duplicates of the same content. The `include` per-app rule bypasses dedup entirely as the escape hatch. Dedup runs in strict mode too — phantom clones are junk regardless of the relaxed opt-in.

Rejected: fuzzy containment ("frame inside another frame ⇒ helper") — kills real picture-in-picture and inspector-panel layouts; the exact key doesn't.

## D4. Per-app rules override policy, not mechanism

`windowAppRules: [String: WindowAppRule]` — `include` / `strict` / `exclude`; absence = follow the global toggle. The key is `bundleIdentifier ?? executable name` (Qt/CLI-hosted apps can lack a bundle ID — the emulator that motivated the original gate is exactly such an app). Rules apply wherever windows are listed: the switcher snapshot, ⌘-Tab (same snapshot), the Dock preview (`isPreviewable`), and `minimizeAllWindows` (which reuses the gate — an excluded app is invisible to the feature, so leaving its windows un-minimized is the consistent choice and never strands a window behind a filter). `bruteForceWindows`' acquisition pre-filter widens to any-window-role when the pid's rule is `include` (else an off-Space window of an `include` app could never be acquired under a strict global).

Persistence follows the existing `persistCodable`/`loadCodable` pattern (`filesActionMenu` precedent); `resetToDefaults` clears the dictionary.

## D5. The inspector is a snapshot, never a stream

`WindowService.inspectorSnapshot()` enumerates every regular app's current-Space AX windows (`currentSpaceElements`), runs each through the same `WindowFilter` + dedup, and returns entries `(app, key, icon, title, subrole, size, verdict, dedupedOut)`. Current-Space-only is deliberate: the questions the inspector answers ("why isn't this window listed?", "why four cards?") are asked about windows the user is looking at; true off-Space ghosts remain `diagnosticReport()` territory.

The Hub Switcher page renders it in a `HubSection`: grouped by app, a verdict badge per window, a per-app rule picker writing `settings.windowAppRules`. Refresh is a button plus one on-appear load — **no timers, no auto-refresh** (the idle-CPU-spin landmine: the Hub window is `isReleasedWhenClosed = false`, a repeating tick would outlive visibility). Data flows through a new `HubContext.inspectWindows` closure wired in `makeHubContext`, keeping the page coordinator-free like every other page.

## D6. What deliberately does not change

- The AX-element-required listing model (ghost discrimination) — untouched; the filter runs after an element resolves.
- The layer-0, regular-app, own-app exclusions — untouched, ahead of the filter.
- Strict-mode verdicts — byte-identical (D2); dedup is the only strict-visible change.
- `diagnosticReport()` — kept as the deep off-Space debugging tool; the inspector is the user-facing sibling.
- The Dock preview's minimized inclusion and ordering — `isPreviewable` keeps forcing minimized-allowed; only the identity gate routes through the filter.
