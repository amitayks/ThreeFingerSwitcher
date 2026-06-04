import AppKit
import SwiftUI

/// Owns the non-activating overlay panel. The panel never becomes key or main and ignores
/// the mouse, so the previously focused window stays the raise target and the overlay is
/// never itself a switch candidate.
@MainActor
final class OverlayController {
    let model = SwitcherModel()
    private var panel: SwitcherPanel?

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .popUpMenu (above normal windows + menu bar) rather than the screen-saver band, and no
        // .stationary (Exposé-exempt) — both perturb the WindowServer's focus/Space arbitration.
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return panel
    }

    func show(rows: [[WindowInfo]], labels: [String], startRow: Int, column: Int) {
        model.setRows(rows, labels: labels, startRow: startRow, column: column)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel)
        panel.orderFrontRegardless()
    }

    func updateColumn(_ index: Int) {
        model.setColumn(index)
    }

    /// Switch the displayed Space-row; the card count changes, so re-layout the panel width
    /// (animated, so the container smoothly resizes as it switches Spaces).
    func updateRow(_ row: Int) {
        model.setRow(row)
        if let panel { layout(panel, animated: true) }
    }

    var currentRow: Int { model.currentRow }
    var rowCount: Int { model.rowCount }
    var selectedColumn: Int { model.selectedIndex }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Size the panel to the card content and centre it horizontally on the active screen.
    /// When the content fits, the panel hugs the cards (so the rounded container wraps them and
    /// appears centred); when it overflows, the panel clamps to the available width and scrolls.
    private func layout(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        let contentWidth = SwitcherLayout.contentWidth(for: model.windows.count, withRowIndicator: model.rowCount > 1)
        let maxWidth = frame.width - SwitcherLayout.sideMargin * 2
        let width = min(contentWidth, maxWidth)
        model.overflow = contentWidth > maxWidth

        let height = SwitcherLayout.panelHeight
        let x = frame.minX + (frame.width - width) / 2
        let y = frame.minY + frame.height * 0.18
        let rect = NSRect(x: x, y: y, width: width, height: height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
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

/// NSPanel subclass that refuses key/main so it can never steal focus.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
