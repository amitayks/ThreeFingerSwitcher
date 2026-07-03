## Context

This slice is **Wave 3** of the V2 AI agent (see `docs/ai-agent-v2-blueprint.md`). It owns shared contract **3.5** (`ParkedSession` / `ParkState` / `ParkScheduler`), the durable `AgentConversation` store, the notch home zone + rail, and the park/sleep/discard/evict lifecycle. It consumes types from earlier waves verbatim and never redefines them.

Three existing seams are the ground truth this design reuses (read them, do not fork them):

- **`DockPreviewOverlayController`** (`Overlay/DockPreviewOverlay.swift`) — the app's lone **mouse-interactive, non-activating** overlay: a `SwitcherPanel` with `[.borderless, .nonactivatingPanel]`, `ignoresMouseEvents = false`, `acceptsMouseMovedEvents = true`, `level = .popUpMenu`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`, never key/main, and a **synchronous `orderOut`** `hide()`. It exposes `show(at:)` (orders front, for open/swap) vs `move(to:)` (reposition only, never re-front — so it never stomps a layer above it). The rail panel is the same species.
- **`DockPreviewController`** + **`GlobalCursorMonitor`** + **`DockHoverModel`** (`Dock/`) — the **edge-gated cursor-reveal** pattern: a passive global+local `.mouseMoved` monitor (no Input Monitoring permission), a pure brain that takes `cursor`/`now:`/geometry and returns a `Decision`, and a controller that reads geometry only when the cursor is near the relevant edge (cheap idle), runs a coarse re-feed timer only while shown, and tears down synchronously. The rail's reveal/keep/grace-dismiss is this pattern with the **top-center notch zone** as the edge.
- **`BubbleMorph`** (`Overlay/BubbleMorph.swift`) — the "first spring": `scaleEffect(seedScale=0.02 → 1)` + `opacity` on `.spring(response: 0.34, dampingFraction: 0.72)`, with a matching `bubbleTransition` for membership insert/remove. Overscroll-park plays this **in reverse** (canvas recedes toward the notch); a rail card buds in with `bubbleMorph`; a pulled-back card buds the canvas back up.

The **notch-degradation** precedent is `DeviceLink/ReceiveHUD.topCenterRect(size:)`: `safeAreaInsets.top > 0` ⇒ a physical notch (tuck `safeTop + 8` below it); else a fixed `12pt` margin under the menu bar. This slice generalizes that into the home-zone anchor so it **never hard-depends on a notch**.

The **park trigger** is the canonical two-finger compass (blueprint §6.4): the recognizer keeps emitting raw `±1` via `launcherCanvasResolve(dx:dy:)`; interpretation lives at the `AppCoordinator` seam. **UP = scroll**, and **overscroll-past-bottom = PARK** — i.e. when the canvas is already scrolled to its bottom and the user continues a two-finger UP excursion past an overscroll threshold (above incidental scroll), the consumer reads "park," not "scroll." The recognizer is **not** changed by this slice.

## Goals / Non-Goals

**Goals:**
- A pure, `swift test`-able **scheduler** (`ParkScheduler` + `SerialParkScheduler`) whose interface is the batching drop-in: `maxSlots == 1` now, `maxSlots == K` later, **no API change**.
- A pure, `swift test`-able **lifecycle** (`ParkLifecycle`): max parked count with idle-only eviction, idle-timeout → summarize-and-sleep, discard semantics with explicit "side effects not rolled back."
- A durable `Codable` **store** for parked `AgentConversation`s (survives relaunch with a one-line resume).
- The **notch home zone** overlay + **rail**, reusing the `DockPreviewOverlay`/`GlobalCursorMonitor` pattern, degrading notch→tab, with synchronous teardown.
- Per-card **state badges** and the make-or-break **ambient needs-you notch glow** (peripheral, never modal).
- A pure **overscroll-park** decision helper consumed at the `AppCoordinator` seam (recognizer untouched).

**Non-Goals:**
- The **batched MLX execution** and the **KV-cache drop/restore** mechanics (owned by `ai-batched-runtime-and-context`; this slice requests a sleep/resume through a seam and consumes `runnableSessions`).
- **Multi-active** scheduling policy beyond one-active-now (the *interface* is K-ready; driving K slots is the batched slice's job).
- **What makes a step `needs-you`** — write-policy tiers, the audit log, the whitelist (`ai-background-autonomy`); this slice only *receives* `escalate(_:reason:)` and renders the badge + glow.
- The **canvas `State` cases** + seed/float-up/compass UX (`ai-conversational-canvas`); this slice exposes the park trigger and the restore entry point it consumes.
- The conversation **types** themselves (`ai-conversation-runtime` owns `AgentMessage`/`AgentConversation`/`AgentSessionID`/`AgentTurn`); this slice owns only the **store**.
- Any Intel/low-end fallback. Apple-Silicon M5/M4 only; background + batched is in scope precisely because the hardware serves it.

## Decisions

### 1. `ParkState` / `ParkedSession` — verbatim from the blueprint (3.5), this slice OWNS them
```swift
public enum ParkState: Codable, Equatable, Sendable {
    case active     // foreground, in the canvas
    case parked     // stashed at the notch home zone, may run in the background
    case needsYou   // a dangerous write / approval escalated to foreground (badge + ambient glow)
    case idle       // nothing pending (eligible for summarize-and-sleep + eviction)
}

public struct ParkedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: AgentSessionID    // SAME identity as AgentConversation.id (3.1) — stable across park/restore
    public var title: String
    public var state: ParkState
    public var badgeCount: Int       // unseen results / needs-you items shown on the rail card
    public var nextRunAt: Date?      // scheduler hint for a timed/scheduled continuation
    public var updatedAt: Date
}
```
`ParkedSession` is the lightweight **rail/scheduler row**; the full `AgentConversation` lives in the store keyed by the same `id`. `badgeCount` and `state` are the only two fields the badge view reads. `idle` is the only state eligible for sleep + eviction (Decision 7). `Codable` because it persists alongside the conversation so the rail rebuilds on relaunch.

### 2. `ParkScheduler` — the batching seam; one active now, K-ready by construction
```swift
public protocol ParkScheduler: Sendable {
    func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID]  // which parked sessions to advance
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult)         // feedback after a (batch) step
    func escalate(_ id: AgentSessionID, reason: String)                   // → .needsYou + badge + ambient glow
}
```
- `runnableSessions(now:maxSlots:)` is **pure** (`now:` is an input, mirroring `DockHoverModel`): it filters the parked set to the runnable ones (state `.parked`, `nextRunAt == nil || nextRunAt <= now`, not blocked on `needsYou`) and returns **up to `maxSlots`** ordered by priority. The batched runtime decides `maxSlots`; this slice never assumes the count.
- **`SerialParkScheduler`** is the concrete v1 policy: it returns **at most one** session regardless of the caller's `maxSlots` (one active generation in this slice), ordered by `nextRunAt` then `updatedAt` (oldest-waiting first), with `needsYou` sessions **excluded** (they are blocked on the user, not runnable). The **foreground active session always gets a slot** (the batched runtime reserves slot 0 for it; the scheduler only fills the *remaining* parked slots — so a `SerialParkScheduler` returning 1 plus a foreground session is two streams once batching lands, which is exactly the K-ready story).
- **Batching is a drop-in:** the batched runtime calls `runnableSessions(now:maxSlots: K)`; a future `ConcurrentParkScheduler` returns up to `K` without any protocol change. The scheduler is the *only* place the slot count is interpreted, so the one→K transition is contained.
- `didAdvance(_:result:)` is the feedback edge: a `.done` result decrements/settles the run, bumps `updatedAt`, and (if the conversation produced a new unseen result) increments `badgeCount` + sets `state = .done`; a `.failed(headline:)` sets the card's failed badge carrying the **clean headline only**; `.awaitingApproval` for a `dangerous` step routes through `escalate`.
- *Rejected:* baking `maxSlots == 1` into the protocol (e.g. `nextRunnable() -> AgentSessionID?`). That would force a protocol break when batching lands — exactly the structural conflict the blueprint's "scheduler is the seam batching plugs into" decision forbids.

### 3. `ParkedSessionStore` — the durable conversation store (this slice OWNS the store, not the types)
A `Codable` store of `AgentConversation` keyed by `AgentSessionID`, plus the `[ParkedSession]` rail/scheduler rows. Mirrors the **Files-band sync-model + async-cache** pattern: a pure in-memory index the scheduler/rail read synchronously, with disk IO bridged off-main by the owning store (an `actor` or a serialized writer). Persisted under the app support dir (one JSON per session + a manifest, or a single store file — implementation detail), behind a small `protocol ParkedSessionStore: Sendable { func all() -> [ParkedSession]; func conversation(_:) -> AgentConversation?; func upsert(_:); func remove(_:); func oneLineResume(_:) -> String? }`. The runtime slice owns `AgentConversation`'s shape (3.1); this slice owns persistence — **no duplicate store** (blueprint 3.1 note). A store IO failure maps to `ParkError` at the boundary, surfaced as a bounded `failed` badge, never a thrown crash and never silent.

### 4. Overscroll-park — a pure decision at the `AppCoordinator` seam (recognizer untouched)
A pure helper (Core):
```swift
enum OverscrollPark {
    // dy > 0 is UP travel (scroll); park only when already at bottom AND the excursion exceeds the threshold.
    static func shouldPark(dy: CGFloat, canvasAtBottom: Bool, overscrollThreshold: CGFloat) -> Bool
}
```
- The canvas reports `canvasAtBottom` (the symmetric companion of the existing `canvasAtTop` guard). The recognizer's raw `launcherCanvasResolve(dx:dy:)` is read at `AppCoordinator`: a UP excursion (`dy > 0`) is normally scroll; **only** when `canvasAtBottom == true` and the accumulated UP excursion exceeds `overscrollThreshold` (a value **above `canvasResolveThreshold`**, so reading the canvas / a normal scroll-to-bottom never parks) does the consumer fire **park**.
- This mirrors the existing `canvasAtTop` commit guard exactly (down-at-top = commit; up-past-bottom = park) — the spatial mnemonic TOP=act / BOTTOM=stash. The recognizer keeps emitting raw `±1`; this slice adds **no** recognizer state.
- *Rejected:* a dedicated recognizer "overscroll" gesture. It would fork `GestureRecognizer` and violate the "interpretation lives at the consumer seam" decision; the consumer already has `canvasAtTop`, so adding `canvasAtBottom` + a threshold is the minimal, in-pattern change.

### 5. The notch home zone — a `DockPreviewOverlay`-species panel, notch-ATTACHED-or-tab, never notch-dependent
A `NotchHomeZoneOverlayController` built on the same panel recipe as `DockPreviewOverlayController` (non-activating, mouse-interactive, never key/main, `level = .popUpMenu`, `.canJoinAllSpaces`, synchronous `orderOut`). Anchoring is **top-center** via a pure `NotchHomeZoneAnchor` mirroring `DockHoverModel.anchorRect`/`clamp` (pure, unit-tested, `now:`-free — pure geometry). There are **two anchor modes** behind one controller, selected by whether a physical notch resolves at runtime:
```swift
enum NotchHomeZoneAnchor {
    // Runtime detection: the cutout box (Cocoa global) from the safe-area inset + the menu-bar areas
    // flanking the camera housing; nil ⇒ notchless/external ⇒ the tab path.
    static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?) -> CGRect?

    // TAB mode (notchless/external) — top-center, hangs below the menu bar (unchanged).
    static func zoneRect(size: CGSize, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect
    static func railRect(zone: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect

    // ATTACHED mode (physical notch) — the NotchNook look: the nub hugs the notch's bottom edge; the panel
    // reaches the PHYSICAL top (notch.maxY) so its black merges with the notch; content sits BELOW the band.
    static func attachedNubRect(size: CGSize, notch: CGRect, screenFrame: CGRect) -> CGRect
    static func attachedPanelRect(contentSize: CGSize, notch: CGRect, screenFrame: CGRect) -> CGRect
    static func attachedLiveZone(nub: CGRect, panel: CGRect?, notch: CGRect) -> CGRect
}
```
- **Attached mode (physical notch):** the zone is a thin nub whose TOP is flush at the notch's bottom edge; the revealed panel's TOP reaches the **physical top** (`notch.maxY`, i.e. it draws **over** the menu-bar strip — `SwitcherPanel.reachesPhysicalTop` skips AppKit's constrain-below-the-menu-bar), is **centered on the cutout**, and its width is floored at `notch.width + 2·minNotchFlank` so the panel is never narrower than the notch. The chrome is a **plain rounded rectangle** filled **opaque black** — the notch is **not carved**: because the panel is black and the notch is black, the panel's black simply spans up **behind** the notch and the two read as one shape (no cutout, no seam to align, robust to any notch corner radius). Top corners are square (`UnevenRoundedRectangle`, flat top) so it grows cleanly from the physical top; bottom corners rounded. The hairline border traces only the **sides and bottom** (an open `NotchPanelBorderShape`), never the top edge, and the **window itself casts no shadow** in attached mode (`hasShadow = false`) — a window drop-shadow at the top would read as a border where the panel meets the notch/menu bar — so nothing draws a line across the merge. The cards are **centered in the panel on both axes** (a `GeometryReader` + `frame(minWidth:minHeight:alignment:.center)` — horizontal centering so a few sessions don't hug the left yet still scroll on overflow; vertical centering so the row sits clear of the notch). The panel height carries an extra notch-band of headroom (`contentSize.height + notch.height`) so the centered row clears the notch. Covering the focused app's menu titles while expanded is **intended** (the NotchNook trade), matched only in attached mode.
- **Spread animation (ease-in-out):** the panel does not bud on the first spring here — it **spreads**. A `@Published isExpanded` on the view-model drives a `scaleEffect(anchor: .top)` + opacity from a small seed to full; the controller flips it inside `withAnimation(.easeInOut)` on reveal (grow out of the notch) and on the grace-dismiss (recede back in). The grace-dismiss defers its `orderOut` until the recede finishes (a cancellable work item, cancelled if a reveal re-arrives mid-recede); **restore and feature-off stay synchronous** `orderOut` (the ghost-on-Space-switch landmine). The re-feed timer pauses while receding (`isReceding`) so a tick never re-issues the dismiss.
- **Degradation (MUST, not optional):** `notchRect == nil` (notchless built-in or **external display**) ⇒ a **top-center menu-bar tab** at a fixed margin (the `ReceiveHUD` `12pt` precedent), a plain `RoundedRectangle` on `.regularMaterial`, hanging **below** the menu bar. The same controller drives both; only the anchor + chrome differ. The home zone is **never** a hard dependency on a physical notch.
- **Black-on-black, not carved:** the merge needs no shape trickery — an opaque-black panel drawn up behind a black notch is seamless, so there is no cutout to align and nothing depends on the notch's (unpublished) corner radius. This is more robust than carving a matching notch silhouette.
- *Refined (supersedes the original "never touch the notch pixels" rejection, alt #3):* on a physical notch the panel now **attaches to and visually merges with** the notch (reaching the physical top; its black spans behind the notch), because "floating a little below the notch" read as detached. This is **not** a live widget rendered *inside* the black cutout — content is **centered clear** of the notch; the merge is a placement + fill decision, and the **tab degradation is preserved** so external/notchless displays stay honest (the reason alt #3 was cautious). The reversal mirrors `dock-window-previews` reversing its own D2.

### 6. State badges + the ambient needs-you notch glow (the make-or-break UX)
Each rail card renders a badge off `ParkedSession.state` + `badgeCount`:
- **thinking** — a subtle animated indicator (the session is `parked` and currently holds a scheduler slot / is generating). Calm, not a spinner-of-doom.
- **done** — a count chip (`badgeCount` of unseen results); pulling the card back clears it.
- **needs-you** — a distinct accent treatment on the card **and** the ambient zone glow (below).
- **failed** — a bounded `failed` badge carrying the **clean headline only** (`AIPresentedError.headline`); raw text only behind an opt-in "Show details" disclosure on the restored canvas, never in the badge. A side effect that did not land is `failed`, never a false "done."

The **ambient needs-you notch glow** is the centerpiece and is specified tightly so it is peripheral, not intrusive:
- It is a **soft, slow glow** on the notch home zone itself (a pulsing accent halo around the resting zone / the notch's lower edge), **not** a bounce, **not** a sound, **not** a window that steals focus, **not** an `NSAlert`. The panel stays non-activating and never becomes key — the glow draws attention without grabbing it.
- It appears **only** when at least one parked session is in `needsYou` and **persists** (slow-pulsing) until the user reveals the rail and addresses (restores or dismisses) every `needsYou` session — an escalation must never be silently missable, but it must also never block work.
- Revealing the rail does **not** clear it; addressing the `needsYou` session(s) does. So the glow is an honest "you have N things waiting," readable at a glance from peripheral vision.
- It rides `BreathingGlowBackdrop`/`PulseHalo` from the existing `WizardMotion` vocabulary (reuse, not reinvent) so it reads as the same app.
- *Rejected:* a Dock badge / Notification Center alert (out of the overlay model, needs entitlements, intrusive) and a count-up animation that re-fires on every step (visual noise). The glow is binary-presence + slow-pulse; the *count* lives on the card.

### 7. Lifecycle — `ParkLifecycle` (pure, injected `now:`)
```swift
struct ParkLifecycle {
    var maxParked: Int
    var idleTimeout: TimeInterval
    // Sessions newly idle past the timeout → request summarize-and-sleep (drop KV, keep one-line resume).
    func sleepable(_ sessions: [ParkedSession], now: Date) -> [AgentSessionID]
    // When over maxParked, the least-recently-updated IDLE session to evict (never active/needsYou/thinking).
    func evictable(_ sessions: [ParkedSession], now: Date) -> AgentSessionID?
}
```
- **Max parked count:** when the parked set exceeds `maxParked`, evict the **least-recently-updated `idle`** session (its conversation persists its one-line resume but its full transcript may be dropped per the sleep path). **Never** evict an `active`, `needsYou`, or actively-`thinking` session — the user's attention/escalation is protected.
- **Idle timeout → summarize-and-sleep:** a session that has been `idle` longer than `idleTimeout` is requested to **summarize-and-sleep**: the batched-runtime slice drops its **KV cache** (frees unified memory) and this slice persists a **one-line resume** (`AgentConversation.compactedSummary` / a dedicated resume line) so a later restore re-primes cheaply. Sleep is requested through an injected seam (`ParkSleepRequesting`) so Core stays MLX-free — the KV drop is the batched slice's, this slice owns *when* and the *persisted resume*.
- **Discard semantics (explicit):** discarding a parked session **cancels its pending generation via `Task` cancellation** (a cancellation is *not* a failure — no `failed` badge), removes the durable conversation from the store, and removes the rail card. **Completed side effects CANNOT be rolled back** — a calendar event already written, a file already moved, a Claude process already launched stay done; discard stops *future* work only. This is stated in the spec so no consumer expects an undo.
- `ParkLifecycle` is pure with `now:` injected → fully `swift test`-able (eviction picks the right victim; sleepable respects the timeout; active/needsYou are never chosen).

### 8. The rail controller — edge-gated reveal, pull-back-to-active, synchronous teardown
`NotchHomeZoneController` (app target) wires it together exactly like `DockPreviewController`:
- A `GlobalCursorMonitor` (passive, no Input Monitoring) feeds cursor points; while the rail is hidden the controller reads geometry only when the cursor is **near the top-center zone** (the edge-gate analogue of `nearDockEdge`) — cheap idle. A pure `NotchRevealModel` (mirroring `DockHoverModel`: `feed(cursor:zoneRect:railFrame:now:) -> Decision` with a unified zone+rail live area and grace-dismiss) decides reveal/keep/dismiss; `now:` is an input.
- On reveal: `overlay.show(at: railRect)` (orders front), cards bud in via `bubbleMorph`. While shown a coarse re-feed timer (the `hoverTickInterval` analogue) advances grace/relayout without depending solely on move events.
- **Pull a card back to active:** clicking a card (or a downward drag past a small threshold on it) **restores** that session — it becomes the active canvas (the consumer/`ai-conversational-canvas` re-seeds the canvas from the stored `AgentConversation`), its `ParkState` → `.active`, its `badgeCount` → 0, and if it was the last `needsYou` the ambient glow clears. The restore re-uses the same identity (`AgentSessionID`), so every subsystem still refers to the same session.
- **Teardown is synchronous** (`overlay.hide()` → `orderOut`) — the documented ghost-on-Space-switch landmine applies here exactly as in the Files band and Dock preview. Reposition uses `move(to:)` (never re-front) so the glow/menu-layer ordering is never stomped.
- Gated by an opt-in (the agent feature being enabled); when off, the monitor isn't installed.

### 9. Error handling — one `ParkError`, mapped at the boundary, bounded + non-blocking
`enum ParkError: Error, Equatable, LocalizedError` carries only what `RuntimeError`/`TaskError` cannot: **store/persistence** failures (`.storeUnavailable`, `.persistFailed`, `.resumeMissing`). Vendor/OS errors (`FileManager`, JSON coding) map into `ParkError` at the store boundary so Core stays MLX-free and never leaks an OS error into UI text. Every surface routes through `AIError.message(for:)` → `AIPresentedError` (clean `headline` + opt-in copyable `details`). A failed park/restore/persist surfaces as a **bounded** `failed` badge on the rail card (headline only) + Retry on the restored canvas — **never** `NSAlert.runModal` (it freezes the Settings window), never raw error text in a headline.

## Target split & verification (per component)

| Component | Target | Verified by |
|---|---|---|
| `ParkState`, `ParkedSession` (3.5 types) | Core | `swift test` (Codable round-trip, identity stability) |
| `ParkScheduler` protocol + `SerialParkScheduler` | Core | `swift test` (one-active-now; `maxSlots` honored; `needsYou` excluded; priority order; K-ready: a stub returning ≤K) |
| `ParkedSessionStore` (protocol + impl) | Core (IO bridged off-main) | `swift test` (in-memory impl: upsert/remove/resume; `ParkError` mapping at boundary) |
| `ParkLifecycle` (eviction + sleepable) | Core | `swift test` (eviction victim selection; idle-timeout sleepable; active/needsYou never chosen; injected `now:`) |
| `OverscrollPark.shouldPark` | Core | `swift test` (at-bottom + over-threshold parks; below-threshold scrolls; not-at-bottom never parks) |
| `NotchHomeZoneAnchor` / `NotchRevealModel` | Core (pure geometry + lifecycle) | `swift test` (tab anchor + clamp; **attached mode**: notch-box detection + degradation, nub flush at notch bottom, panel reaches physical top + width floor, live-zone unions the notch band; reveal/keep/grace-dismiss with injected `now:`) |
| `ParkError` + `AIError.message(for:)` routing | Core | `swift test` (each case → clean headline; no raw OS text) |
| `NotchHomeZoneOverlayController` (panel) | App / GemmaRuntime | `xcodebuild` compile-verify; **user run-verifies** the panel, glow, notch/tab |
| `NotchHomeZoneController` (cursor wiring, restore, glow) | App | `xcodebuild` compile-verify; **user run-verifies** reveal/teardown/restore |
| `BubbleMorph` fly-up wiring in the canvas host | App | `xcodebuild` compile-verify; **user run-verifies** the fly-up |
| `AppCoordinator` overscroll-park consumer wiring | App | `xcodebuild` compile-verify; **user run-verifies** the park trigger |

Per the house rule, an agent **never** builds/signs/installs the `.app` (ad-hoc signing breaks TCC). Pure Core is `swift build`/`swift test`; the MLX-linked/overlay pieces are `xcodebuild` compile-verify only; behavior (glow, fly-up, notch-vs-tab, reveal) is the user's run-verify in a stable-signed build. To compile-check this slice in isolation without sibling slices' uncommitted files, use a throwaway `git worktree` + `swift build`.

## Edge cases

- **Notchless built-in display / external display:** `safeAreaTop == 0` → the home zone is a top-center menu-bar tab; everything else (rail, badges, glow, scheduler) is identical. Verified by the anchor unit test + user run-verify on an external monitor.
- **Display reconfigure / screen change while parked:** the zone re-anchors on the active screen (`move(to:)`, reposition only) on the next reveal; the durable store is display-agnostic.
- **Space switch while the rail is shown:** synchronous `orderOut` teardown (the ghost landmine) — never deferred.
- **Park while a tool step `awaitingApproval`:** the session parks as `parked`; a `dangerous` step escalates to `needsYou` via `escalate` (raised by `ai-background-autonomy`), lighting the glow; a `confirm` step waits as `parked` until restored.
- **Overscroll at top vs bottom:** `canvasAtTop` guards commit (existing); `canvasAtBottom` + threshold guards park (this slice). A short conversation that is both at top and bottom: park requires the explicit UP-past-bottom excursion above `overscrollThreshold`, so a single tiny scroll never parks.
- **Discard a session mid-generation:** `Task` cancellation stops it (not a failure); completed side effects stay (no rollback) — spec'd so no false-undo expectation.
- **Max parked reached with all non-idle:** nothing is evicted (active/needsYou/thinking are protected); a new park is still accepted (the cap is a soft target for *idle* eviction, never a hard refusal that loses a conversation).
- **Relaunch:** the rail rebuilds from the store; sleeping sessions show their one-line resume; restoring re-primes (the KV was dropped, the resume re-seeds context cheaply).
- **needs-you glow never clears:** if the user reveals the rail but doesn't address a `needsYou`, the glow persists — addressing (restore/dismiss) is the only clear, so an escalation is never silently lost.

## Rejected alternatives (summary)

1. **Recognizer-level overscroll gesture** — forks `GestureRecognizer`; rejected in favor of the consumer-seam `canvasAtBottom` + threshold (mirrors `canvasAtTop`).
2. **`nextRunnable() -> AgentSessionID?` scheduler** — bakes one-active-now into the protocol; rejected for `runnableSessions(now:maxSlots:)` so batching is a drop-in.
3. **A live "notch widget" rendered *inside* the notch's black cutout** — still rejected: no parked content is ever drawn inside the cutout. *Refined by §5, though:* on a physical notch the panel now **attaches to and merges with** the notch (top edge at the physical top; an opaque-black panel drawn behind the black notch reads as one shape) so it becomes a downward extension of the notch, while the **tab degradation is preserved** for notchless/external displays (the honest cross-display model this alternative was protecting).
4. **Dock badge / Notification Center alert for needs-you** — intrusive, out of the overlay model, needs entitlements; rejected for the peripheral ambient glow + on-card count.
5. **A second conversation store** — rejected; this slice owns the durable store, the runtime slice owns the types (blueprint 3.1).
6. **App-modal alert on a park/restore/persist failure** — freezes Settings; rejected for the bounded `failed` badge + Retry through `AIError.message(for:)`.
