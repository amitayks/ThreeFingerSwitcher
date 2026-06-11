## Context

macOS exposes the keyboard input source (layout / input method) as a single **global** setting; unlike Windows there is no per-window or per-app language. ThreeFingerSwitcher already (a) observes `NSWorkspace.didActivateApplicationNotification` (`MRUTracker`) and (b) persists rich per-feature state as versioned JSON in `UserDefaults` (`FavoritesStore`, `ClipboardStore`). That gives us both the activation signal and a proven persistence pattern, so remembering and restoring a per-app input source is a small, well-isolated addition.

Two hard constraints shaped the design:

1. **Windows have no durable identity.** `WindowInfo.id` is a `CGWindowID`, reassigned on every relaunch. The only key that survives the target app quitting *and* our relaunch is the application's **bundle identifier**. The requirement ("survive per app") confirms per-app is the durable unit.
2. **The input source is controlled only via Carbon TIS.** There is no Swift/AppKit equivalent. `TISSelectInputSource` / `TISCopyCurrentKeyboardInputSource` and the `kTISNotifySelectedKeyboardInputSourceChanged` distributed notification are the entire mechanism. No TIS code exists in the project today.

## Goals / Non-Goals

**Goals:**
- Remember the keyboard input source per application (bundle id), auto-learned from the user's own changes — zero manual setup.
- Re-select an app's remembered source automatically when it becomes frontmost.
- Apply a user-chosen **global default** source to apps with no memory.
- Persist per-app memory across the target app quitting and across our own relaunch.
- Keep the decision logic pure and unit-tested in the MLX-free `ThreeFingerSwitcherCore`; isolate Carbon side effects behind a seam.
- Configure entirely from the Hub: an enable toggle + a global-default picker. Off by default.

**Non-Goals:**
- **No per-window memory.** Multi-window apps (Chrome, Terminal) get one language per app in v1. Per-window would be in-session only (no durable key) and needs per-app `AXObserver` on `kAXFocusedWindowChanged` — out of scope.
- **No per-app override editor.** Learning is implicit only; there is no UI list of apps→languages to curate.
- No language-code abstraction or fuzzy "language → a layout" mapping; we store concrete input-source IDs.
- No enabling of disabled input sources on the user's behalf.
- No interaction with text fields / secure input beyond best-effort selection.

## Decisions

### D1: Per-app, keyed by bundle identifier (durable unit)
Memory is a `[bundleID: inputSourceID]` map. Bundle id is the only identity that survives both quits. Apps without a bundle id (rare faceless processes) are simply not learned/applied.
- *Alternative — per-window (CGWindowID):* impossible to persist across restart; rejected.
- *Alternative — per-window via title heuristics:* fragile, surprising; rejected.

### D2: Store the input-source **ID**, not a language code
We persist `kTISPropertyInputSourceID` (e.g. `com.apple.keylayout.Hebrew`, `com.apple.inputmethod.SCIM.ITABC`). It is exact, round-trips through `TISSelectInputSource`, and natively covers CJK **input methods**, not just keyboard layouts. A language code (`he`/`en`) would force a `TISCopyInputSourceForLanguage` guess that is ambiguous when the user has two layouts for one language.
- *Alternative — store language code:* lossy/ambiguous; rejected.

### D3: Learn on deactivation is the only write path
The remembered source for an app is written **only** by capturing that app's current input source at the moment focus leaves it — read once, synchronously, on the *next* app's activation, before any new source is applied. At that instant the OS still reports the outgoing app's source (we are the only thing that changes it, and we haven't yet), so attribution is deterministic. There is no "set language for app" command. This makes the WhatsApp example work with no setup, keeps the data model to a single mutation, and — crucially — makes each app's memory **immune to what the user does in other apps** (no asynchronous change notification to classify; see D5).

> Revised after first-run testing. The original design (below, D5) learned by observing the global input-source-change notification; that proved racy and could lose a per-app value after the user toggled the language in a *different* app. Learning on deactivation fixed it.

### D4: Two pure rules in Core, Carbon behind a seam
The brains are two pure functions in `ThreeFingerSwitcherCore`:
- `activate(bundleID, map, globalDefault) -> InputSourceID?` — what to select when an app comes to front.
- `learn(bundleID, source, map) -> map` — the updated map after a user change.

All Carbon I/O sits behind an `InputSourceController` protocol (`currentSourceID() -> InputSourceID?`, `select(_:) -> Bool`, `enabledSources()`). The real implementation (`CarbonInputSourceController`) links Carbon; a fake implements it in Core tests. This mirrors the existing `LLMRuntime` seam: pure, testable decision logic + a thin impure shell. (Both live in the `ThreeFingerSwitcherCore` target — `Sources/ThreeFingerSwitcher/` — which is MLX-free and builds under `swift build`; Carbon is a system framework, so the seam exists for **testability**, not a target constraint.)

### D5: No change-notification observer (superseded — see D3)
The original design observed `kTISNotifySelectedKeyboardInputSourceChanged` and tried to tell our own programmatic `select` apart from a genuine user change with an `applying`/expected-value guard. That classification is **racy**: the distributed notification is asynchronous and `frontmostApplication` is read live, so under real app-switching timing a per-app value could be mis-attributed or lost (the reported "Telegram forgets Hebrew after toggling in Terminal" bug). D3's learn-on-deactivation removes the need entirely — we never observe a global change notification, so there is nothing to classify and no feedback loop. The TIS change notification is no longer used; the only remaining best-effort concern is a failed `select` (risk table).

### D6: Activation is the pivot for both learn and apply
Everything is driven by `didActivateApplication`. On each activation the service reads the current source **once**, learns it for the *outgoing* app (D3), then applies the *incoming* app's remembered source. Activation is the natural boundary, so we never yank the layout mid-typing *within* an app; switching apps is exactly when the user expects the context (and language) to change. Re-activating the same app is a no-op, so an in-place change the user just made is never overwritten until they actually leave.

### D7: Global default is a user-chosen, enabled source
The default is one input-source ID the user picks in the Hub from their **enabled** sources. Applied to any app not present in the map (first seen after launch, or never recorded). Because it (and every learned value) is an already-enabled source, `select` never needs to enable a disabled layout. If unset, the feature applies nothing to unseen apps (pure learn-as-you-go).
- *Alternative — snapshot the source active at our launch:* less predictable, no UI; rejected per product decision.
- *Alternative — no global default:* offered as the "unset" state rather than a separate mode.

### D8: Persistence = versioned JSON in UserDefaults
`KeyboardLanguageStore` follows `FavoritesStore`: a `schemaVersion`-stamped `Codable` record, injectable `UserDefaults` for isolated tests, `mutate`/`save` on every change. The global default + enable flag are scalars on `AppSettings` (consistent with other feature toggles); the per-app map is the store's JSON blob.

### D9: Off by default, lifecycle-gated
`AppCoordinator` starts the service's observers only when `keyboardLanguageEnabled` is true and stops them when it flips off. While disabled the app performs **no** TIS reads or writes and registers no observers.

## Risks / Trade-offs

- **Mis-attributing a source change to the wrong app** → eliminated by learning on deactivation (D3): the outgoing app's source is read synchronously at the activation boundary, so there is no asynchronous notification to classify and no feedback loop (D5, superseded). A per-app value is immune to language changes the user makes in *other* apps.
- **In-app change lost if our app is killed before the user leaves that app** → learning happens on deactivation, so a source change the user makes and never navigates away from (before a hard crash of *our* process) isn't persisted. Accepted: normal app switching always learns on the way out, and the store persists immediately on each capture.
- **A stored/default source later disabled in System Settings** → `TISSelectInputSource` fails; treat as best-effort no-op, keep the current source, log only. This is a silent background action, so per the project's error ethos it is **never** surfaced via a modal — at most a log line.
- **App with no bundle identifier** → skip both learn and apply for that app; no crash, no partial state.
- **Secure input / password fields** → selection still works; we accept a possible language switch on app activation as expected behavior. No special-casing in v1.
- **Multi-window apps share one language** → accepted non-goal (D1); documented so it is not mistaken for a bug.
- **Rapid app switching** → each activation triggers one dictionary lookup + at most one `select`; cost is negligible and self-debouncing (selecting the already-current source is a no-op we can short-circuit).
- **First-ever enable** → no map yet; every app is "unseen" and gets the global default (or nothing if unset). The map fills in as the user works. No migration needed.

## Migration Plan

Purely additive and opt-in. New UserDefaults keys only; no existing key changes. Rollback = turn the toggle off (observers stop, no further reads/writes); the stored map is inert and harmless if left behind. No data migration on first run (empty map is valid).

## Open Questions

- Should selecting the already-current source be short-circuited before calling `select` (micro-optimization + avoids a redundant notification)? Leaning yes; cheap to add in the service.
- Picker source list: show all **enabled keyboard input sources** (`TISCreateInputSourceList` filtered to selectable, category keyboard/IM) by localized name — confirm that filter at implementation time against the running system.
