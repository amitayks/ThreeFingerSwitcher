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
    private var armWork: DispatchWorkItem?

    // Edge-triggered auto-repeat state (per axis: −1 / 0 / +1; horizontal steps items/bands, vertical
    // steps rows). A single timer advances both axes each tick.
    private var edgeTimer: DispatchSourceTimer?
    private var edgeDX = 0
    private var edgeDY = 0
    private var edgeTicks = 0
    /// Acceleration sensitivity (≥1); higher accelerates faster. Set from settings on `show`.
    var edgeAcceleration: Double = 1.0
    /// Deliberate horizontal steps required before a clipboard pin / previous-band action fires. Set
    /// from settings on `show`; pushed into the model so pinning isn't twitchy.
    var clipboardPinSteps: Int = 3

    // MARK: - Show / navigate

    func show(bands: [ContextBand], startBand: Int, startColumn: Int, dwell: Double,
              clipboardBandIndex: Int? = nil) {
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
                       clipboardBandIndex: clipboardBandIndex)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel)
        panel.orderFrontRegardless()
        manageDwell()
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
        if model.currentBand != bandBefore, let panel { layout(panel, animated: true) }
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
        if model.currentBand != bandBefore, let panel { layout(panel, animated: true) }
        manageDwell()
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
        armWork?.cancel(); armWork = nil

        // Case 1: a lift while the canvas is open is a NO-OP. After the firing lift (case 2) the fingers
        // are already up, so the canvas is resolved by a FRESH four-finger swipe — horizontal = discard,
        // DOWN = apply (`launcherCanvasResolve` → `discardCanvas` / `resolveCanvasCommit`) — not by
        // lifting. Leaving the canvas up lets the user swipe to decide (a stray lift never loses it).
        if model.canvasActive { return true }

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
        armWork?.cancel(); armWork = nil
        // A hard cancel (gesture abandoned, disable, sleep) while the canvas is open must also stop any
        // in-flight generation and write nothing — same as a discard swipe.
        if model.canvasActive { onDiscardCanvas?() }
        hide()
    }

    func hide() {
        armWork?.cancel(); armWork = nil
        endEdgeAutoScroll()
        canvasDiscardAccum = 0
        let wasCanvas = model.canvasActive
        model.exitCanvas()
        model.disarm()
        if wasCanvas { onCanvasStateChanged?(false) }   // → recognizer leaves canvas-resolution mode
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

    // MARK: - Edge-triggered auto-repeat

    /// Pure: the auto-repeat interval for a given tick — ramps from ~0.18s down toward a 0.03s floor
    /// as ticks accumulate (faster with higher `acceleration`), so stepping speeds up at the edge.
    nonisolated static func edgeInterval(tick: Int, acceleration: Double) -> Double {
        let base = 0.18, minInterval = 0.03
        let ramp = Double(tick) * 0.06 * max(0.5, acceleration)
        return max(minInterval, base / (1 + ramp))
    }

    /// Auto-repeat stepping while a contact is held at a trackpad edge. `dx`/`dy` are −1 / 0 / +1 per
    /// axis (vertical switches bands on the band list / steps grid rows; horizontal crosses between the
    /// band list and the grid, then steps items). Horizontal is suppressed in the Clipboard band (there
    /// horizontal is the deliberate pin / cross-to-band-list action). When
    /// both axes are zero the timer stops. A step that doesn't move the selection (clamped at an end)
    /// does NOT reset the dwell, so holding at a dead edge still lets the current item arm and fire.
    func setEdgeAutoScroll(dx: Int, dy: Int) {
        // No grid auto-scroll while the canvas is open (it isn't grid-navigable); horizontal is the
        // discard swipe, handled by the recognizer's canvas resolution, not the edge timer.
        if model.canvasActive { endEdgeAutoScroll(); return }
        let hx = model.currentBandIsClipboard ? 0 : dx
        guard hx != edgeDX || dy != edgeDY else { return }
        edgeDX = hx
        edgeDY = dy
        edgeTicks = 0   // restart the acceleration ramp when the edge direction changes
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

    /// Stop auto-repeat (contact left every edge, or lifted).
    func endEdgeAutoScroll() {
        edgeTimer?.cancel()
        edgeTimer = nil
        edgeDX = 0
        edgeDY = 0
        edgeTicks = 0
    }

    private func edgeTick() {
        let beforeBand = model.currentBand, beforeIndex = model.selectedIndex, beforeFocus = model.focus
        if edgeDX != 0 { model.stepHorizontal(edgeDX) }
        if edgeDY != 0 { model.stepVertical(edgeDY) }
        let moved = model.currentBand != beforeBand || model.selectedIndex != beforeIndex || model.focus != beforeFocus
        if moved {
            if model.currentBand != beforeBand, let panel { layout(panel, animated: true) }
            manageDwell()   // a real move resets the dwell (so auto-repeat never arms mid-scroll)
        }
        edgeTicks += 1
        rescheduleEdge()
    }

    private func rescheduleEdge() {
        guard let timer = edgeTimer else { return }
        timer.schedule(deadline: .now() + Self.edgeInterval(tick: edgeTicks, acceleration: edgeAcceleration))
    }

    /// After any navigation step: arm the selected app (restart dwell) when the cursor is on a grid
    /// item; disarm when it's on the band list (band titles don't fire).
    private func manageDwell() {
        armWork?.cancel(); armWork = nil
        if model.focus == .grid, model.selectedItem != nil {
            startDwell()
        } else {
            model.disarm()
        }
    }

    // MARK: - Dwell-to-arm

    /// Begin charging the selected item: the ring fills over `dwell`, then `arm()` locks it.
    private func startDwell() {
        armWork?.cancel()
        guard model.selectedItem != nil else { model.disarm(); return }
        model.beginArming()
        let work = DispatchWorkItem { [weak self] in self?.arm() }
        armWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func arm() {
        guard model.arming else { return }
        model.setArmed()
        // Best-effort haptic tick (S-OQ1). Harmless if the Taptic Engine doesn't actuate; the
        // charge-ring is the primary, always-present arm signal.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
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
            // Content pane width: the Clipboard band's master-detail width, else the icon-grid width.
            let contentWidth = model.currentBandIsClipboard
                ? ClipboardBandLayout.containerWidth
                : LauncherGridLayout.containerWidth
            // The left band column (only when there's a choice of bands) is a fixed-width icon strip.
            let bandColumn = model.bandCount > 1 ? LauncherGridLayout.bandColumnWidth : 0
            width = min(bandColumn + contentWidth, frame.width - SwitcherLayout.sideMargin * 2)

            // Height is driven solely by the active band's content — the icon grid's item rows, or the
            // Clipboard band's taller detail pane — clamped to the window's min/max. The band-title list
            // divides this same height evenly, so it never makes the window taller than the items do.
            let wanted = model.currentBandIsClipboard
                ? min(max(ClipboardBandLayout.containerHeight, LauncherGridLayout.minHeight), LauncherGridLayout.maxHeight)
                : LauncherGridLayout.windowHeight(itemCount: model.items.count)
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
