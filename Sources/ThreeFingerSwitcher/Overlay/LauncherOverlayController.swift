import AppKit
import SwiftUI

/// Owns the non-activating launcher panel and the dwell-to-arm lifecycle. Reuses `SwitcherPanel`
/// (never key/main, ignores the mouse) and `SwitcherLayout` metrics. The recognizer is dumb about
/// dwell/arm — that logic lives here: when the selection settles, a timer charges the item to
/// `armed`; a lift then fires the armed item (else dismisses).
@MainActor
final class LauncherOverlayController {
    let model = LauncherModel()

    /// Called when an armed item is fired on lift. Wired by the coordinator to `LaunchService`.
    var onFire: ((LaunchItem, ContextBand) -> Void)?
    /// Called when a RIGHT step pins/unpins the selected clipboard entry. Wired to `ClipboardStore`.
    var onTogglePin: ((LaunchItem) -> Void)?
    /// Called when the AI preview canvas's commit gesture (a four-finger DOWN swipe) resolves. Wired by
    /// the coordinator to `AICommandExecutor.commit()`. Only invoked while the canvas is active + ready.
    var onCommitCanvas: (() -> Void)?
    /// Called when the AI preview canvas is discarded (a horizontal swipe / cancel gesture). Wired to
    /// `AICommandExecutor.cancel()` so any in-flight generation stops and nothing is written.
    var onDiscardCanvas: (() -> Void)?
    /// Called when the canvas opens (`true`) / closes (`false`). The coordinator uses it to put the
    /// gesture recognizer into canvas-resolution mode, so a fresh four-finger swipe resolves the canvas
    /// (horizontal = discard, down = apply) instead of opening the launcher again.
    var onCanvasStateChanged: ((Bool) -> Void)?
    /// Called when the Files band becomes the active band (`true`) / stops being it (`false`) — mirrors
    /// `onCanvasStateChanged`. The coordinator uses it to put the gesture recognizer into the sustained
    /// Files-drill mode (`filesDrillActive`), so horizontal travel drills the directory tree and a
    /// resolving lift opens / Open-Withs the highlighted entry instead of stepping the grid. Flipped on
    /// every band change (show / vertical band switch / horizontal escape) and cleared on `hide`.
    var onFilesColumnStateChanged: ((Bool) -> Void)?
    /// The executor whose observable streaming state the preview canvas binds to. Injected by the
    /// coordinator before `show`; the panel's `LauncherView` is built with it (the panel is recreated
    /// fresh on every `show`, so a late-set executor is picked up on the next open).
    var executor: AICommandExecutor?
    /// Enable/download wiring for the canvas's `.unavailable` state (configuration-hub). Set by the
    /// coordinator before `show`; picked up when the panel's `LauncherView` is (re)built on each open.
    var aiAvailability: AICanvasAvailability?

    private var panel: SwitcherPanel?
    private var bands: [ContextBand] = []
    private var dwell: Double = 0.5
    /// Shared with the wizard's hold-to-continue (Overlay/DwellArmDriver.swift) so the taught
    /// charge and the real charge are one implementation.
    private let dwellDriver = DwellArmDriver()

    // Held-in-zone auto-repeat state (per axis: −1 / 0 / +1; horizontal steps items/bands, vertical
    // steps rows). Driven by the recognizer's positional held-zone signal (change `positional-navigation`,
    // D3/D4), not a physical trackpad edge. A single timer advances both axes; its cadence follows the
    // eased dwell curve (`RepeatCadence`).
    private var edgeTimer: DispatchSourceTimer?
    private var edgeDX = 0
    private var edgeDY = 0
    /// Seconds the current held offset has dwelt (accumulated scheduled intervals) — drives the eased
    /// auto-repeat curve. Reset when the held direction changes or auto-repeat stops.
    private var edgeDwellElapsed: Double = 0
    /// Eased auto-repeat tunables (change `positional-navigation`, D4), pushed from settings on `show`:
    /// the first step is immediate (the recognizer's outer-crossing), the second after `repeatInitialDelay`,
    /// then the interval eases toward `repeatFloor` over `repeatRampTime` of dwell.
    var repeatInitialDelay: Double = 0.22
    var repeatFloor: Double = 0.03
    var repeatRampTime: Double = 1.2
    /// Deliberate horizontal steps required before a clipboard pin / previous-band action fires. Set
    /// from settings on `show`; pushed into the model so pinning isn't twitchy.
    var clipboardPinSteps: Int = 3

    // MARK: - Show / navigate

    func show(bands: [ContextBand], startBand: Int, startColumn: Int, dwell: Double,
              clipboardBandIndex: Int? = nil,
              filesBandIndex: Int? = nil, filesColumn: FilesColumnController? = nil) {
        self.bands = bands
        self.dwell = dwell
        model.dwell = dwell
        model.onPinToggle = onTogglePin
        model.clipboardPinStepThreshold = clipboardPinSteps
        model.setBands(bands.map(\.items),
                       names: bands.map(\.name),
                       colors: bands.map(\.color),
                       icons: bands.map(\.resolvedIcon),
                       startBand: startBand,
                       column: startColumn,
                       clipboardBandIndex: clipboardBandIndex,
                       filesBandIndex: filesBandIndex,
                       filesColumn: filesColumn)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel)
        panel.orderFrontRegardless()
        manageDwell()
        // Publish the initial drill state. It engages only once focus is in the file column
        // (`filesDrillEngaged`): a SINGLE-band Files launcher lands on `.grid` (no band rail), so the drill
        // arms up front and the first horizontal swipe drills; a MULTI-band launcher lands on the band rail
        // (`.bands`), so the drill stays OFF until a horizontal step crosses in — a lift on the Files icon
        // dismisses like any other band (refinement 1).
        syncFilesDrillState()
        // Publish the initial search-focus state (false on open) so the panel starts non-key; a top-of-column
        // overflow later flips it key-interactive (refinement 5).
        syncFilesSearchInteractive()
    }

    /// Re-publish whether the Files directory **drill** is engaged so the coordinator can flip the
    /// recognizer's sustained Files-drill mode (`filesDrillActive`). The drill engages only once focus has
    /// crossed INTO the file column (`model.filesDrillEngaged` = Files current AND `focus == .grid`), NOT
    /// merely when the Files band is current: while the highlight rests on the Files band ICON (`.bands`) the
    /// band behaves like any other — a horizontal step crosses in, a vertical step switches bands, and a
    /// lift DISMISSES the launcher (refinement 1). So this is re-synced after every step (focus can cross
    /// without a band change), not only on band switches. Idempotent for the coordinator (it just sets a
    /// flag); tracks the last published value so a navigation that doesn't cross the engaged boundary doesn't
    /// churn the recognizer.
    private var filesDrillPublished = false
    private func syncFilesDrillState() {
        let active = model.filesDrillEngaged
        guard active != filesDrillPublished else { return }
        filesDrillPublished = active
        onFilesColumnStateChanged?(active)
    }

    /// Mirror the model's `filesSearchFocused` onto the panel's key state (refinement 5): when a top-of-
    /// column overflow focuses the Files search field the panel must go **key-interactive** (like the AI
    /// canvas) so keystrokes land in the field; when a step-down un-focuses it the panel resigns key again.
    /// The panel stays NON-ACTIVATING throughout — becoming key never activates this app (the captured front
    /// app keeps focus), and the drill gesture is recognized off the multitouch device, not window events.
    /// Tracks the last published value so it only flips on a real change. Called after every step path
    /// (where `filesSearchFocused` can change) and on show.
    private var filesSearchInteractivePublished = false
    private func syncFilesSearchInteractive() {
        let focused = model.filesSearchFocused
        guard focused != filesSearchInteractivePublished else { return }
        filesSearchInteractivePublished = focused
        setFilesSearchInteractive(focused)
    }

    /// Whether the cursor is on the left band-title list (where *vertical* travel switches bands). Lets
    /// the gesture recognizer apply the coarser context-step to the vertical band-switch axis there, and
    /// the finer item-step to everything else (horizontal crossing into the grid, grid stepping).
    var focusIsOnBandList: Bool { model.focus == .bands }

    /// Horizontal swipe step: cross between the band list and the grid, else move the grid cursor
    /// within its row (band switching now lives on the *vertical* axis of the band list).
    ///
    /// While the AI preview canvas is open the recognizer is in canvas-resolution mode and emits no grid
    /// steps (it routes swipes to `launcherCanvasResolve`), so this branch is a **defensive fallback**:
    /// should a horizontal step still arrive, a deliberate excursion discards (accumulated so a small
    /// jitter doesn't discard), matching the canvas's horizontal-swipe = discard semantics. Vertical
    /// scrubbing is inert in the canvas (there's nothing to navigate).
    func stepHorizontal(_ dir: Int) {
        if model.canvasActive {
            accumulateCanvasDiscard(dir)
            return
        }
        let bandBefore = model.currentBand
        model.stepHorizontal(dir)
        if model.currentBand != bandBefore { if let panel { layout(panel, animated: true) } }
        // Re-sync the drill state on EVERY step: a horizontal step can cross focus `.bands` → `.grid`
        // (engaging the Files drill) WITHOUT changing the band, so this can't be gated on a band change
        // (refinement 1). Idempotent — a no-op when the engaged state didn't change.
        syncFilesDrillState()
        // A LEFT-at-roots escape to the band rail clears any search focus; keep the panel's key state in
        // sync (idempotent — a no-op when nothing changed) (refinement 5).
        syncFilesSearchInteractive()
        manageDwell()
    }

    /// Vertical swipe step: switch the active band on the band list, else move between grid rows
    /// (which now clamps at row 0 — there's no header strip to rise onto).
    func stepVertical(_ dir: Int) {
        if model.canvasActive { return }   // the canvas isn't grid-navigable
        // Band switching now lives on the vertical axis (the band list), so re-size the panel here on a
        // band change — the width shifts when crossing into / out of the Clipboard band, and the frame
        // animates via the same path band switching used on the horizontal axis before. Height is stable
        // across bands (clamped to the taller pane within min/max), so this is just an animated re-fit.
        let bandBefore = model.currentBand
        model.stepVertical(dir)
        if model.currentBand != bandBefore { if let panel { layout(panel, animated: true) } }
        // A vertical step on the band rail switches bands (possibly off Files), which changes the engaged
        // state; re-sync unconditionally (idempotent) rather than only on a band change (refinement 1).
        syncFilesDrillState()
        // A vertical step in the Files column may focus/un-focus the search field (and a band switch clears
        // it); keep the panel's key state in sync either way (refinement 5).
        syncFilesSearchInteractive()
        manageDwell()
    }

    // MARK: - Files band (the recognizer's sustained Files-drill routes here)

    /// One depth step while the Files band is current (the recognizer's `filesDepth`): RIGHT (`dir > 0`)
    /// descends into the highlighted folder, LEFT ascends (or, at the roots list, escapes to the band
    /// list). The direction is already reverse-adjusted upstream, exactly like grid/clipboard horizontal
    /// travel; the model routes it to the directory drill because the Files band is current. Unlike a grid
    /// step this does NOT dwell-to-arm — a Files entry resolves on the drill's lift (`filesOpen` /
    /// `filesOpenWith`), not by charging an arm ring. A descend / ascend never changes the active band
    /// (still the Files band), so the panel size is stable across drilling — no re-fit needed.
    ///
    /// The one focus change here is the LEFT-at-roots ESCAPE: it crosses the cursor to the band rail
    /// (`focus == .bands`), which **disengages** the drill (`filesDrillEngaged` flips false). Re-sync so the
    /// recognizer leaves `filesDrillActive` the instant we land on the band icon — a lift there must then
    /// DISMISS the launcher, not open the highlighted entry (refinement 1).
    func filesDepth(_ dir: Int) {
        guard model.currentBandIsFiles else { return }
        model.stepHorizontal(dir)
        syncFilesDrillState()
        // A LEFT-at-roots escape (the one focus change here) crosses to the band rail and clears search
        // focus; mirror that onto the panel's key state so the field resigns (refinement 5).
        syncFilesSearchInteractive()
    }

    /// One highlight step while the Files band is current (the recognizer's `filesHighlight`): UP
    /// (`dir > 0`) moves toward the top, DOWN toward the bottom (reverse-adjusted upstream). An up-step at
    /// the top of the column overflows into a focus-search request inside the model; a down-step un-focuses
    /// the search field (refinement 5). No dwell-to-arm (see `filesDepth`). The fixed container height
    /// (refinement 3) is stable across rows — the list scrolls inside to follow the highlight — so no panel
    /// re-fit is needed. The drill is re-synced anyway (idempotent), matching the other step paths.
    func filesHighlight(_ dir: Int) {
        guard model.currentBandIsFiles else { return }
        model.stepVertical(dir)
        syncFilesDrillState()
        // A top-of-column up-overflow focuses the search field, a down-step un-focuses it — mirror that onto
        // the panel's key state so keystrokes land in (and leave) the field (refinement 5).
        syncFilesSearchInteractive()
    }

    /// The current Files highlight the recognizer's resolving lift acts on (open / Open-With), read off the
    /// navigator. Nil when the Files band isn't current or the column is empty (the coordinator then has
    /// nothing to open).
    var filesHighlightedEntry: FileEntry? {
        guard model.currentBandIsFiles else { return nil }
        return model.filesColumn?.highlightedEntry
    }

    /// Deliberate horizontal travel within the canvas accumulates toward one discard (mirrors the
    /// Clipboard band's deliberate-excursion threshold so a tiny wobble never discards). Fallback path —
    /// the primary discard is the recognizer's horizontal resolution swipe (`discardCanvas`).
    private var canvasDiscardAccum = 0
    private func accumulateCanvasDiscard(_ dir: Int) {
        guard dir != 0 else { return }
        // Reset the accumulator if the direction reverses, so back-and-forth never silently sums.
        if (canvasDiscardAccum > 0) != (dir > 0) { canvasDiscardAccum = 0 }
        canvasDiscardAccum += dir
        if abs(canvasDiscardAccum) >= max(1, clipboardPinSteps) {
            canvasDiscardAccum = 0
            discardCanvas()
        }
    }

    /// Lift: fire the armed item, else dismiss. Returns whether something fired.
    ///
    /// Three cases:
    /// 1. The AI preview canvas is already open → a lift is a **no-op** (returns true). The fingers are
    ///    already up from the firing lift, so the canvas is resolved by a FRESH four-finger swipe instead:
    ///    a DOWN swipe commits (`resolveCanvasCommit`), a horizontal swipe discards (`discardCanvas`). A
    ///    stray re-lift must never lose the result, so it does nothing here.
    /// 2. An armed **AI command** item is lifted → **open the canvas** and begin the command WITHOUT
    ///    dismissing (the exception to the order-out-before-fire rule). The overlay stays visible and
    ///    non-activating; a fresh DOWN swipe then commits, a horizontal swipe discards.
    /// 3. Any other armed item → the existing path: order the panel out BEFORE firing (so a
    ///    Space-switching action doesn't drag the panel onto the destination Space), then fire.
    @discardableResult
    func end() -> Bool {
        dwellDriver.cancel()

        // Case 1: a lift while the canvas is open is a NO-OP. After the firing lift (case 2) the fingers
        // are already up, so the canvas is resolved by a FRESH four-finger swipe — horizontal = discard,
        // DOWN = apply (`launcherCanvasResolve` → `discardCanvas` / `resolveCanvasCommit`) — not by
        // lifting. Leaving the canvas up lets the user swipe to decide (a stray lift never loses it).
        if model.canvasActive { return true }

        // Files DRILL: a lift is owned by the recognizer's Files-drill resolution (`filesOpen` /
        // `filesOpenWith` / `filesDiscard`), which holds the defusable open with the panel STILL VISIBLE
        // (mirroring the AI canvas's order-out exception, design D7). Should a lift reach here while the drill
        // is engaged (focus IN the column), do NOT hide-before-fire — that would tear the navigator down
        // mid-resolution and reset the drill. Leave the panel up; the drill path resolves it.
        //
        // Gate on `filesDrillEngaged` (Files current AND focus `.grid`), NOT on `currentBandIsFiles`: while the
        // highlight rests on the Files band ICON (`.bands`) the drill is OFF, the recognizer routes the lift
        // here through the normal launcher end path, and the band must behave like any other — a lift DISMISSES
        // (refinement 1). The band icon never arms (`manageDwell` disarms on `.bands`), so falling through
        // hits the unarmed `hide(); return false` below: a clean dismiss.
        if model.filesDrillEngaged { return true }

        guard model.armed,
              bands.indices.contains(model.currentBand),
              bands[model.currentBand].items.indices.contains(model.selectedIndex) else { hide(); return false }
        let band = bands[model.currentBand]
        let item = band.items[model.selectedIndex]

        // Case 2: an AI command opens the streaming preview canvas instead of completing on lift. The
        // panel is NOT ordered out (the canvas needs it visible); `onFire` routes to the executor.
        if case let .aiCommand(command) = item.kind {
            endEdgeAutoScroll()
            canvasDiscardAccum = 0
            model.enterCanvas(command)
            onCanvasStateChanged?(true)   // → recognizer enters canvas-resolution mode (swipe to resolve)
            if let panel { layout(panel, animated: true) }   // grow to the canvas metrics
            onFire?(item, band)   // fires the executor synchronously → sets its state (.unavailable / .loadingModel)
            // The canvas is interactive for its WHOLE life (every AI command, every state), so the user
            // can SCROLL the streamed thinking / response and TAP the language pill or the "Thinking"
            // disclosure. The front app gets no scroll/click while the canvas is open.
            //
            // This is SAFE: the panel is a `.nonactivatingPanel`, so becoming key here never activates
            // *this* app (the captured front app stays the active app); the four-finger swipe-to-resolve
            // is recognized off the MULTITOUCH device (touch frames → `trackCanvasResolution`), NOT from
            // window mouse/scroll events, so commit (down) / discard (horizontal) keep working while the
            // panel is interactive; and write-back re-activates the captured app on commit. Reset is
            // implicit on `hide()` (the panel is destroyed + recreated pass-through per open).
            setCanvasInteractive(true)
            return true
        }

        // Case 3: every other kind keeps the order-out-before-fire rule exactly as before.
        // Dismiss the panel BEFORE firing. The panel is `.canJoinAllSpaces`, so a Space-switching
        // action (Next/Previous Space) fired first would carry the still-visible panel onto the
        // destination Space; ordering it out first lets the WindowServer drop it before the switch.
        hide()
        onFire?(item, band)
        return true
    }

    /// Discard the open AI preview canvas (a horizontal swipe / cancel gesture): cancel any in-flight
    /// generation, write nothing, and dismiss the overlay. A no-op when the canvas isn't open.
    func discardCanvas() {
        guard model.canvasActive else { return }
        onDiscardCanvas?()
        hide()
    }

    /// Apply the AI preview canvas's result (a four-finger DOWN swipe — "bring it into the document"):
    /// route the ready in-place result / confirmed task per the command's output target, then dismiss.
    /// Only commits when the executor is in a committable state — a down swipe while still loading or
    /// streaming is IGNORED (the user waits; only a horizontal swipe discards mid-flight). No-op when the
    /// canvas isn't open.
    func resolveCanvasCommit() {
        guard model.canvasActive else { return }
        guard executor?.state.isCommittable ?? true else { return }   // not ready yet → wait, don't commit
        onCommitCanvas?()
        hide()
    }

    func cancel() {
        dwellDriver.cancel()
        // A hard cancel (gesture abandoned, disable, sleep) while the canvas is open must also stop any
        // in-flight generation and write nothing — same as a discard swipe.
        if model.canvasActive { onDiscardCanvas?() }
        hide()
    }

    func hide() {
        dwellDriver.cancel()
        endEdgeAutoScroll()
        canvasDiscardAccum = 0
        let wasCanvas = model.canvasActive
        model.exitCanvas()
        model.disarm()
        if wasCanvas { onCanvasStateChanged?(false) }   // → recognizer leaves canvas-resolution mode
        // Leave the Files-drill mode too: the overlay is going away, so the recognizer must return to the
        // normal launcher latch (a fresh four-finger swipe re-opens the launcher, not a stale drill).
        if filesDrillPublished { filesDrillPublished = false; onFilesColumnStateChanged?(false) }
        // Reset the search-interactive latch (the panel is destroyed below; the next `show` recreates it
        // non-key + pass-through). No panel flip needed here — the window is about to be torn down.
        filesSearchInteractivePublished = false
        // TODO(files-band, tasks 11.2/11.3 — recede-on-leave exit): the Files navigator currently closes
        // hard (the snap below) rather than receding its content out. Animating the BubbleMorph out before
        // the panel goes away is intentionally NOT done here, because it would conflict with two invariants:
        //  (1) the ghost-panel teardown below MUST be synchronous — deferring `orderOut`/`close` behind an
        //      exit animation re-opens the verified ghost-on-Space-switch bug (a Next-Space ⌃→ processes
        //      before a delayed close flushes), the regression this method is explicitly guarding; and
        //  (2) it needs a handshake that does not exist yet — a published `closing` flag on `LauncherModel`
        //      for `FilesBandView` to drive its BubbleMorph exit off, plus a completion callback to tear the
        //      panel down only after the morph settles. `FilesBandView` is authored in the parallel View
        //      change, so there is nothing to coordinate the exit with today.
        // When that seam lands, route a *resolving lift* (which already keeps the band visible per Stage 2)
        // and a recede-on-leave through that flag and tear down in the completion, leaving the synchronous
        // close below as the fallback for the ghost-critical Space-switch paths.
        // Destroy the panel, don't just orderOut. The panel is `.canJoinAllSpaces`, and an orderOut'd
        // all-Spaces panel leaves a rendered GHOST on the Space you switch to (verified: a Space-switch
        // action left the launcher visible on the destination even though isVisible was already false).
        // Closing the window removes it from the WindowServer entirely; `show()` recreates it fresh on
        // the current Space.
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var currentBand: Int { model.currentBand }
    var bandCount: Int { model.bandCount }
    /// Whether the AI streaming preview canvas is currently open (the overlay is mid-AI-command). The
    /// coordinator reads this to gate a fresh launcher gesture so it commits/discards rather than
    /// re-showing the grid from scratch.
    var canvasActive: Bool { model.canvasActive }

    // MARK: - Held-in-zone auto-repeat (eased dwell curve)

    /// Auto-repeat stepping while a contact is held at a trackpad edge. `dx`/`dy` are −1 / 0 / +1 per
    /// axis (vertical switches bands on the band list / steps grid rows; horizontal crosses between the
    /// band list and the grid, then steps items). Horizontal is suppressed in the Clipboard band (there
    /// horizontal is the deliberate pin / cross-to-band-list action) AND in the Files band (there
    /// horizontal *drills* the directory tree — descend/ascend a level — so an edge auto-repeat would
    /// make the depth run away at the edge, stepping through folders the user can't see settle; each
    /// drill is a deliberate, discrete swipe, never an auto-fired one). Vertical auto-repeat is kept in
    /// both (it scrubs the current list / steps rows). When both axes are zero the timer stops. A step
    /// that doesn't move the selection (clamped at an end) does NOT reset the dwell, so holding at a dead
    /// edge still lets the current item arm and fire.
    func setEdgeAutoScroll(dx: Int, dy: Int) {
        // No grid auto-scroll while the canvas is open (it isn't grid-navigable); horizontal is the
        // discard swipe, handled by the recognizer's canvas resolution, not the edge timer.
        if model.canvasActive { endEdgeAutoScroll(); return }
        let hx = (model.currentBandIsClipboard || model.currentBandIsFiles) ? 0 : dx
        guard hx != edgeDX || dy != edgeDY else { return }
        edgeDX = hx
        edgeDY = dy
        edgeDwellElapsed = 0   // restart the eased acceleration curve when the held direction changes
        if edgeDX == 0, edgeDY == 0 {
            endEdgeAutoScroll()
        } else if edgeTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.setEventHandler { [weak self] in self?.edgeTick() }
            edgeTimer = timer
            rescheduleEdge()
            timer.resume()
        }
    }

    /// Stop auto-repeat (the offset returned to center, or the contact lifted).
    func endEdgeAutoScroll() {
        edgeTimer?.cancel()
        edgeTimer = nil
        edgeDX = 0
        edgeDY = 0
        edgeDwellElapsed = 0
    }

    private func edgeTick() {
        let beforeBand = model.currentBand, beforeIndex = model.selectedIndex, beforeFocus = model.focus
        if edgeDX != 0 { model.stepHorizontal(edgeDX) }
        if edgeDY != 0 { model.stepVertical(edgeDY) }
        let moved = model.currentBand != beforeBand || model.selectedIndex != beforeIndex || model.focus != beforeFocus
        if moved {
            if model.currentBand != beforeBand { if let panel { layout(panel, animated: true) } }
            // Re-sync the drill on a band OR focus change (auto-repeat can cross focus `.bands` ⇄ `.grid`
            // just like a manual step) — idempotent, so harmless when nothing relevant changed (refinement 1).
            if model.currentBand != beforeBand || model.focus != beforeFocus { syncFilesDrillState() }
            // Vertical edge auto-repeat scrubs the Files list; a top-of-column overflow focuses search (and a
            // down-step un-focuses it), so keep the panel's key state in sync as it scrubs (refinement 5).
            syncFilesSearchInteractive()
            manageDwell()   // a real move resets the dwell (so auto-repeat never arms mid-scroll)
        }
        rescheduleEdge()
    }

    /// Schedule the next auto-repeat tick along the eased dwell curve (change `positional-navigation`,
    /// D4): the interval shortens from `repeatInitialDelay` toward `repeatFloor` as the held offset
    /// dwells. `edgeDwellElapsed` accumulates the scheduled intervals so the curve advances by real
    /// elapsed time. The first schedule (dwell = 0) waits `repeatInitialDelay` — the immediate first
    /// step already fired from the recognizer's outer-threshold crossing.
    private func rescheduleEdge() {
        guard let timer = edgeTimer else { return }
        let interval = RepeatCadence.interval(dwellElapsed: edgeDwellElapsed,
                                              initialDelay: repeatInitialDelay,
                                              floor: repeatFloor,
                                              rampTime: repeatRampTime)
        timer.schedule(deadline: .now() + interval)
        edgeDwellElapsed += interval
    }

    /// After any navigation step: arm the selected app (restart dwell) when the cursor is on a grid
    /// item; disarm when it's on the band list (band titles don't fire).
    private func manageDwell() {
        dwellDriver.cancel()
        if model.focus == .grid, model.selectedItem != nil {
            startDwell()
        } else {
            model.disarm()
        }
    }

    // MARK: - Dwell-to-arm

    /// Begin charging the selected item: the ring fills over `dwell`, then `arm()` locks it.
    private func startDwell() {
        guard model.selectedItem != nil else { dwellDriver.cancel(); model.disarm(); return }
        model.beginArming()
        dwellDriver.charge(after: dwell) { [weak self] in self?.arm() }
    }

    private func arm() {
        guard model.arming else { return }
        model.setArmed()
        // Best-effort haptic tick (S-OQ1). Harmless if the Taptic Engine doesn't actuate; the
        // charge-ring is the primary, always-present arm signal.
        DwellArmDriver.hapticTick()
    }

    // MARK: - Panel

    /// Make the panel clickable + key-capable while the canvas shows a control that needs the mouse —
    /// the AI "unavailable" Enable / Download / model-picker controls, OR the in-canvas language
    /// dropdown shown for a translate-style command (a runtime-parameter command). Otherwise the panel
    /// stays pass-through (gesture-only). Reset implicitly on `hide()` (the panel is destroyed and
    /// recreated per open).
    ///
    /// This is SAFE for the captured front app's focus: the panel is a `.nonactivatingPanel`, so
    /// becoming key here never activates *this* app; the four-finger swipe-to-resolve is recognized off
    /// the multitouch device (not window mouse events), so it keeps working while the panel is
    /// interactive; and write-back re-activates the captured app on commit (`SelectionService` calls
    /// `app.activate` + PID-targeted AX / key events), so the destination's focus is restored.
    private func setCanvasInteractive(_ on: Bool) {
        guard let panel else { return }
        panel.ignoresMouseEvents = !on
        panel.keyInteractive = on
        if on { panel.makeKeyAndOrderFront(nil) }
    }

    /// Make the panel key-capable while the Files search field is focused so keystrokes land in it
    /// (refinement 5) — the keyboard analogue of `setCanvasInteractive`, driven by `model.filesSearchFocused`
    /// via `syncFilesSearchInteractive`. Unlike the canvas this does NOT flip `ignoresMouseEvents`: the
    /// Files navigator is gesture-driven (the drill needs the panel to keep ignoring the mouse), and a key
    /// window routes keystrokes to its first responder regardless of mouse hit-testing — so only the key
    /// state changes. On → become key so SwiftUI's `@FocusState` can make the `TextField` first responder;
    /// off → resign key-capability and drop the first responder so the field loses focus (the highlight
    /// clears). Becoming key never activates this app (the panel is `.nonactivatingPanel`), so the captured
    /// front app stays frontmost. Reset implicitly on `hide()` (the panel is destroyed + recreated per open).
    private func setFilesSearchInteractive(_ on: Bool) {
        guard let panel else { return }
        panel.keyInteractive = on
        if on {
            panel.makeKeyAndOrderFront(nil)
        } else {
            // Drop the field's first responder so it loses focus; with `keyInteractive` now false the panel
            // can no longer become key, so the next event cycle treats it as the non-key gesture overlay again.
            panel.makeFirstResponder(nil)
        }
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: SwitcherLayout.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false   // ARC owns it; close() must not also release (we nil it)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        // NOT `.canJoinAllSpaces`: an all-Spaces panel leaves a ghost on the Space a Next-Space action
        // switches to (and `close()` doesn't flush before the ⌃→ is processed). The panel is recreated
        // fresh on every `show()` (see `hide()`), so it is created on — and stays bound to — only the
        // current Space, which makes it impossible for it to appear on the destination Space.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: LauncherView(model: model, executor: executor,
                                                                 availability: aiAvailability))
        return panel
    }

    private func layout(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        // Master-detail shell: a left band-title list (only when there's more than one band) plus the
        // right content pane (the icon grid, or the Clipboard band's larger metrics). Width is the band
        // column + the content width; height is the taller of the two panes clamped to the window's
        // min/max bounds, so switching bands never jitters the frame (each pane scrolls inside). The AI
        // preview canvas is a full-surface replacement and keeps its own (larger) metrics. Both axes are
        // clamped to the screen.
        let width: CGFloat
        let height: CGFloat
        if model.canvasActive {
            // The canvas owns the whole surface (no band list) — unchanged sizing path.
            width = min(ClipboardBandLayout.containerWidth, frame.width - SwitcherLayout.sideMargin * 2)
            height = min(ClipboardBandLayout.containerHeight, frame.height - 100)
        } else {
            // Content pane width: the Clipboard band's master-detail width, the Files band's bounded
            // column-navigator width (the FIXED Clipboard-sized container — refinement 3, constant at any
            // depth and any column setting), else the icon-grid width.
            let contentWidth: CGFloat
            if model.currentBandIsClipboard {
                contentWidth = ClipboardBandLayout.containerWidth
            } else if model.currentBandIsFiles {
                // A FIXED container equal to the Clipboard band's exact width — it never resizes on crossing
                // in or changing depth; the current-folder list scrolls inside instead (refinement 3).
                contentWidth = FilesBandLayout.containerWidth
            } else {
                contentWidth = LauncherGridLayout.containerWidth
            }
            // The left band column (only when there's a choice of bands) is a fixed-width icon strip.
            let bandColumn = model.bandCount > 1 ? LauncherGridLayout.bandColumnWidth : 0
            width = min(bandColumn + contentWidth, frame.width - SwitcherLayout.sideMargin * 2)

            // Height is the LARGER of the active band's content demand — the icon grid's item rows,
            // the Clipboard band's taller detail pane, or the Files navigator's row-count height — and
            // the band-icon list's demand, clamped to the window's min/max. The list term matters with
            // many bands: its icons are fixed-size, so sizing from the content alone re-stretches the
            // container a beat after each band switch (fit the rows, then grow for the list — the
            // mid-move jitter). One max() computation sizes the frame once per switch, stable across
            // short bands.
            let bandListWanted = LauncherGridLayout.bandListHeight(bandCount: model.bandCount)
            let wanted: CGFloat
            if model.currentBandIsClipboard {
                wanted = min(max(max(ClipboardBandLayout.containerHeight, bandListWanted), LauncherGridLayout.minHeight),
                             LauncherGridLayout.maxHeight)
            } else if model.currentBandIsFiles {
                // A FIXED container height equal to the Clipboard band's exact height — no per-density and
                // no per-depth variation (refinement 3). A folder taller than the fixed row area scrolls
                // inside (the view follows the highlight); the frame never grows for it. Still take the max
                // with the band-icon list so a tall band rail isn't clipped, clamped to the window bounds.
                let filesWanted = FilesBandLayout.containerHeight
                wanted = min(max(max(filesWanted, bandListWanted), LauncherGridLayout.minHeight),
                             LauncherGridLayout.maxHeight)
            } else {
                wanted = LauncherGridLayout.windowHeight(itemCount: model.items.count, bandCount: model.bandCount)
            }
            height = min(wanted, frame.height - 100)
        }

        // Round to whole points so the window never gets a fractional frame the WindowServer would snap
        // to a pixel boundary (the `* 0.62` anchor otherwise yields a fractional y).
        let x = (frame.minX + (frame.width - width) / 2).rounded()
        let y = (frame.minY + (frame.height - height) * 0.62).rounded()   // a little above centre
        let rect = NSRect(x: x, y: y, width: width.rounded(), height: height.rounded())

        // Skip a no-op re-fit: switching between same-size bands yields the same rect, and animating to a
        // rect the window is already at makes the panel visibly twitch in place. Compare with a sub-point
        // tolerance (a real resize differs by tens of points) so pixel-snap residue never re-triggers it.
        let f = panel.frame
        if abs(f.minX - rect.minX) < 1, abs(f.minY - rect.minY) < 1,
           abs(f.width - rect.width) < 1, abs(f.height - rect.height) < 1 { return }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else {
            panel.setFrame(rect, display: true)
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
