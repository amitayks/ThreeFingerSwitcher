## Context

This is **Wave 4** of the V2 agent decomposition (`docs/ai-agent-v2-blueprint.md`). It is the **front end** of the whole vision: the typed, multi-turn **conversational canvas**. It owns the canvas UX (seed → float-up → multi-turn → gesture compass) and the *canvas-level* additive `AICommandExecutor.State` cases; it **consumes** the conversation types, the session machine, the tool-route loop, and the parked scheduler from earlier waves — it does not redefine any of them.

Ground truth in the existing code (read before judging this design):

- **`AI/AICommandExecutor.swift`** — the `@MainActor ObservableObject` with `enum State` (`.idle`/`.loadingModel`/`.noInput`/`.streaming(partial:)`/`.ready(result:)`/`.reviewingAction(TaskReview)`/`.declined(reason:)`/`.failed(message:)`/`.unavailable`/`.committed`), `@Published thinking`, `@Published activeLanguage`, `var canvasAtTop`, a per-fire `generationTask`, and the two-stage `fire(_:)` → stream → `commit()`. `State.isCommittable` gates the DOWN-swipe commit. **This slice keeps every existing case and path** and adds canvas-level cases on top.
- **`Overlay/AICommandCanvasView.swift`** — the streaming preview view: header + status badge, a collapsible **Thinking** section (`BidiText`, live elapsed timer), a `resultScroll` (`BidiText`), the `reviewFields` armed-confirmation, the `.unavailable` enable/download subview, and `footerHint`. The `CanvasAtTopKey` preference + `onPreferenceChange` already feed `executor.canvasAtTop`. This slice **extends** this view with a thread renderer + a focusable composer; it does not fork it.
- **`Overlay/LauncherOverlayController.swift`** — `setCanvasInteractive(_:)` flips `panel.ignoresMouseEvents` + `panel.keyInteractive` + `makeKeyAndOrderFront` for the unavailable controls / the language dropdown. **Safe for the captured app's focus** because the panel is a `.nonactivatingPanel` (becoming key never *activates* this app) and the compass is recognized off the multitouch device (not window mouse events). This slice extends the flip to **field focus**.
- **`App/AppCoordinator.swift`** — `launcherCanvasResolve(dx:dy:)` already maps the recognizer's raw axis-locked `±1` through `canvasResolveDecision(dx:dy:binding:)` to `.commit`/`.discard`/`.ignore`, with the **`canvasAtTop` commit guard** binding-independent. This is the consumer seam where this slice adds the **overscroll-park** read and the **Enter-sends** wiring.
- **`Gesture/GestureRecognizer.swift`** — `trackCanvasResolution` emits raw `launcherCanvasResolve(dx:dy:)` (`±1`, axis-locked) past `canvasResolveThreshold` (0.12, above incidental two-finger scroll), while `launcherCanvasResolutionActive`. **The recognizer is NOT changed by this slice** (matches the gesture-bindings + parked-sessions precedent — interpretation lives at the consumer seam).
- **`openspec/specs/ai-command-band/spec.md`** — the capability spec this slice delta-modifies (input acquisition, output routing, preview canvas). **`openspec/specs/launcher-overlay/spec.md`** already specifies the two-finger swipe-to-resolve (down=commit / horizontal=discard / up=ignored); this slice MODIFIES the `ai-command-band` capability and references the launcher-overlay grammar.

**Consumed contracts (owned elsewhere — do NOT redefine; bind to the committed types):**

- `ai-conversation-runtime` (Wave 1, on disk at `openspec/changes/ai-conversation-runtime/`): `AgentRole`/`AgentMessage`/`AgentSessionID`/`AgentConversation`/`AgentTurn`; `LLMChatRequest` + `LLMRuntime.chat()`; the executor's additive `.conversing(partial:)` + `.awaitingTurn` States; `startConversation(seedText:image:…)` / `runTurn()` / `assembleRequest()`. **This slice's `State` additions are layered on top of those.** (Per that slice's D4: it adds `.conversing`/`.awaitingTurn` and leaves `.awaitingApproval`/`.parked` for THIS slice + tool-routing to add additively.)
- `ai-tool-routing` (Wave 2): the observable `AgentLoop` state (`[ToolStepResult]` + the current `.awaitingApproval` `TaskReview`), the `ApprovalGate` async seam (DOWN=approve / RIGHT=skip), `ToolStepResult`/`ToolStepStatus`.
- `ai-parked-sessions` (Wave 3): `OverscrollPark.shouldPark(dy:canvasAtBottom:overscrollThreshold:)`, the `canvasAtBottom` companion-guard contract, `ParkState`/`ParkedSession`, and the **restore entry point** the rail calls to re-open a parked conversation into this canvas.

## Goals / Non-Goals

**Goals:**
- The seed model: open the canvas **showing the seed and waiting** (no auto-fire) for the conversational path; define the waiting state (`.awaitingSeed`).
- The float-up: a placeholder over the seed that animates up the instant the user types (BubbleMorph spirit), Enter sends; the panel becomes key/main while a field is focused (extend `setCanvasInteractive`) **without** breaking two-finger resolution.
- Multi-turn: render the running thread (user/assistant turns) reusing the existing Thinking section + `BidiText`; stream the in-flight assistant turn.
- The unification: a preset = a pre-filled turn 1; the output target (`replaceSelection`/`pasteAtCursor`/`previewOnly`) governs **only what DOWN does at the seam**, not the thread shape.
- Bare-seed defaults: a pure `BareSeedDefault` (seed type → default question) so a bare seed is a valid turn 1.
- The canonical compass applied here: DOWN affirm (extract latest assistant turn / approve a step) gated by `canvasAtTop`; UP scroll & overscroll-park; RIGHT discard; LEFT reserved; Enter send. The scroll/affirm collision resolved explicitly.
- One-source discipline: turn 1 is the only seed; follow-up turns are pure text; attach-new-seed is a documented future.
- The canvas-owned executor cases + the resolve/park interpretation are MLX-free Core, `swift test`-driven with `StubLLMRuntime`.

**Non-Goals:**
- The conversation **types** + compaction (`ai-conversation-runtime` owns them; consumed here).
- The route loop, registry, candidate retrieval, approval mechanics (`ai-tool-routing` owns them; this slice **renders** the loop state + drives the gate via the compass).
- The parked **store**, **rail**, **scheduler**, **notch home zone** (`ai-parked-sessions` owns them; this slice fires the park trigger + receives the restore).
- The batched MLX runtime / KV-reuse (`ai-batched-runtime-and-context`).
- An **attach-new-seed** gesture (a second source mid-thread) — documented future; not built here.
- A new `<Slice>Error` — every failure rides `RuntimeError`/`TaskError` via `AIError.message(for:)` (the consumed slices already established this).
- Intel/low-end fallback — M5/M4-only.

## Decisions

### D1. The seed model — open showing the seed, WAIT; `.awaitingSeed` is the one new state this slice owns

Today `fire(_:)` immediately acquires input, resolves the preset template, and streams. V2 splits the two intents:

- **Conversational open (the new default for an "Ask…"-style command):** `startConversation(seed:)` acquires the seed exactly as today (the same `acquireInput` + `clipboardImage`/`screenRegion` paths, the same `.noInput`/permission mapping), builds turn 1's user `AgentMessage` from it, opens the `AgentConversation` (owned by `ai-conversation-runtime`), and lands in **`.awaitingSeed`** — the canvas **shows the seed** and **waits**; the model is **not** invoked.
- **Preset open (Fix Grammar, Translate):** the SAME `startConversation(seed:)`, but turn 1 is **pre-filled** with the canned instruction folded with the seed, and it is **auto-sent** (calls `send()` once) so it streams immediately — identical to today's auto-fire feel, but it is now turn 1 of a thread (D5).

`.awaitingSeed` is the **only** new `State` case this slice *introduces*. The session-level `.conversing(partial:)` and `.awaitingTurn` are **owned by `ai-conversation-runtime`** (its D4) and merely consumed/rendered here. `.awaitingApproval(TaskReview)` and `.parked` are added by **tool-routing** / **parked-sessions** respectively; this slice **renders** them. The blueprint §5.1 line "Additive AICommandExecutor.State cases for multi-turn (.conversing, .awaitingApproval, .parked)" is satisfied by the union across slices; the ones this slice physically adds are `.awaitingSeed` (and, if not already present from the runtime slice, the render-only handling of `.awaitingApproval`/`.parked`).

```
enum State {
    // … existing one-shot cases (idle/loadingModel/noInput/streaming/ready/reviewingAction/declined/failed/unavailable/committed) …
    // … runtime-slice cases (consumed): conversing(partial:), awaitingTurn …
    case awaitingSeed                    // NEW (this slice): seed shown, no model call yet, Enter sends turn 1
    // rendered (added by sibling slices): awaitingApproval(TaskReview), parked
}
```

`.awaitingSeed.isCommittable == false` (DOWN does nothing until there is an assistant turn). State equality extends the existing hand-written `==` for `.awaitingSeed` (no payload → trivial).

*Why a distinct `.awaitingSeed` rather than reusing `.awaitingTurn`?* `.awaitingTurn` (runtime slice) means "an assistant turn has completed; the thread idles." `.awaitingSeed` means "turn 1 is shown but the model has never run." They render differently (the float-up placeholder over a bare seed vs. a full thread) and the **bare-seed default** (D6) only applies in `.awaitingSeed`. Keeping them distinct keeps each render path honest.

### D2. The float-up — a placeholder over the seed, lifting on first keystroke (BubbleMorph spirit)

The composer is a single SwiftUI subtree at the **bottom** of the canvas. Structure (in `AICommandCanvasView`):

```
VStack(spacing: 0) {
    languagePill?            // unchanged
    header                   // unchanged
    Divider
    ThreadView(conversation) // NEW: the running turns (D4); in .awaitingSeed it is just the seed card
    Spacer(minLength: 0)
    Composer(...)            // NEW: the focusable field + the float-up placeholder
    Divider
    footerHint               // existing, now turn-aware
}
```

- **Placeholder over the seed.** While `.awaitingSeed` and the composer is empty + unfocused, an overlaid "Ask anything…" placeholder sits centered over the seed card (a `ZStack` over the `ThreadView`'s single seed). On **first keystroke** (composer text becomes non-empty) OR focus gained, the placeholder animates **up and out** — a `BubbleMorph`-spirit spring (`scale 1 → 0.96` + `opacity → 0` + a small upward `offset`, on `.spring(response: 0.34, dampingFraction: 0.72)`, matching `BubbleMorph`'s soft spring) — making room for the thread to grow downward. This is the documented "BubbleMorph spirit": the same spring family, not a new haptic, no charge ramp.
- **`@FocusState`.** The composer owns `@FocusState private var composerFocused: Bool`. Tapping the field (the panel is interactive — D3) focuses it; `.onChange(of: composerFocused)` and `.onChange(of: composerText.isEmpty)` drive the placeholder float-up. The field uses `.onSubmit { send() }` so **Enter sends**.
- **Enter sends.** `send()` appends the composer text as the next user `AgentMessage` and calls the runtime slice's `runTurn()` (the executor enters `.conversing`); the composer clears; the placeholder is hidden while a thread exists. A bare-seed Enter in `.awaitingSeed` with an empty composer sends the **default question** (D6).

### D3. Panel becomes key/main while typing — extend `setCanvasInteractive`, compass still resolves

`setCanvasInteractive(_:)` already flips `ignoresMouseEvents`/`keyInteractive`/`makeKeyAndOrderFront` for the unavailable controls + the language dropdown. The conversational canvas needs the panel **key/main while a field is focused** so the keyboard reaches the SwiftUI `TextField`. Extension:

- The canvas is interactive for its **whole life** already (the controller calls `setCanvasInteractive(true)` on canvas open — see line 116/309). The composer's `@FocusState` flip is therefore a **SwiftUI-internal focus**, not a new panel call: because the panel is already key-capable, focusing the `TextField` makes it first responder and keystrokes flow. **No new AppKit call is required for the common path** — the existing `setCanvasInteractive(true)` on open suffices.
- **The load-bearing safety (verbatim from the existing doc comment):** the panel is a `.nonactivatingPanel`, so becoming key **never activates this app** — the captured front app stays the activation target; and the **two-finger compass is recognized off the multitouch device** (`GestureRecognizer`/`TouchEngine`), **not** window mouse/scroll events, so it keeps resolving while the field is focused and the panel is key. Commit/write-back re-activates the captured app (`SelectionService.app.activate` + PID-targeted AX), restoring its focus. **This slice must not regress that:** the composer must not consume the multitouch feed, and the panel must stay `.nonactivatingPanel`.
- **Teardown unchanged.** The panel is destroyed + recreated per open (`hide()` is synchronous `orderOut`/`close`), so the key/main flip resets implicitly — no ghost-on-Space-switch risk introduced (the documented overlay rule holds).

*Edge — a keyboard shortcut vs. the compass:* Enter is the **only** keyboard verb (send). All resolution verbs are two-finger; there is no keyboard commit/discard, so a focused field and the compass never fight over a key.

### D4. Multi-turn rendering — reuse the Thinking section + BidiText, per turn

`ThreadView(conversation:)` renders `conversation.messages` (the runtime slice's `AgentConversation`) as a scrollable list of turn cards:

- **User turn:** a right-aligned (LTR base) / natural-direction `BidiText` bubble of `message.text` (+ a thumbnail if `message.image != nil`, for a vision seed).
- **Assistant turn:** the `message.text` rendered through `BidiText` (the existing per-paragraph natural-base-direction renderer), preceded by the **collapsible Thinking section** when `message.thinking != nil` — the *same* `thinkingSection` component, now bound to the per-message thinking for a *completed* turn, and to the live `executor.thinking` for the **in-flight** turn (`.conversing`).
- **The in-flight assistant turn** (`.conversing(partial:)`) renders `partial` live through `resultScroll`/`BidiText` exactly as today's `.streaming` does — the existing live-render path, now appended as the last (growing) card.
- **Tool steps** (when the route loop is active — `ai-tool-routing`): the loop publishes an ordered `[ToolStepResult]` + the current `.awaitingApproval` `TaskReview`; the thread renders a compact step list (each `ToolStepResult.summary`) and, on `.awaitingApproval`, the existing `reviewFields(_:)` card. The plan rationale already rides the `.thinking` channel (tool-routing D8), so the Thinking section shows it for free.
- **Scroll-at-top + scroll-at-bottom reporters.** The existing `CanvasAtTopKey` continues to feed `executor.canvasAtTop`. This slice adds a **`CanvasAtBottomKey`** companion (same `atTopReporter` idiom, measuring `maxY` against the viewport) feeding a new `executor.canvasAtBottom` — the input the **overscroll-park** read needs (D7). Both are gate inputs the view writes; neither is `@Published`.

The thread auto-scrolls to the newest turn as it streams (the existing `ScrollViewReader` tail-follow), and rests at the bottom when a turn completes — so a fresh DOWN at the bottom is *not* a commit (the at-top guard), and an overscroll-UP at the bottom is the park excursion (D7).

### D5. The unification — a preset is a pre-filled turn 1; output target acts only at the seam

A preset and an "Ask…" are the **same** `startConversation(seed:)` differing only in turn-1 content + whether it auto-sends, and in the command's **output target**:

| Command kind | turn 1 | auto-send | output target | what DOWN does |
|---|---|---|---|---|
| Quick action (Fix Grammar) | canned instruction folded with the seed | yes | `replaceSelection` | extract latest assistant turn → replace selection (commit) |
| Translate | canned + `{lang}` folded with the seed | yes | `replaceSelection`/`previewOnly` | extract latest → route per target; language pill re-runs as today |
| "Ask…" (conversational) | **empty** (the seed alone, awaiting a question) | no (`.awaitingSeed`) | `previewOnly` | extract latest assistant turn → previewOnly = nothing written (just dismiss) |
| Side-effecting task | canned folded with the seed | yes | `runTask`/`sendTo` | route loop → DOWN approves the pending `.awaitingApproval` step |

- **The thread shape is identical** in every row — open conversation, turn 1, stream, idle, type again, stream. The **output target governs only the DOWN/affirm at the seam** (D7): which target the latest assistant turn extracts into, or that DOWN approves a tool step. It **never** changes the number of turns, the float-up, or the rendering.
- **`extractLatest()`** is the conversational generalization of today's `commit()`: it reads `conversation.messages.last(where: { $0.role == .assistant })?.text` and routes it through the command's output target (`replaceSelection`/`pasteAtCursor`/`previewOnly`) via the existing `SelectionProviding` calls — with the existing **honesty rule** (a write that didn't land is `.failed`, never a false "Done"). For a side-effecting command, DOWN instead resolves the route loop's pending approval (tool-routing's `ApprovalGate.approve`).
- **Auto-send for presets is one `send()` after `startConversation`.** The preset path therefore reuses the *entire* conversational machine; it is not a parallel code path. (This is the "SAME canvas, SAME state machine" requirement — implemented as one entry with a parameter, not two surfaces.)

### D6. Bare-seed defaults — a pure `seed type → default question` resolver

"Send just the copied text/image with no question" must be a valid turn 1, not an empty model call. A pure Core resolver:

```swift
enum BareSeedDefault {
    // The default question used when a bare seed is sent with no typed question.
    static func question(for seed: SeedKind) -> String
}
enum SeedKind: Equatable { case text, image }   // derived from the command.input source
```

- **`image` → describe / what-is-this** (e.g. `"Describe this image. What is it?"`) — applies to `clipboardImage` + `screenRegion`.
- **`text` → summarize / explain** (e.g. `"Summarize this. Explain it briefly."`) — applies to `selection` + `clipboard`.
- The bare-seed default fires **only** when the user sends (Enter / DOWN-while-`.awaitingSeed`) **with an empty composer**. A typed question replaces it. The default is folded with the seed exactly as a preset instruction is (D5), so turn 1 is `{default question}\n\n{seed}` for text, or `{default question}` + the image attachment for vision.
- Pure + `swift test`-able (string-stable, deterministic). It is *not* persisted or user-editable in this slice (a future "default-question per command" preference is out of scope — noted, not built).

### D7. The gesture compass (canonical) — applied to the canvas; the scroll/affirm collision resolved

The recognizer is **unchanged**; interpretation stays at the `AppCoordinator` seam (the existing `launcherCanvasResolve(dx:dy:)`). The canonical two-finger compass in the canvas:

| Excursion | Verb | Fires when |
|---|---|---|
| **DOWN** | **affirm** — `extractLatest()` to the output target, OR approve the pending tool step | **only when `executor.canvasAtTop`** (the existing binding-independent guard) |
| **UP** | **scroll** (native), and **overscroll-past-bottom → PARK** | park only when `canvasAtBottom` AND the UP excursion exceeds `overscrollThreshold` (> `canvasResolveThreshold`) |
| **RIGHT** | **discard** (cancel in-flight generation, write nothing, dismiss) | any time |
| **LEFT** | **reserved** (no-op for now) | — |
| **Enter** (keyboard) | **send** the composed turn | composer focused |

**Resolving the scroll/affirm verb collision explicitly (the crux):**
- A multi-turn thread is **scrollable** — UP and DOWN are *also* the native scroll directions. The collision is resolved by **two orthogonal gates already in the codebase**, generalized:
  - **DOWN = affirm only at the TOP** (`canvasAtTop`). Off the top, a DOWN two-finger pan is the user **scrolling the thread down** (toward newer turns) — the native scroll already handled it; affirm does NOT fire. This is the existing at-top commit guard, unchanged.
  - **UP = scroll always, except overscroll-past-bottom = PARK.** A normal UP pan scrolls (toward older turns / the seed). Only when the thread is **already at its bottom** (`canvasAtBottom`) and the user **continues UP past `overscrollThreshold`** (above incidental scroll) does the consumer read **park** (hand-off to `ai-parked-sessions`'s `OverscrollPark.shouldPark`). So UP never both scrolls and parks at the same position: it scrolls until there's nothing left to scroll, then an *extra* overscroll excursion parks.
  - **The resolve excursion threshold** (`canvasResolveThreshold`, 0.12) sits **above incidental two-finger scroll**, so reading the thread never triggers affirm/discard/park; a deliberate excursion does. Park's `overscrollThreshold` is even larger (it must clear a normal scroll-to-bottom).
- **Spatial mnemonic:** TOP of canvas = act on the result (affirm); BOTTOM of canvas = stash it (park). DOWN-at-top brings the answer **into** the document; UP-past-bottom pushes the whole session **up to the notch**.
- **Tool-step approval reuses the same compass:** when the loop is `.awaitingApproval`, **DOWN = approve** (drives `ApprovalGate.approve`), **RIGHT = skip** (`ApprovalGate.skip`) — identical mnemonic to commit/discard. The at-top guard still applies to DOWN (the review card is short and at the top, so it passes trivially).

**The consumer seam (extends `launcherCanvasResolve`):**

```
func launcherCanvasResolve(dx, dy):
  guard canvasActive
  switch canvasResolveDecision(dx, dy, binding: settings.gestureBindings.canvas):
    .commit:                                  // DOWN by default
      if executor.state.isAwaitingApproval { approveStep(); return }   // tool-step approve
      guard executor.canvasAtTop else { return }                        // at-top affirm guard
      extractLatest()                                                   // affirm → output target
    .discard:                                 // RIGHT by default
      discardCanvas()
    .ignore:                                  // UP/LEFT by default
      // NEW: overscroll-park read for an UP excursion
      if dy > 0, OverscrollPark.shouldPark(dy: accumulatedUp, canvasAtBottom: executor.canvasAtBottom,
                                            overscrollThreshold: parkThreshold) {
        parkCanvas()                          // hand-off to ai-parked-sessions
      }
      // else: genuine no-op (LEFT reserved; sub-threshold handled by the recognizer)
}
```

- The **`.ignore` branch** is where UP/LEFT land today (default up = scroll/ignore). This slice extends *only* that branch with the overscroll-park read; commit/discard are untouched. Because the recognizer already emits a single axis-locked `±1` past threshold, "overscroll-past-bottom" is read from `dy > 0` + `canvasAtBottom` + the (consumer-accumulated) excursion magnitude vs. `parkThreshold`. The gesture-bindings `canvas` binding still maps which raw excursion means commit/discard/ignore, so a user who remapped (e.g. swipe-right = commit) keeps that — park rides whatever excursion resolves to `.ignore` in the UP direction.

`parkCanvas()` calls the parked-sessions restore/park entry: it transitions `executor.state = .parked`, hands the live `AgentConversation` to the parked store (`ParkScheduler`/store own it from there), and recedes the canvas toward the notch with a **reverse BubbleMorph** (the parked slice's documented "canvas recedes toward the notch"). The overlay then tears down synchronously (orderOut) as on any resolve.

### D8. One-source discipline — turn 1 is the only seed; follow-ups are pure text

- The seed (`selection`/`clipboard`/`clipboardImage`/`screenRegion`) populates **turn 1's** user `AgentMessage` (`text` and/or `image`). **Every follow-up turn is pure typed text** — the composer produces only `text`; it never re-acquires a selection/clipboard/region or attaches a new image.
- This is the blueprint's one-source discipline made structural: `send()` for a follow-up turn builds `AgentMessage(role:.user, text: composerText, image: nil)`. There is **no** path in this slice that attaches a second image/selection mid-thread.
- **Attach-new-seed is a documented future** (an explicit gesture/affordance to add a second source to an open thread). It is named here and in the spec as out-of-scope; it is **not** silently allowed (no accidental second-source path exists). If/when added, it gets its own change with its own gesture, preserving review of the one-source rule.

### D9. Errors — one taxonomy, observable, bounded, non-blocking (consumed convention)

- Every turn/affirm/park failure rides `RuntimeError`/`TaskError` → `AIError.message(for:).headline` → the existing `.failed(message:)` rendered by the bounded `content` card (`BidiText`, capped height). **No new `<Slice>Error`** — the consumed slices established the taxonomy; this slice adds no failure category the existing ones can't carry. A failed `extractLatest()` write is `.failed`, never a false "Done" (the existing honesty rule). A failed park (store IO) surfaces the parked slice's `ParkError` headline as `.failed`, never a crash, never silence.
- **No `NSAlert`** anywhere; the canvas is the bounded, non-blocking surface. Cancellation (RIGHT discard / mid-stream cancel) is **not** a failure — it returns to idle and tears down, as today.

### D10. `@MainActor` + concurrency — unchanged shape

`AICommandExecutor` stays `@MainActor ObservableObject`. The per-turn loop is the runtime slice's retained `Task` (a discard cancels it), streaming mutates `@Published state`/`thinking` on the main actor as today. The pure value types this slice owns (`BareSeedDefault`, `SeedKind`, the canvas-resolve decision) are `nonisolated`/`Sendable` and `swift test`-able off the main actor.

## State machine (canvas-level view, layered on the runtime slice)

```
                 startConversation(seed:)            (preset path: + auto send())
   .idle ───────────────────────────────────▶ .awaitingSeed ──Enter/DOWN(empty→default)──▶ .conversing
       │  (availability gate → .unavailable)        │ Enter (typed)            ▲   │ stream
       │  (no input → .noInput)                     └────────────────────────┘   │ done
       │                                                                          ▼
       └──────────────────────────────────────────────────────────────▶ .awaitingTurn
                                                                              │  type + Enter → .conversing (loop)
                                                                              │  DOWN@top → extractLatest() → .committed
   (route loop) .conversing ──route→tool step──▶ .awaitingApproval ──DOWN approve / RIGHT skip──▶ .conversing
   any state ── RIGHT discard ──▶ .idle (teardown)
   .awaitingTurn/.conversing ── UP overscroll-past-bottom ──▶ .parked (hand-off to ai-parked-sessions, recede+teardown)
```

## File-level touch list (target + verification)

| File | Target | Change | Verified by |
|---|---|---|---|
| `AI/AICommandExecutor.swift` | Core | Add `.awaitingSeed` (+ equality); render-only handling of `.awaitingApproval`/`.parked` if not already from runtime slice; `startConversation(seed:)` (conversational + preset entry), `send()`, `extractLatest()`, `parkHandoff()`; reuse runtime slice's `runTurn`/`assembleRequest`; add `var canvasAtBottom` companion to `canvasAtTop`; bare-seed default fold | `swift test` (scripted `StubLLMRuntime`: seed-wait, typed turn, multi-turn, preset auto-send, extract latest, bare-seed default, discard, park hand-off) |
| `AI/Agent/BareSeedDefault.swift` (new) | Core | `SeedKind` + `BareSeedDefault.question(for:)` (D6) | `swift test` (deterministic string per kind) |
| `App/AppCoordinator.swift` | Core (logic) / app | Extend `launcherCanvasResolve` `.ignore` branch with the `OverscrollPark.shouldPark` read → `parkCanvas()`; DOWN-when-`.awaitingApproval` → approve; Enter-sends wiring; consumer accumulation of UP excursion for the park threshold | `swift test` for the pure decision (`canvasResolveDecision` already tested; add a park-decision test); `xcodebuild` for the wiring |
| `Overlay/AICommandCanvasView.swift` | app (Overlay) | `ThreadView(conversation:)` renderer (reuse Thinking + `BidiText`); `Composer` with `@FocusState` + float-up placeholder (BubbleMorph-spirit spring) + `.onSubmit { send() }`; `CanvasAtBottomKey` reporter → `executor.canvasAtBottom`; turn-aware `footerHint`; render `.awaitingSeed`/`.conversing`/`.awaitingTurn`/`.awaitingApproval`/`.parked` | `xcodebuild` compile-verify; **user run-verify** (float-up, focus, key/main, compass) |
| `Overlay/LauncherOverlayController.swift` | app (Overlay) | Confirm `setCanvasInteractive(true)` covers field focus on open (likely no change beyond a doc note); ensure synchronous teardown unchanged; `parkCanvas()`/`resolveCanvasCommit()` route to `extractLatest`/`parkHandoff` | `xcodebuild`; user run-verify |
| `Tests/ThreeFingerSwitcherTests/ConversationalCanvasTests.swift` (new) | Test | seed-wait, typed turn, multi-turn, preset auto-send, extract-latest per output target, bare-seed default, discard, park-decision, one-source (follow-up has no image) | `swift test` |
| `Tests/ThreeFingerSwitcherTests/BareSeedDefaultTests.swift` (new) | Test | `question(for:)` per `SeedKind` | `swift test` |

**Verification split:** the seed/send/affirm/park **machine**, `BareSeedDefault`, and the resolve/park **decision** are MLX-free Core, verified by `swift build` + `swift test` with `StubLLMRuntime` scripting full typed conversations (the runtime slice's `scriptedTurns` queue). The SwiftUI **float-up + `@FocusState` + key/main flip + thread rendering** are `xcodebuild` compile-verified (never built/signed/installed by the agent) and **user run-verified** in a stable-signed build (focus, keyboard, the two-finger compass while a field is focused). To compile-check this slice in isolation from sibling uncommitted files, use a throwaway `git worktree` + `swift build`/`xcodebuild`.

## Edge cases

- **Bare seed, empty composer, Enter.** Sends the `BareSeedDefault.question(for:)` folded with the seed (D6) — never an empty model call. A typed character before Enter replaces the default.
- **`.noInput` / permission gap on the seed.** The existing acquisition mapping is preserved: an input-requiring command with no input → `.noInput` (no conversation opens, no model call); a `screenRegion` permission gap → `.failed` naming the permission. The canvas never opens an empty thread on a missing seed.
- **DOWN before any assistant turn** (`.awaitingSeed`/loadingModel/`.conversing`): not committable → ignored (the user waits); RIGHT discard is honored at any time. Matches the existing `isCommittable` gate.
- **DOWN off the top** (thread scrolled down): scroll, not affirm (the at-top guard). The affirm requires every scrollable region at top (the `CanvasAtTopKey` reduce ANDs them — thread + thinking + result).
- **UP at a non-bottom position:** scroll only — `OverscrollPark.shouldPark` returns false unless `canvasAtBottom`. So a user reading up through old turns never accidentally parks.
- **Overscroll-park with the canvas binding remapped.** Park rides the UP/`.ignore` direction regardless of the user's commit/discard remap; if a user bound DOWN→discard and UP→commit, the at-top/at-bottom guards + the park threshold still hold (park is an additional overscroll read, not a binding slot). (Edge to confirm in run-verify with a remapped binding.)
- **Park while a turn is streaming.** `parkHandoff()` does **not** cancel the in-flight turn — it hands the live conversation to the scheduler, which continues advancing it in the background (the parked slice's job). The canvas recedes; the partial turn is preserved (no half-message dropped). (A discard, by contrast, cancels and writes nothing.)
- **Restore a parked session.** The rail calls the restore entry; this slice re-opens the canvas bound to the restored `AgentConversation` in `.awaitingTurn` (or `.awaitingApproval` if a step escalated to `.needsYou`) — the thread renders from the persisted messages.
- **Field focused + a stray two-finger scroll.** Sub-`canvasResolveThreshold` motion scrolls the thread (or the field if it's a multiline composer); it never resolves — the recognizer's threshold gates it before the consumer ever sees a `±1`.
- **Vision seed, follow-up text turn.** Turn 1 carries the image; the follow-up turn is pure text with no image (one-source, D8); the model re-sees the image via the assembled history's turn-1 message (runtime slice's `assembleRequest` carries the latest image — for a vision thread that is turn 1's image).
- **Committed/parked then a re-lift.** A stray re-lift after a resolve is a no-op (the firing lift already raised the fingers); the canvas is resolved only by a *fresh* two-finger swipe — unchanged from today.

## Rejected alternatives

- **Keep auto-fire and bolt on a "reply" box.** Rejected — it forks the one-shot and conversational paths and breaks the "SAME canvas, SAME state machine" requirement. Unifying a preset as a *pre-filled, auto-sent turn 1* makes the conversational machine the single path.
- **A new recognizer "park" / "send" gesture.** Rejected — forks `GestureRecognizer`, violates "interpretation lives at the consumer seam," and duplicates the parked-sessions decision. The recognizer keeps emitting raw `±1`; park is read at the seam from `dy>0`+`canvasAtBottom`+threshold (the same shape as the at-top commit guard).
- **A new `ConversationCanvasError` taxonomy.** Rejected — `RuntimeError`/`TaskError` (+ the parked slice's `ParkError`) carry every failure; `AIError.message(for:)` is the single translator. Adding a taxonomy violates the house rule.
- **Float the placeholder with a custom animation curve / new haptic.** Rejected — the BubbleMorph spring family is the documented "first spring"; reusing its `.spring(response:0.34, dampingFraction:0.72)` keeps the canvas consistent and adds no new haptic (CLAUDE.md: no new haptics).
- **Allow attach-new-seed mid-thread now.** Rejected for this slice — it breaks the one-source discipline silently if done casually; it is a deliberate, reviewed future change with its own gesture.
- **Make `.awaitingSeed` reuse `.awaitingTurn`.** Rejected — they render differently and only `.awaitingSeed` triggers the bare-seed default; collapsing them would make the bare-seed default fire on every idle turn (wrong) and muddle the placeholder-over-seed vs. full-thread render.
- **Persist a user-editable default question per command in this slice.** Rejected as scope creep — the static `BareSeedDefault` covers the requirement ("a sane default per seed type"); a per-command editable default is a future preference, noted not built.
