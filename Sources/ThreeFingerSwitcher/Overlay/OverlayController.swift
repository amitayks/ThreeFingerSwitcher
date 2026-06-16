import AppKit
import SwiftUI

/// Owns the non-activating overlay panel. The panel never becomes key or main and ignores
/// the mouse, so the previously focused window stays the raise target and the overlay is
/// never itself a switch candidate.
@MainActor
final class OverlayController {
    let model = SwitcherModel()
    private var panel: SwitcherPanel?

    /// Duration of the Space-switch reel slide; the thumbnail freeze (below) is held for the same span.
    static let slideDuration: TimeInterval = 0.34
    /// Pending flush of the per-slide thumbnail freeze, so a new switch can reschedule it (fast switching).
    private var unfreezeWork: DispatchWorkItem?

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
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return panel
    }

    /// Set the panel's stacking per show. Default: `.popUpMenu` (above normal windows + menu bar) and
    /// NO `.stationary` — both a higher band and `.stationary` perturb the WindowServer's focus/Space
    /// arbitration, so they're avoided on the common path. While Mission Control is open we must float
    /// ABOVE it, so we raise to the screen-saver band and add `.stationary` (Exposé-exempt) so MC
    /// doesn't pull the panel into the overview; this is short-lived — the commit dismisses MC and
    /// re-raises the window from a clean state.
    private func configure(_ panel: SwitcherPanel, aboveMissionControl: Bool) {
        if aboveMissionControl {
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        } else {
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    /// Build the panel + its `NSHostingView` and render them ONCE, off-screen, at app setup — so the
    /// FIRST user-triggered `show` is already "warm". The switcher's open gesture is continuous: the
    /// same swipe that opens the overlay immediately drains a burst of Space-switch `updateRow`s. On a
    /// cold, lazily created hosting view those `withAnimation` reel-offset retargets interpolate from a
    /// not-yet-committed state, so the reel looks frozen until the gesture stops — the bug that hit ONLY
    /// the first session, because the panel + its warm layer are retained from then on. Rendering once
    /// off-screen here gives Core Animation a committed presentation layer long before any trigger.
    /// Idempotent and cheap; a no-op once the panel exists.
    func prewarm() {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        // Far off-screen so nothing flashes; force a synchronous layout + display, then hide on the
        // next runloop so CA still gets a commit cycle for the rendered state.
        panel.setFrame(NSRect(x: -30000, y: -30000, width: 800, height: SwitcherLayout.panelHeight), display: true)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        DispatchQueue.main.async { [weak panel] in panel?.orderOut(nil) }
    }

    func show(rows: [[WindowInfo]], labels: [String], startRow: Int, column: Int,
              aboveMissionControl: Bool = false, rowSwitchingPending: Bool = false,
              windowScale: CGFloat = 1) {
        // The configurable window size scales the uniform-scale cap; set it before the rows so the
        // first grid solve already uses it.
        model.setMaxScale(SwitcherLayout.kMax * windowScale)
        model.setRows(rows, labels: labels, startRow: startRow, column: column)
        model.rowSwitchingPending = rowSwitchingPending
        let panel = self.panel ?? makePanel()
        self.panel = panel
        configure(panel, aboveMissionControl: aboveMissionControl)
        layout(panel)
        panel.orderFrontRegardless()
    }

    func updateColumn(_ index: Int) {
        model.setColumn(index)
    }

    /// Horizontal scrub: move the selection within the current visual row of the grid.
    func moveHorizontal(_ direction: Int, wrap: Bool) {
        model.moveHorizontal(direction, wrap: wrap)
    }

    /// Vertical scrub: move between visual rows; returns whether it crossed the grid's top/bottom edge
    /// (so the caller switches Space).
    func moveVertical(_ direction: Int) -> SwitcherModel.VerticalMove {
        model.moveVertical(direction)
    }

    /// Switch the displayed Space. The NSPanel is sized once to the whole reel's canvas (the largest
    /// Space) and never resizes on a switch; instead the SwiftUI container hugs the new Space and the
    /// reel offset moves, BOTH animated here in ONE explicit `withAnimation` transaction so they stay in
    /// sync. Driving it explicitly (not an implicit `.animation(value:)`) means a (re)show — which sets
    /// the row WITHOUT this wrapper — lands instantly with no appearance slide. The slide stays smooth
    /// because the caller freezes thumbnail updates for its duration (`beginSlideFreeze`): a mid-slide
    /// `setThumbnail` would otherwise re-render the body, re-apply the reel `.offset` non-animated, and
    /// SNAP the slide to place (the first-run bug where preview-bearing cards jump instead of sliding).
    func updateRow(_ row: Int) {
        withAnimation(.easeInOut(duration: Self.slideDuration)) {
            model.setRow(row)
        }
    }

    /// Buffer thumbnail updates for the duration of the Space-switch slide and flush them once it
    /// settles, so a capture landing mid-slide can't snap the animation (cards translate as a rigid
    /// group; the buffered frames cut in afterward). Re-entrant: a fast follow-up switch reschedules the
    /// flush. Call this AFTER seeding the new Space's cached thumbnails (those should be present for the
    /// slide); only the async captures that arrive later are frozen.
    func beginSlideFreeze() {
        model.freezeThumbnails()
        unfreezeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.flushThumbnails() }
        unfreezeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.slideDuration, execute: work)
    }

    var currentRow: Int { model.currentRow }
    var rowCount: Int { model.rowCount }
    var selectedColumn: Int { model.selectedIndex }

    func hide() {
        unfreezeWork?.cancel()
        unfreezeWork = nil
        model.flushThumbnails()   // never leave the overlay hidden with a frozen, half-applied set
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Size the panel to the whole reel's canvas — the LARGEST Space's solved grid — and place it
    /// centred on the active screen. A canvas target (a fraction of the visible frame) drives the
    /// uniform-scale solve; the panel then hugs the largest Space (width and height) so the canvas fits
    /// every Space and stays put while the reel moves between them. The solve uses the FIXED canvas
    /// target (never the hugged panel), so there is no size-feedback loop; a Space taller than the
    /// canvas clamps and is clipped within its reel cell.
    private func layout(_ panel: NSPanel, animated: Bool = false) {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }

        let hasIndicator = model.rowCount > 1
        let chromeW = 2 * SwitcherLayout.gridContainerPadding
            + (hasIndicator ? SwitcherLayout.rowIndicatorGutter : 0)
        let chromeH = 2 * SwitcherLayout.gridContainerPadding + SwitcherLayout.titleAreaHeight

        // Fixed canvas target the grid solves into (independent of the hugged panel — no feedback loop).
        let targetW = frame.width * SwitcherLayout.canvasWidthFraction - SwitcherLayout.sideMargin * 2
        let targetH = frame.height * SwitcherLayout.canvasHeightFraction
        let gridCanvas = CGSize(width: max(targetW - chromeW, 1), height: max(targetH - chromeH, 1))
        model.setCanvas(gridCanvas)

        // Hug the panel to the LARGEST Space's grid, clamped to the canvas target (so the reel cell
        // fits every Space and the panel never resizes on a switch).
        let content = model.maxContentSize
        let width = min(content.width + chromeW, targetW)
        let height = min(content.height, gridCanvas.height) + chromeH

        let x = frame.minX + (frame.width - width) / 2
        let y = frame.minY + (frame.height - height) * 0.55   // a little above centre, like the launcher
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

/// NSPanel subclass that refuses key/main so it can never steal focus — EXCEPT when `keyInteractive`
/// is set, which the launcher flips on for the AI "unavailable" canvas so its Enable/Download/model
/// controls are clickable. Being a `.nonactivatingPanel`, becoming key there does not activate the app (the
/// captured front app stays frontmost); the flag is reset/destroyed when the canvas dismisses. (The Files
/// navigator never needs this — it is purely gesture-driven and stays non-key throughout.)
final class SwitcherPanel: NSPanel {
    /// When true, the panel may become key so hosted controls (buttons/picker) receive clicks.
    var keyInteractive = false
    override var canBecomeKey: Bool { keyInteractive }
    override var canBecomeMain: Bool { false }
}
