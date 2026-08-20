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
    private var panel: SwitcherPanel?
    /// The ONE SwiftUI hosting view, reused across panels. The panel is destroyed per-hide (the
    /// ghost-on-Space-switch fix — see `hide()`), but rebuilding the hosting view with it meant a
    /// full SwiftUI graph construction on the main thread at trigger time on EVERY launcher open,
    /// and left each dead graph's `model` subscription to die with its panel — which any stray
    /// AppKit retention (in-flight animation, autorelease) turned into a permanent extra observer
    /// fanning out per gesture tick. One graph, one subscription, for the process lifetime.
    private var hosting: NSHostingView<LauncherView>?
    private var bands: [ContextBand] = []
    private var dwell: Double = 0.5
    /// Shared with the wizard's hold-to-continue (Overlay/DwellArmDriver.swift) so the taught
    /// charge and the real charge are one implementation.
    private let dwellDriver = DwellArmDriver()

    // Edge-triggered auto-repeat state (per axis: −1 / 0 / +1; horizontal steps items/bands, vertical
    // steps rows). A single timer advances both axes each tick.
    private var edgeTimer: DispatchSourceTimer?
    private var edgeDX = 0
    private var edgeDY = 0
    private var edgeTicks = 0
    /// Acceleration sensitivity (≥1); higher accelerates faster. Set from settings on `show`.
    var edgeAcceleration: Double = 1.0
    /// Deliberate horizontal steps required before a clipboard **pin** (RIGHT) fires. Set from settings
    /// on `show`; pushed into the model so pinning isn't twitchy. (Left-exit from the clipboard band is
    /// a single quick step, not gated by this.)
    var clipboardPinSteps: Int = 2

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
    func stepHorizontal(_ dir: Int) {
        let bandBefore = model.currentBand
        model.stepHorizontal(dir)
        if model.currentBand != bandBefore { if let panel { layout(panel, animated: true) } }
        manageDwell()
    }

    /// Vertical swipe step: switch the active band on the band list, else move between grid rows
    /// (which now clamps at row 0 — there's no header strip to rise onto).
    func stepVertical(_ dir: Int) {
        // Band switching now lives on the vertical axis (the band list), so re-size the panel here on a
        // band change — the width shifts when crossing into / out of the Clipboard band, and the frame
        // animates via the same path band switching used on the horizontal axis before. Height is stable
        // across bands (clamped to the taller pane within min/max), so this is just an animated re-fit.
        let bandBefore = model.currentBand
        model.stepVertical(dir)
        if model.currentBand != bandBefore { if let panel { layout(panel, animated: true) } }
        manageDwell()
    }

    /// Lift: fire the armed item, else dismiss. Returns whether something fired.
    ///
    /// The panel is ordered out BEFORE firing (so a Space-switching action doesn't drag the panel onto
    /// the destination Space), then the armed item fires.
    @discardableResult
    func end() -> Bool {
        dwellDriver.cancel()

        guard model.armed,
              bands.indices.contains(model.currentBand),
              bands[model.currentBand].items.indices.contains(model.selectedIndex) else { hide(); return false }
        let band = bands[model.currentBand]
        let item = band.items[model.selectedIndex]

        // Dismiss the panel BEFORE firing. The panel would otherwise be carried onto the destination
        // Space by a Space-switching action (Next/Previous Space); ordering it out first lets the
        // WindowServer drop it before the switch.
        hide()
        onFire?(item, band)
        return true
    }

    func cancel() {
        dwellDriver.cancel()
        hide()
    }

    func hide() {
        dwellDriver.cancel()
        endEdgeAutoScroll()
        model.disarm()
        // Destroy the panel, don't just orderOut. An orderOut'd panel can leave a rendered GHOST on the
        // Space you switch to (verified: a Space-switch action left the launcher visible on the
        // destination even though isVisible was already false). Closing the window removes it from the
        // WindowServer entirely; `show()` recreates it fresh on the current Space.
        // The hosting view is detached FIRST so the reusable SwiftUI graph deterministically survives
        // the window's death (see `hosting`).
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var currentBand: Int { model.currentBand }
    var bandCount: Int { model.bandCount }

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
    /// horizontal is the deliberate pin / cross-to-band-list action). Vertical auto-repeat is kept
    /// everywhere. When both axes are zero the timer stops. A step that doesn't move the selection
    /// (clamped at an end) does NOT reset the dwell, so holding at a dead edge still lets the current
    /// item arm and fire.
    func setEdgeAutoScroll(dx: Int, dy: Int) {
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
            if model.currentBand != beforeBand { if let panel { layout(panel, animated: true) } }
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
        // Reuse the one SwiftUI graph across panel rebuilds (see `hosting`): the panel is disposable
        // (Space-binding), the graph is not (construction cost + model subscription).
        let hosting = self.hosting ?? NSHostingView(rootView: LauncherView(model: model))
        self.hosting = hosting
        panel.contentView = hosting
        return panel
    }

    private func layout(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        // Master-detail shell: a left band-title list (only when there's more than one band) plus the
        // right content pane (the icon grid, or the Clipboard band's larger metrics). Width is the band
        // column + the content width; height is the taller of the two panes clamped to the window's
        // min/max bounds, so switching bands never jitters the frame (each pane scrolls inside). Both
        // axes are clamped to the screen.
        let contentWidth: CGFloat = model.currentBandIsClipboard
            ? ClipboardBandLayout.containerWidth
            : LauncherGridLayout.containerWidth
        // The left band column (only when there's a choice of bands) is a fixed-width icon strip.
        let bandColumn = model.bandCount > 1 ? LauncherGridLayout.bandColumnWidth : 0
        let width = min(bandColumn + contentWidth, frame.width - SwitcherLayout.sideMargin * 2)

        // Height is the LARGER of the active band's content demand — the icon grid's item rows or
        // the Clipboard band's taller detail pane — and the band-icon list's demand, clamped to the
        // window's min/max. The list term matters with many bands: its icons are fixed-size, so
        // sizing from the content alone re-stretches the container a beat after each band switch
        // (fit the rows, then grow for the list — the mid-move jitter). One max() computation sizes
        // the frame once per switch, stable across short bands.
        let bandListWanted = LauncherGridLayout.bandListHeight(bandCount: model.bandCount)
        let wanted: CGFloat
        if model.currentBandIsClipboard {
            wanted = min(max(max(ClipboardBandLayout.containerHeight, bandListWanted), LauncherGridLayout.minHeight),
                         LauncherGridLayout.maxHeight)
        } else {
            wanted = LauncherGridLayout.windowHeight(itemCount: model.items.count, bandCount: model.bandCount)
        }
        let height = min(wanted, frame.height - 100)

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
