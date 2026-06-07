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

    private var panel: SwitcherPanel?
    private var bands: [ContextBand] = []
    private var dwell: Double = 0.5
    private var armWork: DispatchWorkItem?

    // MARK: - Show / navigate

    func show(bands: [ContextBand], startBand: Int, startColumn: Int, dwell: Double) {
        self.bands = bands
        self.dwell = dwell
        model.dwell = dwell
        model.setBands(bands.map(\.items),
                       names: bands.map(\.name),
                       colors: bands.map(\.color),
                       startBand: startBand,
                       column: startColumn)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel)
        panel.orderFrontRegardless()
        manageDwell()
    }

    /// Horizontal swipe step: switch batch on the headers row, else move the grid cursor.
    func stepHorizontal(_ dir: Int) {
        let bandBefore = model.currentBand
        model.stepHorizontal(dir)
        if model.currentBand != bandBefore, let panel { layout(panel, animated: true) }
        manageDwell()
    }

    /// Vertical swipe step: move between grid rows, rising onto / dropping from the headers row.
    func stepVertical(_ dir: Int) {
        model.stepVertical(dir)
        manageDwell()
    }

    /// Lift: fire the armed item, else dismiss. Returns whether something fired.
    @discardableResult
    func end() -> Bool {
        armWork?.cancel(); armWork = nil
        guard model.armed,
              bands.indices.contains(model.currentBand),
              bands[model.currentBand].items.indices.contains(model.selectedIndex) else { hide(); return false }
        let band = bands[model.currentBand]
        let item = band.items[model.selectedIndex]
        // Dismiss the panel BEFORE firing. The panel is `.canJoinAllSpaces`, so a Space-switching
        // action (Next/Previous Space) fired first would carry the still-visible panel onto the
        // destination Space; ordering it out first lets the WindowServer drop it before the switch.
        hide()
        onFire?(item, band)
        return true
    }

    func cancel() {
        armWork?.cancel(); armWork = nil
        hide()
    }

    func hide() {
        armWork?.cancel(); armWork = nil
        model.disarm()
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

    /// After any navigation step: arm the selected app (restart dwell) when the cursor is on a grid
    /// item; disarm when it's on the headers row (headers don't fire).
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
        panel.contentView = NSHostingView(rootView: LauncherView(model: model))
        return panel
    }

    private func layout(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        // Constant-width "Applications"-style container; height grows with the band's item count
        // up to a few rows, then the grid scrolls. Both axes are clamped to the screen.
        let width = min(LauncherGridLayout.containerWidth, frame.width - SwitcherLayout.sideMargin * 2)
        let wanted = LauncherGridLayout.containerHeight(forItemCount: model.items.count)
        let height = min(wanted, frame.height - 100)

        let x = frame.minX + (frame.width - width) / 2
        let y = frame.minY + (frame.height - height) * 0.62   // a little above centre
        let rect = NSRect(x: x, y: y, width: width, height: height)

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
