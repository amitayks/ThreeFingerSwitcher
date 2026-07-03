## Context

The window switcher (`Overlay/SwitcherModel` + `Overlay/OverlayController` + `Overlay/SwitcherView`) is a cross-Space, window-level, preview-rich overview. Today its *only* driver is the trackpad: `TouchEngine` → `Gesture/GestureRecognizer` → the `GestureRecognizerDelegate` methods on `AppCoordinator` (`gestureDidActivate` / `gestureDidStep` / `gestureDidStepRow` / `gestureDidCommit` / `gestureDidCancel`). The recognizer is a *driver*: it decides when to open, how the selection moves, and when to commit; the overlay/model just render and raise.

Two facts make a keyboard driver cheap:

- `gestureDidActivate` is input-agnostic — it snapshots windows, groups them with `SpaceGrouping.group`, shows the overlay, and seeds/prefetches thumbnails. Nothing there is trackpad-specific except the wizard/demo guards.
- The hard commit primitive already exists: `WindowService.raise(_:)` performs the off-Space SkyLight `setFront` + `makeKeyWindow` handshake (`CGSPrivate.swift`, *"verified against AltTab's SkyLight.framework.swift"*). AltTab is the canonical "replace ⌘-Tab with a cross-Space window switcher," so the exact precedent is already vendored.

The existing session-level scroll interception (`TouchInput/ScrollEventTap`, a `.cgSessionEventTap` `CGEventTap` that self-heals on `.tapDisabledBy*`) is the template for a keyboard tap. Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`) is already tracked in `PermissionsService` and held by the app.

All affected code is in MLX-free Core, so it verifies under `swift build` / `swift test`; only the live ⌘-Tab suppression needs the real signed app.

## Goals / Non-Goals

**Goals:**
- Drive the *existing* switcher overlay from ⌘-Tab, gated behind an opt-in (default OFF).
- Tab steps the selection forward one window at a time, flowing linearly across Space boundaries; Shift+Tab returns to the first window; ⌘-release commits; Esc cancels.
- Reuse the overlay, model, thumbnails, live-preview refresh, and cross-Space raise unchanged. Net-new = one keyboard tap, one linear-traversal primitive, one setting, mutual exclusion.
- No new permission, no re-login.

**Non-Goals:**
- App-level switching. The unit is the window (the switcher is window-based).
- MRU / recency ordering. Traversal follows the overlay's own spatial order (the Space-grouped reel); a recency mode is possible future work but would fight the reel's visual identity.
- Live Space switching *during* browsing — the real Space switch happens once, on commit.
- "Quick-flick" (⌘-Tab-release faster than the overlay appears → instant swap with no overlay). v1 always shows the overlay on the first Tab; a flick optimization can come later.
- Rebinding to a chord other than ⌘-Tab, or a standalone HUD distinct from the switcher.

## Decisions

### D1 — A second *driver*, not a second switcher

`KeyboardSwitcher` is a sibling to `GestureRecognizer`: it produces the same intents (open / step / home / commit / cancel) against the same `OverlayController` + `SwitcherModel`. `gestureDidActivate`'s body is extracted into a shared `openSwitcher()` on `AppCoordinator` that both drivers call.

*Alternative rejected:* a keyboard-specific overlay. It would duplicate the reel layout, thumbnail cache, live refresh, and cross-Space raise — all of which are the expensive parts — for no user-visible gain.

### D2 — A session-level keyboard `CGEventTap`, modeled on `ScrollEventTap`

`KeyboardSwitcherTap` creates a `.cgSessionEventTap` `.defaultTap` over `keyDown | keyUp | flagsChanged`. It:
- tracks the ⌘ (`.maskCommand`) modifier from `flagsChanged`;
- while ⌘ is held, **consumes** (returns `nil` for) `Tab` (`kVK_Tab` = 48, layout-independent) and Shift+Tab, forwarding them to the session as forward/home intents — so the native switcher HUD never appears;
- consumes `Escape` only while a session is active (to cancel without the keypress reaching the focused app);
- passes through **every other event unmodified**, including ⌘ with any non-Tab key (⌘-Q/W/Space/…) and a bare Tab (no ⌘);
- self-heals: re-enables itself on `.tapDisabledByTimeout` / `.tapDisabledByUserInput`, exactly like `ScrollEventTap`.

*Alternative rejected:* `RegisterEventHotKey` (Carbon). It cannot reliably suppress the system ⌘-Tab HUD and gives no signal for the ⌘-**release** that defines commit. A `flagsChanged`-observing event tap is the only way to get the "hold-⌘, browse, release-⌘-to-commit" model.

### D3 — Suppressing the native ⌘-Tab HUD is the one thing to spike

Returning `nil` for a ⌘-held `Tab` keyDown at the session tap is what stops the OS switcher (AltTab's approach). This is the single load-bearing assumption. **Task 1 is a spike** on the target macOS: confirm (a) the HUD never appears and (b) the ⌘-release `flagsChanged` is observed for commit. If suppression proves partial on some OS, the opt-in stays behind that finding rather than shipping a flickering HUD.

### D4 — The interaction state machine (pure, testable)

`KeyboardSwitcher` is a pure state machine (no AppKit); the tap feeds it raw key/flag events and it emits intents. States:

```
  idle ──(⌘ down)──▶ armed ──(Tab)──────▶ active ──(Tab)──────▶ active   (step forward)
                       │                    │  ──(Shift+Tab)──▶ active   (jump to first)
                       │                    │  ──(⌘ up)───────▶ commit ─▶ idle
                       │                    │  ──(Esc)────────▶ cancel ─▶ idle
                       └──(⌘ up, no Tab)────┴──────────────────────────▶ idle  (never opened)
```

- **⌘-down alone opens nothing** — we cannot tell ⌘-Tab from ⌘-Q at ⌘-down, so `armed` only *watches* for Tab. Other keys flow through untouched and (if they aren't Tab) the session collapses back to idle on ⌘-up.
- **The first Tab opens the overlay AND immediately steps once** in the Tab's direction (⌘-Tab → next window, ⌘-Shift-Tab → previous), so a quick press-and-release lands on the *adjacent* window like the native switcher, rather than resting on the current one. The state machine emits `open` then a `step(forward: !shift)` on the opening Tab. *(Revised from the first cut, which opened on the current window and only advanced on the second Tab.)*
- **Safety teardown:** if the overlay is somehow left active without a ⌘-up (app resigns active, tap disabled, engine stop), the session cancels and the overlay is torn down — honoring switcher-overlay's "always torn down" requirement.

### D5 — Linear traversal: the one new model primitive

The reel's flat order is exactly `SpaceGrouping.group`'s output: rows in Mission-Control order, each row's windows in snapshot order. **flat index** = (Σ window counts of rows before `currentRow`) + `selectedIndex`.

`SwitcherModel` gains the pure `linearTarget(delta:wrap:)` — map current (row, index) → flat index, add `delta`, wrap or clamp by `wrapAtEnds`, map back to (row, index) — plus `setRowAndColumn(_:column:)` (the existing `setRow` resets column to 0, insufficient here). The **animated** application lives on `OverlayController.selectLinear(delta:wrap:)`, which slides the reel inside an explicit `withAnimation` only when the row changes (mirroring the existing `moveVertical` (model) / `updateRow` (animated overlay) split). Forward (Tab) uses `delta: +1`; **backward (Shift+Tab) uses `delta: -1`** — the exact reverse, flowing across Spaces the same way (forward into a Space edge → next Space's first window; backward past a Space's first window → previous Space's **last** window).

*Revised after testing:* Shift+Tab was first specced as "jump to the session origin (first window)." In use that only ever moved within the starting Space (the origin is always there), so it read as "backward doesn't cross Spaces." It is now a **symmetric backward step** — the same primitive with a negated delta — which crosses Spaces backward as expected. The origin / `firstTarget` / `selectFirst` machinery was removed.

### D6 — Space switch on commit, not during browse

Tab browsing only moves the highlight and scrolls the overlay reel (reusing `switchSpace` + slide-freeze). The **real** Space switch + raise happens once, on ⌘-up, through `windowService.raise(_:)` — which already switches Space for an off-Space window. Live per-Tab Space thrash (each switch is a ~0.3s animation) is explicitly avoided.

### D7 — One switcher session at a time (mutual exclusion + guards)

A single owner flag guards the switcher: whichever driver opened it owns it; the other is inert until it closes. Concretely, the keyboard driver ignores Tab while a trackpad gesture holds the overlay, and the trackpad path is unaffected while a keyboard session is active. The keyboard driver also honors the existing `wizardOwnsGestures` / `switcherDemoActive` guards (inert while onboarding owns the stage).

### D8 — Opt-in and install

`AppSettings.commandTabSwitcher: Bool` (default `false`), surfaced as a Hub toggle. `main.swift` installs `KeyboardSwitcherTap` only when the flag is on **and** Input Monitoring is granted; toggling off removes the tap so the native ⌘-Tab is fully restored with no re-login. Because it is a live event tap (not a `defaults write` gesture relocation), enabling/disabling takes effect immediately.

### D9 — Browsing work runs OFF the tap callback; the commit raise stays prompt

An active `.cgSessionEventTap` makes the WindowServer **block on the tap callback** until it returns. So the callback must stay cheap. The per-keystroke browsing intents are heavy — open → window snapshot + `overlay.show` + thumbnail prefetch; each cross-Space step → a prefetch — and running them synchronously inside the callback stalled the *entire* input pipeline (the trackpad frames and highlight rendering share the same main thread) behind every keypress (the lag observed in the first cut).

So **open, step, commit, and cancel** all dispatch their work to the next main-runloop tick (`DispatchQueue.main.async`), **FIFO-ordered so open → step → commit run in exactly the order the keys were pressed**; only cheap ownership bookkeeping (claiming `switcherOwner`) stays synchronous.

**Commit MUST defer too — a synchronous commit broke FIFO order (§9.7).** An early cut made `keyboardSwitcherCommit` raise *synchronously* (§9.4), on the theory that the cross-Space `setFront` handshake had to land tight against the ⌘-release. But because it ran synchronously inside the ⌘-up tap callback while open/step were deferred, a fast ⌘-Tab press-release could process the whole ⌘-down / Tab / ⌘-up burst before the run loop drained the deferred open/step: the synchronous commit then ran FIRST, saw `overlay.isVisible == false` (open hadn't run), dismissed nothing, and the open/step drained afterward and **stranded a now-commitless overlay on screen** (the "stuck overlay" bug). Deferring commit restores FIFO: commit always runs after the open that shows the overlay and the step that advances it, so the overlay is always dismissed. Prompt focus is no longer needed for correctness — §9.5 made `WindowService.raise` arm the polling **hold-guard** for *every* off-Space raise, re-fronting the target for ~1.2s (plain) / ~2.4s (Stage Manager) and defeating the "selected then deselected" steal *regardless of when the raise fires*. The one-run-loop-tick deferral is imperceptible and is a single end-of-gesture raise (not per-keystroke browsing work), so it reintroduces neither the steal nor the browsing lag. The deferred commit guards `switcherOwner == .keyboard`, so a prior commit/cancel that already resolved (and hid) the session makes a stale commit a safe no-op.

The pure state machine's transitions stay synchronous throughout (so `isActive` / consume decisions never race), and the trackpad path calls the same shared methods synchronously from the touch-frame handler, which does NOT block the WindowServer, so it is unaffected.

*Alternative considered:* run the tap on a dedicated background thread (the AltTab / Karabiner pattern). Deferring the browsing work off the (main-runloop) callback achieves the same decoupling with far less machinery, so the background thread was not needed.

### D10 — Arrow keys navigate the open switcher (Windows-Alt-Tab parity)

While the switcher is open (⌘ held), the tap forwards the four arrow keys to a new `arrow(_:)` on the state machine (`SwitcherArrow` = left/right/up/down), consumed ONLY while `isActive` so ⌘-arrow shortcuts are untouched when the switcher is closed, and never opening it (only Tab opens). **Left/Right reuse `keyboardSwitcherStep(forward:)`** — identical to Shift+Tab / Tab, so they step linearly and flow across Spaces one window at a time (`→ → → next Space →`). **Up/Down use a new `keyboardSwitcherStepSpace(up:)`** that jumps directly to the adjacent Space via the trackpad's `switchSpace`; its direction mirrors `GestureRecognizer.emitRowStep` exactly (`up ? +1 : -1`, flipped by `reverseVerticalDirection`), so an Up arrow and an up-scrub move the reel identically without the design needing to know the reel's visual orientation. Arrows are deferred off the tap callback like the other browsing intents.

## Risks / Trade-offs

- **Native ⌘-Tab HUD not fully suppressed on some OS** → D3 spike gates the feature; AltTab-proven and its bridge is vendored. If partial, don't ship the flicker.
- **A keyboard tap observes all key events (privacy/perf)** → the handler inspects only the ⌘ flag and the Tab/Esc keycodes, never logs key content, and returns every other event untouched with minimal work. Same trust boundary as the already-granted Input Monitoring.
- **System disables the tap on timeout** → re-enable on `.tapDisabledBy*`, mirroring `ScrollEventTap` (already proven).
- **A missed ⌘-up would strand the overlay** → the safety teardown in D4 (resign-active / engine-stop / tap-disable → cancel) guarantees the overlay is never left up, per switcher-overlay's teardown requirement.
- **Conflicts with another ⌘-Tab replacer (AltTab/Contexts/Witch)** → documented; two taps both consuming ⌘-Tab is undefined, so the user should run one. Not mitigated in code.
- **First-Tab-opens-on-origin vs. Cmd-Tab's open-on-previous** → a deliberate divergence (D5); avoids depending on recency/frontmost-index that spatial order doesn't provide. Revisit if muscle-memory feedback demands it.
