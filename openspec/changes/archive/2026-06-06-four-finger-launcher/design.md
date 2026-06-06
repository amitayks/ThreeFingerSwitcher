## Context

The three-finger switcher navigates existing windows/Spaces by passive `OpenMultitouchSupport` reads plus runtime gesture ownership. `optional-space-row-gesture` established that ownership model and, in doing so, built exactly the substrate this feature needs:

- **Live finger count** — `AppCoordinator.currentFingerCount` is updated from every `TouchFrame` (`AppCoordinator.swift:40`). It already distinguishes 3 from 4.
- **Scroll suppression for ≥3 fingers** — `ScrollEventTap.consumePredicate = { currentFingerCount >= 3 }` (`AppCoordinator.swift:43`) swallows any scroll the OS produces from a freed multi-finger gesture. **This predicate already covers four fingers**, both axes (a `scrollWheel` event carries Δx and Δy).
- **Crash-safe private-API synthesis** — `MissionControl` resolves `CoreDockSendNotification` by explicit `dlopen` into an optional function pointer; a missing symbol is a no-op. `CGSPrivate` does the same for SkyLight symbols. This is the template for any new private symbol (e.g. `SLSMoveWindowsToManagedSpace`).
- **Semantic-intent routing** — the recognizer emits intents; `AppCoordinator` performs the real action (e.g. `gestureDidTriggerMissionControl → MissionControl.trigger`). Mission Control / App Exposé are now app-synthesized on idle three-finger up/down, so they are no longer an OS gesture on *any* finger count.

The consequence that makes this feature cheap: **the four-finger lane is free of OS competition by construction.** Earlier exploration worried about four-finger vertical firing Mission Control; with runtime ownership, MC lives only on app-synthesized idle three-finger up, so nothing contends for four-finger horizontal or vertical once the native four-finger keys are freed to scroll (which the existing tap already consumes).

Existing patterns to mirror:
- `Switcher{Model,View}` + `OverlayController` + `SwitcherLayout` — the non-activating `NSPanel` hosting a SwiftUI grid of `rows: [[…]]` with a current-row indicator gutter and state-driven selection highlight.
- `VerticalGestureConfig` / `TrackpadGestureConfig` — absent-aware backup/restore of trackpad-domain keys via `/usr/bin/defaults`, with `needsReloginWarning` and lifecycle wiring in `AppCoordinator`.
- `WindowService.focusSequence` / `raise` — AX-driven raise with off-Space SkyLight handshake; the same AX expertise drives menu-press "New Window," and `CGSPrivate` is where the window-move symbol joins.

The new value-add (the launcher) decomposes into four concerns: a swipe **HUD** (`launcher-overlay`), a favorites **model** (`launch-items`), an **execution** layer (`launch-actions`), and a management **editor** (`favorites-editor`), plus deltas to the four shared capabilities.

## Goals / Non-Goals

**Goals:**
- A four-finger horizontal swipe opens a launcher; the same sub-inch positional selection model as the window switcher picks an item; vertical (overlay open) switches context bands.
- Launching an app yields a **new window in the current Space**, or pulls a single-window app's existing window to the current Space — **never** a Space teleport.
- Favorites are heterogeneous (apps / paths / urls / shortcuts / scripts / presets), grouped by **user-defined context** in a **fixed order**, editable from a dedicated "small IDE."
- Consequential commits are deliberate: **dwell-to-arm + lift-to-fire**, with haptic + visual confirmation; a quick swipe never fires.
- Reuse the runtime-ownership substrate and the overlay/native-config/AX patterns; add minimal new system-level surface.

**Non-Goals:**
- Replacing or changing three-finger window/Space switching, or the idle three-finger Mission Control / App Exposé synthesis (only the *four-finger MC fallback* is removed).
- A general window manager (tiling, moving arbitrary windows between Spaces on demand beyond the launcher's "bring here").
- Fuzzy search / typing — the entire premise is zero-typing, positional selection. The editor is the only place text is entered.
- MRU / adaptive ordering of launcher items — order is fixed and user-owned by design (D2).
- Multi-instance launching of single-instance apps (`open -n`) as a default — offered only as an explicit per-item override.

## Decisions

### D1. Latch finger count at gesture start; no mid-gesture morph

`GestureRecognizer` today treats a fourth finger as an unconditional cancel (`GestureRecognizer.swift:64,72`). The change: at `begin`, latch the stable contact count and route the whole gesture — `3 → switcher`, `4 → launcher` — using the latched count as the debounce `target` (reusing the existing below/above-target flicker tolerance). The mode is fixed for the gesture's lifetime.

*Alternative considered — morph 3→4 mid-gesture* ("add a finger to escalate into the launcher"): rejected for v1. Morphing forces ill-defined transitions (what becomes of a half-selected window? does the overlay swap mid-scrub? how does dwell-arm state reset?) and complicates the recognizer for marginal benefit. "Land four fingers → launcher" already *feels* like throwing on a fourth finger; you just commit to it at the start. Revisit only if the start-from-rest cost proves annoying in practice.

### D2. Group-by-context grid, fixed order, deterministic home cell

The launcher is a 2D grid reusing the switcher's `rows: [[…]]` shape: **rows = context bands** (user-named, colored), **columns = items** in a fixed user-defined order. Activation always lands on a **deterministic home cell** — a designated home band, column 0 — never a recency-based position.

This is the core product decision. The entire value is positional muscle memory ("four fingers → flick right twice → *always* my terminal"); any reordering or recency-ranking silently destroys it. So order is immutable except through the editor, and entry is deterministic.

Context (not type) grouping means a band holds mixed kinds — *Dev* = `[Terminal, VS Code, ~/projects, deploy.sh, "Work" preset]` — because a band models a *mode of work*, which is how the user chunks their day. Color-coding the bands (and the row-indicator dots, reusing the switcher gutter) makes vertical navigation glanceable.

*Alternative considered — group-by-type* (Apps row / Scripts row / Presets row, auto-filled): rejected as the grid layout. It splits one workflow across rows (your dev terminal, dev folder, dev script live apart) and defeats the "summon a whole mode" intent. Type still appears — as the editor's **sourcing** axis (D9) — just not as the swipe grouping.

*Alternative considered — last-used context as the entry row:* rejected; convenience at the cost of determinism. The home cell is configurable but fixed.

### D3. Launch-item model and persistence

```
LaunchItem            ContextBand                   Favorites (root, versioned)
├ id                  ├ id                          ├ schemaVersion
├ title               ├ name                        ├ bands: [ContextBand]
├ icon (app / SF / emoji)  ├ color                  └ homeBandId, homeColumn  (deterministic entry)
├ tint (color)        ├ defaultAppStrategy (D4)
└ kind:               └ items: [LaunchItem]         (order = array order = swipe order)
   ├ .app(bundleURL, strategy?)        // strategy nil ⇒ inherit band default
   ├ .path(URL)                        // open file/folder
   ├ .url(URL)                         // https or app scheme
   ├ .shortcut(name)                   // `shortcuts run "name"`
   ├ .script(.shell(code) | .appleScript(code) | .file(URL))
   └ .preset([LaunchItemRef])          // ordered composite (D4: presets compose)
```

`.preset` referencing other items makes "Home/Work state" fall out of composition rather than a bespoke feature. The whole tree is one `Codable` value persisted under a **single versioned UserDefaults key** (`favorites`), departing from `AppSettings`' scalar-per-key pattern because the data is a rich nested list; `schemaVersion` enables forward migration. Items are **values, not exclusive** — the same app may appear in several bands.

*Alternative considered — Core Data / a JSON file on disk:* rejected as overkill for a small personal list; a `Codable` blob in `UserDefaults` matches the app's existing storage and testing seam (`AppSettings(defaults:)`).

### D4. "Always new window" is a per-item strategy with a smart default; presets compose

macOS has no universal "new window of app X" API, so this is a strategy ladder, defaulting to `.smart`, inheritable from the band (D2/D3):

```
fire(.app):
  not running           → launch it (first window opens on the current Space)            [trivial]
  .smart / capable      → AX-press the app's own File ▸ "New Window" / "New" menu item    [new window HERE]
  .smart / not capable  → go to the existing window (switch Spaces + focus) — D5           [single-window apps]
  .alwaysNewWindow      → force menu-press, else synthesize ⌘N                            [override]
  .bringExistingHere    → go to the existing window (the move is impossible — D5)          [override]
  .quitAndReopenHere    → quit + relaunch so a fresh window opens here (lossy)             [opt-in]
  .newInstance          → `open -n` (only for genuinely multi-process apps, e.g. terminals)[override]
```

(Originally `.smart / not capable` and `.bringExistingHere` were meant to *move* the window to the current Space; on-device that proved impossible for foreign windows — see D5 — so both now "go to the window," and `.quitAndReopenHere` is the opt-in for "open a fresh window here instead.")

The **AX menu probe is also the capability detector**: walking the app's `AXMenuBar` for a `File ▸ New Window`/`New` item answers "multi-window?" and *performs* the action via `kAXPressAction` — semantically correct, no keystroke race, and the new window reliably lands on the current Space. ⌘N synthesis is only a fallback when the menu item can't be located.

`.preset` fires its referenced items **in order**, each via this same dispatch (an app, then a path, then a script…). Consequential kinds (`.script`, `.preset`) post a success/failure notification after firing (D6 rationale: acting must be observable; raising a window is silently safe, running `deploy.sh` is not).

*Alternative considered — a single universal mechanism* (always `open -n`, or always ⌘N): rejected. `open -n` spawns second processes (wrong for ~all single-instance apps); blind ⌘N misfires where ⌘N isn't "new window." The menu-press default is the only approach that respects each app's real semantics.

### D5. Single-window apps: a foreign window CAN'T be moved across Spaces — go to it, or quit+reopen here

**Original intent (proved impossible — kept for history):** for single-window apps, move the target window to the **current** Space via `SLSMoveWindowsToManagedSpace(cid, [wid], currentSpaceID)` and raise it locally without activating first, so the window comes to the user with no Space switch.

**On-device finding (REVISED during apply):** macOS does **not** permit an app *without SIP partially disabled* to move another process's window between Spaces. Verified end-to-end with file-logged diagnostics on a stable-signed build (Messages, System Settings), all three candidate mechanisms return success yet have **no effect** on a foreign off-Space window:

> - `SLSMoveWindowsToManagedSpace` — call returns, window stays on its Space (dest `id64` == `ManagedSpaceID`, so it isn't a space-id namespace bug).
> - `CGSAddWindowsToSpaces` (+ `CGSRemoveWindowsFromSpaces`) — same: returns, no move.
> - AX minimize→restore (minimized windows normally restore onto the *current* Space) — `AXUIElementSetAttributeValue(kAXMinimized, true)` returns `err=0` but the off-Space window never actually minimizes, so there is nothing to restore here.

This is the same capability yabai ships a SIP-disabled scripting addition for; a normal app can't require that. So "the window flies to you" is **not achievable** for foreign single-window apps. Two teleport-honest behaviors that ARE possible, exposed as the strategy ladder (D4):

> - **`.smart` / `.bringExistingHere` → go to the window.** Switch to the window's Space and focus it via the switcher's robust off-Space raise (`WindowService.raise`: SkyLight front handshake + Stage-Manager hold-guard + focus watchdog). It moves *you*, not the window — but it's a deliberate, chosen launcher action, and it always reaches the app. `LaunchService` gets this via an injected `goToWindow(pid)` closure so it stays decoupled from `WindowService`.
> - **`.quitAndReopenHere` (opt-in) → quit + relaunch here.** A fresh launch always opens its first window on the current Space, so quitting (gracefully, allowing save) and relaunching brings a usable window to the user. Destructive (loses unsaved state, may show a save prompt, ~1–2 s), so it is an **explicit per-item strategy** the user opts specific safe apps into — `.smart` never selects it (no auto-kill footgun). The favorites editor (tasks §8) surfaces the choice; until it ships, single-window apps behave as "go to the window."

What *did* land from the original plan and still matters: the **teleport bug is fixed** (we no longer call `app.activate()` while a window is off-Space), off-Space windows are enumerated via the private per-Space API (`SpaceService.windowsInSpace`, not the public `CGWindowList` which misses them), and `relocate(pid:)` cleanly classifies `.broughtHere` (already on the current Space → focus locally) / `.noWindows` (reopens here) / `.failed` (off-Space → go to it).

*Alternative considered — activate then move back:* moot (the move doesn't work). *Alternative — `CGSAddWindowsToSpaces`:* tested, also blocked. *Multi-window apps are unaffected* — they get a real new window on the current Space via the AX menu-press path (D4), which works.

### D6. Dwell-to-arm / lift-to-fire commit; feedback in the overlay, timing out of the recognizer

The switcher commits on lift because raising is idempotent. Launching is consequential, so the launcher uses: land on an item → **dwell ≥ T** → **armed** (haptic tick + charge-ring fills) → **lift fires**; lift while not armed **dismisses**; swiping off an armed item **disarms** it. This makes accidental fires structurally hard — a fast scrub-and-release never triggers anything.

The recognizer stays dumb: it emits launcher `activate / item-step / context-step / end` intents only. The **dwell timer, arm state, haptic, and charge-ring live in the launcher controller** (it knows when selection settled). On `end` (lift) the controller fires the armed item or dismisses. `T` is a tunable (default ~500 ms — long enough to be deliberate, short enough to stay "instant"; 1 s tested as too slow for the stated zero-friction goal). The charge-ring carries the feedback visually so the experience degrades gracefully if haptics are unavailable (see Risks).

*Alternative considered — same lift-commits model as the switcher:* rejected; one stray four-finger flick could run a script or open five windows. *Alternative — a confirmation step / modal:* rejected as too heavy for a flow whose point is minimal effort; dwell-arm is the lightest deliberate-intent signal.

### D7. Trackpad ownership extends to four fingers; one launcher opt-in; four-finger MC fallback removed

A single persisted **launcher opt-in** binds (a) the recognizer emitting four-finger launcher intents and (b) freeing the native four-finger swipes — `TrackpadFourFingerHorizSwipeGesture` and `TrackpadFourFingerVertSwipeGesture → 0` in both trackpad domains, absent-aware backup, **one-time re-login** (identical mechanics to `VerticalGestureConfig`). They cannot be independently enabled (same binding rationale as the Space-row opt-in's D1).

Freed four-finger swipes degrade to scroll, which the **existing** `ScrollEventTap` already consumes (predicate `≥3`, unchanged). The only runtime-ownership change is **lifecycle**: the tap must run while the launcher opt-in is effective, not solely the Space-row opt-in (`tap.start()` when *either* is effective).

Because four-finger vertical is now claimed by context-switching, the **four-finger Mission Control fallback** that `optional-space-row-gesture` deliberately left enabled (`TrackpadFourFingerVertSwipeGesture = 2`) is removed (set to `0`). Mission Control / App Exposé remain fully available via the app's idle three-finger up/down synthesis — no user-visible loss.

*Alternative considered — a unified "ThreeFingerSwitcher owns the trackpad" toggle* freeing all four lanes at once: attractive (one re-login total) and noted as a likely future consolidation, but kept as a separate launcher opt-in for v1 so the feature ships independently of the in-flight Space-row change and users can adopt incrementally.

### D8. Parallel `Launcher*` overlay trio, reusing switcher infrastructure

Add `LauncherModel` / `LauncherView` / `LauncherOverlayController` mirroring the `Switcher*` trio and reusing `SwitcherLayout` metrics and the non-activating-panel pattern, rather than overloading `SwitcherModel` with a cell-kind union. The grid structure is identical; the cell content differs (icon + label + band color + charge-ring instead of a window thumbnail). Parallel types keep each overlay's state machine clean (the launcher's dwell-arm state has no analogue in the switcher).

*Alternative considered — one generic overlay with a cell-content protocol:* tempting for DRY, but the two overlays differ in commit model, selection semantics, and per-cell state; a shared abstraction would leak conditionals. Reuse the *layout* and *panel*, not the *model*.

### D9. Editor sources by type, arranges by context

The "small IDE" separates the two axes that were conflated in exploration: the **sidebar sources items by type** (drill into "Apps" → a scrollable list of all installed apps; same for Shortcuts / Paths / Presets / Scripts), and the **canvas arranges by context band** (drag chips to reorder within a band, drag bands to reorder, click a chip to remove, set name/icon/color per item and per band, set the band's default app strategy). Clicking a sourced item adds it to the **active target band**. A `+ Add manually` affordance covers free-form url/path/script entry with a custom short name, icon, and color. A menu-bar **"Add front app → band"** adds the frontmost app without opening the editor.

This makes editing **spatially identical to swiping** — the canvas *is* the grid you'll navigate.

### D10. Idle four-finger vertical is reserved (no action) in v1

With the launcher on four-finger horizontal and context-switching on four-finger vertical *inside* the overlay, an **idle** four-finger vertical (pre-activation) has no assigned action. Its scroll is consumed by the tap; the recognizer ignores it. Left reserved for a future quick-action rather than overloaded now.

## Risks / Trade-offs

- **[Haptic actuation from a background accessory app mid-gesture may be unreliable]** → Spike `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, …)` from the signed (not ad-hoc) build with no click event in flight (S-OQ1). The charge-ring is the primary, always-present arm signal, so a missing tick degrades gracefully rather than breaking the commit UX.
- **[Multi-window "new window here" can flash the app's other-Space window before the new one appears]** → Spike the clean path (S-OQ2): anchor the app on the current Space (or create the window) before it fronts. The single-window "bring here" path (D5) is already teleport-free; if the flash proves unavoidable for some apps, expose `.bringExistingHere` as the per-item escape.
- **[`SLSMoveWindowsToManagedSpace` reliability on current macOS]** → Spike on Sonoma/Sequoia with Stage Manager and "assign to Space" windows (S-OQ3); full-screen windows are out of scope for moving. Crash-safe resolution means a missing/again-renamed symbol degrades the bring-here path to "launch/activate" rather than crashing.
- **[`open -n` / new-instance misused on single-instance apps]** → `.newInstance` is never a default; `.smart` never selects it. It is an explicit per-item override with a UI caveat.
- **[Consequential script/preset fired by accident]** → dwell-to-arm (D6) plus post-fire notifications; presets list their steps in the editor so their blast radius is visible before saving.
- **[One-time re-login confuses users / managed (MDM) Macs block the four-finger writes]** → reuse the existing detect-and-warn (`needsReloginWarning`) and the non-fatal "couldn't change the setting" path from `applySpacesRearrange`; the launcher simply doesn't engage and stays gated off.
- **[Stale four-finger backup if the app crashes before restore]** → reuse the proven absent-aware JSON backup + reapply-on-launch + idempotent restore from `VerticalGestureConfig`.
- **[New-window menu item is localized / named differently per app]** → match a small ordered set of candidate titles ("New Window", "New", plus localized variants) and the first File-menu item whose action implies new-window; fall back to ⌘N; record misses so the candidate set can grow.

## Migration Plan

- **Builds on `optional-space-row-gesture`.** Land/keep that change first; this one assumes `ScrollEventTap`, `MissionControl`, live finger-count, and `VerticalGestureConfig` exist. The shared deltas (`gesture-recognition`, `native-gesture-config`, `runtime-gesture-ownership`, `tunable-settings`) stack on top of that change's deltas.
- **Default off.** The launcher opt-in is off by default; nothing changes for existing users until they enable it (then a one-time re-login frees the four-finger lanes).
- **Rollback.** Toggling the launcher opt-in off restores the native four-finger gestures from the absent-aware backup and re-enables the four-finger MC fallback if it was originally present; the favorites data persists harmlessly under its own key. Removing the feature entirely leaves only an unused `favorites` UserDefaults key.
- **Build/sign constraint (process note, inherited):** in-app testing of TCC-dependent paths (AX menu-press, scroll tap, window move, haptics) requires a **stable-signed** build from the user's Terminal (`INSTALL=1 ./scripts/build-app.sh`); the sandboxed agent shell can only produce ad-hoc builds (broken Accessibility). Agent writes code + `swift build`/`swift test`; user installs to verify behavior.

## Open Questions

- **S-OQ1 (NOT blocking — decoupled by design; on-device check pending):** Does `NSHapticFeedbackManager` actuate the Taptic Engine for a background `.accessory` app with no in-flight click, from a stable-signed build? The commit UX was deliberately built so this is non-blocking: the **charge-ring is the primary, always-present arm signal** and the haptic tick is best-effort (`LauncherOverlayController` performs it but never depends on it). So the dwell-arm/lift-fire flow (§7) ships regardless of the answer. The actuation itself can only be felt on hardware from the user's stable-signed build (the sandboxed agent build can't verify it) — left as a hardware check (task 1.1); if it proves unreliable we simply remain charge-ring-only with no code change.
- **S-OQ2 (RESOLVED during apply):** the minimal teleport-free new-window sequence is **create-then-front, never front-first.** `makeNewWindow` triggers the new window against the *background* app (AX menu-press, ⌘N fallback) so it is born on the current Space, then defers `activate()` (~120 ms) until the window exists — activating first was teleporting to the app's other-Space window. Two app-specific findings folded in: (a) a **submenu-parent** new-window item (Terminal's *Shell ▸ New Window ▸ profile*) can't be pressed — pressing it only opens the submenu — so the menu-press descends to the first concrete profile leaf, with ⌘N as the final fallback; (b) the AX menu-walk still **detects** such a submenu parent as "multi-window capable" so the strategy routes correctly. Residual: a faint flash is still possible for some apps; `.bringExistingHere` remains the per-item escape.
- **S-OQ3 (RESOLVED during apply — negative result):** moving a **foreign** single-window app's window to the active Space is **not possible** without SIP partially disabled. The symbol resolves and the call (and `CGSAddWindowsToSpaces`, and an AX minimize→restore) all return success but have **no effect** on an off-Space foreign window — verified on a stable-signed build with file-logged diagnostics (Messages, System Settings); dest `id64` == `ManagedSpaceID`, so it isn't a namespace bug. This is the yabai-scripting-addition capability a normal app can't require. Pivoted (D5): single-window apps **go to the window** (deliberate Space switch via `WindowService.raise`), with an opt-in **`.quitAndReopenHere`** to instead relaunch a fresh window on the current Space. The teleport bug that *was* in scope (activating an off-Space window) is fixed regardless.
- **Home cell configurability:** ship a fixed home band/column with a setting to choose which band is "home," or hard-code band 0 column 0 for v1? (Leaning: hard-code, add the setting if asked.)
- **Naming:** persisted keys and labels — `favorites` vs `launchItems`; opt-in label ("Launcher" / "Quick Launch" / "Favorites switcher"). Cosmetic, non-blocking.
- **Dwell default:** confirm ~500 ms against feel once haptics land (S-OQ1); expose as a tunable regardless.
