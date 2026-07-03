import AppKit
import SwiftUI

/// Wires the notch home-zone rail together exactly like `DockPreviewController` (design §8): a passive
/// `GlobalCursorMonitor` (no Input Monitoring) feeds cursor points; while the rail is hidden geometry is
/// read only when the cursor is near the top-center zone (the `nearDockEdge` analogue — cheap idle); a
/// pure `NotchRevealModel` decides reveal/keep/dismiss (`now:` injected); a coarse re-feed timer advances
/// grace/relayout only while shown; teardown is **synchronous**. Gated by the agent-feature opt-in (when
/// off, the monitor isn't installed). The ambient needs-you glow rides its own slim non-activating glow
/// panel on the resting zone, present iff any session is `.needsYou`, cleared only when every needs-you
/// is addressed.
@MainActor
final class NotchHomeZoneController {
    private let overlay = NotchHomeZoneOverlayController()
    private let reveal = NotchRevealModel()
    private let cursor: CursorMonitor
    private let now: () -> TimeInterval

    /// The data source: the parked rows + their stored conversations (the scheduler/store seam).
    var sessionsProvider: () -> [ParkedSession] = { [] }
    /// Restore a session as the active canvas (handed to `ai-conversational-canvas`).
    var onRestore: ((AgentSessionID) -> Void)?
    /// Discard a parked session (cancel pending + remove).
    var onDiscard: ((AgentSessionID) -> Void)?

    private var enabled = false
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 0.12

    /// The ambient-glow panel — a slim, non-activating, click-through panel on the resting zone.
    private var glowPanel: NSPanel?
    private let glowState = GlowState()

    init(cursor: CursorMonitor? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.cursor = cursor ?? GlobalCursorMonitor()
        self.now = now
        overlay.onRestore = { [weak self] id in self?.handleRestore(id) }
        overlay.onDiscard = { [weak self] id in self?.onDiscard?(id) }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            cursor.onMove = { [weak self] point in self?.handleCursor(point) }
            cursor.start()
        } else {
            cursor.stop()
            cursor.onMove = nil
            dismiss(animated: false)             // immediate teardown when the feature is switched off
            tearDownGlow()
        }
    }

    /// Refresh the rail rows + the ambient glow from the current parked set (call after a scheduler
    /// advance / escalate). Updates the glow presence iff any session is `.needsYou`.
    func refresh() {
        let sessions = sessionsProvider()
        overlay.model.sessions = sessions
        let needsYou = sessions.contains { $0.state == .needsYou }
        glowState.isActive = needsYou
        if needsYou { ensureGlow() } else { tearDownGlow() }
    }

    // MARK: - Test seams (the rail view-model the overlay renders + the glow predicate)

    /// The rail rows the overlay currently renders (after the last `refresh`/reveal). Test-only read.
    var overlayModelSessionsForTest: [ParkedSession] { overlay.model.sessions }
    /// Whether the ambient needs-you glow is currently lit. Test-only read.
    var hasNeedsYouForTest: Bool { glowState.isActive }

    // MARK: - Cursor handling (edge-gated, mirrors DockPreviewController)

    private func handleCursor(_ point: CGPoint) {
        guard enabled, let m = metrics(for: point) else { return }
        let zone = zoneRectFor(m)
        // Edge-gate: only compute when something is shown or the cursor is near the top-center zone.
        guard overlay.isVisible || nearTopZone(point, zone: zone, metrics: m) else { return }

        let railFrame = overlay.isVisible ? overlay.frame : nil
        // The ONE contiguous live region (zone + connecting band + container, extended up into the notch
        // pixels) — so moving the cursor UP into the notch keeps the rail .shown (docks), never dismisses.
        let liveZone = liveZoneFor(m, zone: zone, rail: railFrame)
        let decision = reveal.feed(cursor: point, zoneRect: zone, railFrame: railFrame,
                                   liveZone: liveZone, now: now())

        switch decision {
        case .idle:
            if overlay.isVisible { dismiss() }
        case .dismiss:
            dismiss()
        case .reveal:
            overlay.model.sessions = sessionsProvider()
            // Set the attachment BEFORE showing so the view carves the notch / insets content correctly on
            // the very first frame (no flash of an un-carved rounded rect).
            overlay.model.attachment = attachmentFor(m)
            let rail = railRectFor(m, zone: zone)
            overlay.reveal(at: rail)            // spreads out of the notch on first show; repositions after
        }
        manageRefreshTimer()
    }

    private func handleRestore(_ id: AgentSessionID) {
        // Bug 4 (restore focus): dismiss the rail FIRST, then re-open the canvas. The rail's teardown is a
        // synchronous `orderOut` (ghost-on-Space-switch landmine — kept synchronous); doing it AFTER
        // `onRestore?` would order this app's panel out right after the restored canvas made itself key,
        // stealing first-responder back so Enter never reaches `executor.send`. Dismissing first leaves the
        // restored canvas the key window once `onRestore?` makes it key + orders it front.
        dismiss(animated: false)                 // immediate: the restored canvas must take focus cleanly
        onRestore?(id)
        refresh()                                // restoring may clear the last needs-you → clear glow
    }

    /// Dismiss the rail. `animated` (the default, used for the cursor-left grace-dismiss) recedes it back
    /// into the notch on the ease-in-out spread; `animated == false` (restore / feature-off) tears it down
    /// synchronously so focus/teardown are immediate (the ghost-on-Space-switch landmine path).
    private func dismiss(animated: Bool = true) {
        overlay.hide(animated: animated)
        manageRefreshTimer()
    }

    private func manageRefreshTimer() {
        // Pause the re-feed while an animated recede is in flight (isReceding) — otherwise each tick would
        // re-issue the dismiss and the recede would never complete.
        let wantTimer = overlay.isVisible && !overlay.isReceding
        if wantTimer, refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } else if !wantTimer, let t = refreshTimer {
            t.invalidate()
            refreshTimer = nil
        }
    }

    private func tick() {
        // Re-feed at the current cursor so grace advances without depending on move events.
        let point = NSEvent.mouseLocation
        handleCursor(point)
    }

    // MARK: - Geometry (top-center zone on the active screen; notch-attached OR tab-degraded)

    /// The active screen's metrics + the resolved physical notch box (nil ⇒ notchless/external → tab mode).
    /// The one place `NSScreen`'s notch geometry (`safeAreaInsets` + the aux menu-bar areas) is read; the
    /// pure `NotchHomeZoneAnchor` does the rest.
    private struct ScreenMetrics {
        let screen: NSScreen
        let notch: CGRect?
        var screenFrame: CGRect { screen.frame }
        var visibleFrame: CGRect { screen.visibleFrame }
        var safeAreaTop: CGFloat { screen.safeAreaInsets.top }
    }

    private func activeScreen(for point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func metrics(for point: CGPoint) -> ScreenMetrics? {
        guard let screen = activeScreen(for: point) else { return nil }
        let notch = NotchHomeZoneAnchor.notchRect(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeft: screen.auxiliaryTopLeftArea,
            auxRight: screen.auxiliaryTopRightArea)
        return ScreenMetrics(screen: screen, notch: notch)
    }

    private var zoneSize: CGSize {
        CGSize(width: NotchHomeZoneLayout.zoneWidth, height: NotchHomeZoneLayout.zoneHeight)
    }

    /// The reveal target: in attached mode a thin nub hugging the notch's bottom edge; else the honest
    /// top-center tab a margin below the menu bar.
    private func zoneRectFor(_ m: ScreenMetrics) -> CGRect {
        if let notch = m.notch {
            return NotchHomeZoneAnchor.attachedNubRect(size: zoneSize, notch: notch, screenFrame: m.screenFrame)
        }
        return NotchHomeZoneAnchor.zoneRect(size: zoneSize, visibleFrame: m.visibleFrame, safeAreaTop: m.safeAreaTop)
    }

    /// The revealed panel: in attached mode it merges into the notch (top at the physical top, content band
    /// below); else it hangs flush below the tab. Both hug their sessions via the shared content-fit solve.
    private func railRectFor(_ m: ScreenMetrics, zone: CGRect) -> CGRect {
        let solved = NotchHomeZoneLayout.solve(count: overlay.model.sessions.count, visibleFrame: m.visibleFrame)
        if let notch = m.notch {
            return NotchHomeZoneAnchor.attachedPanelRect(
                contentSize: solved.contentSize, notch: notch, screenFrame: m.screenFrame)
        }
        return NotchHomeZoneAnchor.railRect(zone: zone, size: solved.contentSize, visibleFrame: m.visibleFrame)
    }

    private func liveZoneFor(_ m: ScreenMetrics, zone: CGRect, rail: CGRect?) -> CGRect {
        if let notch = m.notch {
            return NotchHomeZoneAnchor.attachedLiveZone(nub: zone, panel: rail, notch: notch)
        }
        return NotchHomeZoneAnchor.liveZoneRect(zone: zone, rail: rail, visibleFrame: m.visibleFrame)
    }

    private func attachmentFor(_ m: ScreenMetrics) -> NotchAttachment {
        if let notch = m.notch {
            return .notch(cutout: CGSize(width: notch.width, height: notch.height))
        }
        return .tab
    }

    /// Edge-gate: the cursor is near the top-center resting zone OR anywhere in the contiguous live region
    /// (cheap idle, like `nearDockEdge`). Widened to cover the connecting band + the notch pixels above
    /// the zone so the cursor isn't dropped on the way UP into the notch (the dismiss-on-move-into-notch bug).
    private func nearTopZone(_ point: CGPoint, zone: CGRect, metrics m: ScreenMetrics) -> Bool {
        guard zone != .zero else { return false }
        let railFrame = overlay.isVisible ? overlay.frame : nil
        let live = liveZoneFor(m, zone: zone, rail: railFrame)
        // A small slack ring around the contiguous live region (the `nearDockEdge` slop) for reveal trigger.
        return live.insetBy(dx: -40, dy: -8).contains(point)
    }

    // MARK: - Ambient glow panel (its own slim non-activating click-through panel on the zone)

    private final class GlowState: ObservableObject { @Published var isActive = false }

    private func ensureGlow() {
        if glowPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: NotchHomeZoneLayout.zoneWidth,
                                    height: NotchHomeZoneLayout.zoneHeight + 60),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true          // ambient: never takes the pointer
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: GlowHost(state: glowState))
            glowPanel = panel
        }
        // Anchor on the active screen's top-center zone; never re-fronts the rail (separate panel).
        let point = NSEvent.mouseLocation
        let zone = metrics(for: point).map { zoneRectFor($0) } ?? .zero
        if zone != .zero, let panel = glowPanel {
            var frame = panel.frame
            frame.origin = CGPoint(x: zone.midX - frame.width / 2, y: zone.minY)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        }
    }

    private func tearDownGlow() {
        glowPanel?.orderOut(nil)                      // synchronous teardown
    }

    private struct GlowHost: View {
        @ObservedObject var state: GlowState
        var body: some View { NotchAmbientGlow(isActive: state.isActive) }
    }
}
