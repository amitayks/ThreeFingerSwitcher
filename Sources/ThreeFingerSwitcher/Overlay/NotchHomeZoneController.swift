import AppKit
import SwiftUI

/// Wires the notch home-zone rail together exactly like `DockPreviewController` (design §8): a passive
/// `GlobalCursorMonitor` (no Input Monitoring) feeds cursor points; while the rail is hidden geometry is
/// read only when the cursor is near the top-center zone (the `nearDockEdge` analogue — cheap idle); a
/// pure `NotchRevealModel` decides reveal/keep/dismiss (`now:` injected); a coarse re-feed timer advances
/// grace/relayout only while shown; teardown is **synchronous**. Gated by the agent-feature opt-in (when
/// off, the monitor isn't installed). A `hasNeedsYou` flag tracks whether any session is `.needsYou`
/// (the rail badges those rows on reveal); the earlier always-on animated glow panel was removed — it
/// pinned the main thread while idle (see docs/postmortem-idle-cpu-spin.md).
@MainActor
final class NotchHomeZoneController {
    private let overlay = NotchHomeZoneOverlayController()
    private let reveal = NotchRevealModel()
    private let cursor: CursorMonitor
    private let now: () -> TimeInterval

    /// The data source: the parked rows + their stored conversations (the scheduler/store seam).
    var sessionsProvider: () -> [ParkedSession] = { [] }
    /// Expand a session's card IN PLACE into its conversation view (`notch-native-conversations`).
    var onExpand: ((AgentSessionID) -> Void)?
    /// The "+ New chat" card was activated — create a session (durable at birth) and expand it.
    var onNewSession: (() -> Void)?
    /// The expanded conversation asked to collapse (chevron / Esc / notch-nub click).
    var onCollapse: (() -> Void)?
    /// Discard a parked session (deletion — cancel pending + remove).
    var onDiscard: ((AgentSessionID) -> Void)?
    /// Resolve the engine driving a session's expanded conversation (owned by `ParkController`).
    var engineProvider: (AgentSessionID) -> NotchSessionEngine? = { _ in nil }

    private var enabled = false
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 0.12
    /// True while a conversation is expanded in place — pins the panel open (cursor departure and the
    /// grace-dismiss apply to RAIL mode only; an open conversation never tears down under the reader).
    private var isConversationExpanded: Bool {
        if case .expanded = overlay.model.mode { return true }
        return false
    }

    /// Whether any parked session currently needs the user. Tracked for the rail badge + tests; the
    /// earlier always-on animated glow panel was removed (see docs/postmortem-idle-cpu-spin.md).
    private var hasNeedsYou = false

    init(cursor: CursorMonitor? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.cursor = cursor ?? GlobalCursorMonitor()
        self.now = now
        overlay.onExpand = { [weak self] id in self?.onExpand?(id) }
        overlay.onNewSession = { [weak self] in self?.onNewSession?() }
        overlay.onCollapse = { [weak self] in self?.onCollapse?() }
        overlay.onDiscard = { [weak self] id in self?.onDiscard?(id) }
    }

    /// Set the reveal DWELL — how long the cursor must stay crossed behind the notch before the rail reveals
    /// (0 ⇒ immediate). Live-settable from the Hub; takes effect on the next reveal (an in-flight dwell is
    /// left to complete against its current deadline).
    func setRevealDwell(_ interval: TimeInterval) {
        reveal.dwellInterval = max(0, interval)
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
        }
    }

    /// Refresh the rail rows + the needs-you flag from the current parked set (call after a scheduler
    /// advance / escalate). `hasNeedsYou` is true iff any session is `.needsYou`.
    func refresh() {
        let sessions = sessionsProvider()
        overlay.model.sessions = sessions
        hasNeedsYou = sessions.contains { $0.state == .needsYou }
    }

    // MARK: - Test seams (the rail view-model the overlay renders + the needs-you predicate)

    /// The rail rows the overlay currently renders (after the last `refresh`/reveal). Test-only read.
    var overlayModelSessionsForTest: [ParkedSession] { overlay.model.sessions }
    /// Whether any parked session currently needs the user. Test-only read.
    var hasNeedsYouForTest: Bool { hasNeedsYou }

    // MARK: - Expand / collapse in place (`notch-native-conversations` D4)

    /// Switch the panel into the in-place EXPANDED conversation for `id`: bind the session's engine to
    /// the view-model, flip the mode, and resize the same panel to the expanded content solve. The rail's
    /// reveal machinery is then PINNED (see `handleCursor`) so cursor departure never tears it down.
    func expandSession(_ id: AgentSessionID) {
        let point = NSEvent.mouseLocation
        guard let m = metrics(for: point) ?? NSScreen.main.flatMap(metricsFor) else { return }
        overlay.model.engine = engineProvider(id)
        overlay.model.mode = .expanded(id)
        overlay.model.attachment = attachmentFor(m)
        let size = NotchHomeZoneLayout.solveExpanded(visibleFrame: m.visibleFrame)
        let rect: CGRect
        if let notch = m.notch {
            rect = NotchHomeZoneAnchor.attachedPanelRect(contentSize: size, notch: notch,
                                                         screenFrame: m.screenFrame)
        } else {
            rect = NotchHomeZoneAnchor.railRect(zone: zoneRectFor(m), size: size,
                                                visibleFrame: m.visibleFrame)
        }
        // Stretch the border out to the expanded size (a fluid frame animation) when already shown; a hidden
        // panel (new chat straight to expanded) grows from the notch point via the first-show spring instead.
        overlay.reveal(at: rect, animateResize: true)
        manageRefreshTimer()
    }

    /// Return the panel to RAIL mode (the expanded conversation collapsed): drop key FIRST (the D5
    /// ordering — never tear down/resize while holding key), unbind the engine, resize back to the rail
    /// solve, and let the normal rail grace behavior resume.
    func collapseToRail() {
        overlay.setKeyCapable(false)
        overlay.model.engine = nil
        overlay.model.mode = .rail
        guard overlay.isVisible else { return }
        let point = NSEvent.mouseLocation
        guard let m = metrics(for: point) ?? NSScreen.main.flatMap(metricsFor) else { return }
        overlay.model.sessions = sessionsProvider()
        overlay.model.attachment = attachmentFor(m)
        // Stretch the border back down to the rail size (fluid frame animation).
        overlay.reveal(at: railRectFor(m, zone: zoneRectFor(m)), animateResize: true)
        manageRefreshTimer()
    }

    /// Straight-CLOSE the expanded conversation (the swipe-up "minimize" path): shrink the panel from its
    /// current expanded size DIRECTLY into the point behind the notch — no rail-size intermediate to dwell
    /// on. The conversation stays BOUND through the shrink (the caller defers its state-collapse to `then`),
    /// so the real conversation shrinks — never flashing the empty/new-chat state or the rail. Once hidden:
    /// reset the panel to rail mode (clears the conversation pin, clean rail for the next reveal), force the
    /// reveal model hidden (a fresh cross-behind is required to re-open), then run `then` (the state-collapse).
    func collapseAndClose(then finish: (() -> Void)? = nil) {
        overlay.setKeyCapable(false)
        reveal.reset()                              // a fresh cross-behind is required to re-reveal
        overlay.hide(animated: true) { [weak self] in
            self?.overlay.model.engine = nil
            self?.overlay.model.mode = .rail         // clean rail for the next reveal; clears the pin
            finish?()
        }
        manageRefreshTimer()
    }

    // MARK: - Cursor handling (edge-gated, mirrors DockPreviewController)

    private func handleCursor(_ point: CGPoint) {
        guard enabled, let m = metrics(for: point) else { return }
        // The expanded-conversation PIN (`notch-native-conversations` D4): while a conversation is open
        // in place, the reveal model is not fed at all — cursor departure and the grace-dismiss apply to
        // rail mode only (the `menuSuppressedPID` consumer-side suppression precedent). The panel closes
        // only via explicit collapse, feature-off, or the synchronous teardown paths.
        if isConversationExpanded { return }
        let zone = zoneRectFor(m)
        // The reveal TRIGGER: the cursor must cross UP *behind the notch* (notched display) or slam to the
        // physical top edge (notchless/external) — not merely graze the resting zone below it. The nub/zone
        // stays only as a keep-open bridge inside the live region (below). See docs/notch-geometry-reference.md.
        let trigger = triggerRectFor(m)
        // Edge-gate: compute when something is shown, a dwell is in progress (so it can be advanced OR
        // cancelled once the cursor leaves the trigger), or the cursor is near the trigger / live region.
        guard overlay.isVisible || reveal.isDwelling
                || nearTopZone(point, zone: zone, trigger: trigger, metrics: m) else { return }

        let railFrame = overlay.isVisible ? overlay.frame : nil
        // The ONE contiguous live region (zone + connecting band + container, extended up into the notch
        // pixels) — so moving the cursor UP into the notch keeps the rail .shown (docks), never dismisses.
        let liveZone = liveZoneFor(m, zone: zone, rail: railFrame)
        let decision = reveal.feed(cursor: point, zoneRect: trigger, railFrame: railFrame,
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

    /// Dismiss the rail. `animated` (the default, used for the cursor-left grace-dismiss) recedes it back
    /// into the notch on the ease-in-out spread; `animated == false` (restore / feature-off) tears it down
    /// synchronously so focus/teardown are immediate (the ghost-on-Space-switch landmine path).
    private func dismiss(animated: Bool = true) {
        overlay.hide(animated: animated)
        manageRefreshTimer()
    }

    private func manageRefreshTimer() {
        // Pause the re-feed while an animated recede is in flight (isReceding) — otherwise each tick would
        // re-issue the dismiss and the recede would never complete. Also run it while a reveal DWELL is
        // counting down, so a perfectly still cursor (no move events) still reveals once the dwell elapses.
        let wantTimer = (overlay.isVisible && !overlay.isReceding) || reveal.isDwelling
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
        return metricsFor(screen)
    }

    private func metricsFor(_ screen: NSScreen) -> ScreenMetrics {
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

    /// The reveal TRIGGER region (distinct from the resting zone/nub, which only bridges keep-open): the
    /// physical notch cutout on a notched display — reveal fires ONLY when the cursor crosses UP behind the
    /// notch — or a thin top-edge band at top-center on a notchless/external display (slam to the top edge).
    private func triggerRectFor(_ m: ScreenMetrics) -> CGRect {
        if let notch = m.notch {
            return NotchHomeZoneAnchor.notchTriggerRect(notch: notch)
        }
        return NotchHomeZoneAnchor.topEdgeTriggerRect(width: zoneSize.width,
                                                      visibleFrame: m.visibleFrame,
                                                      screenFrame: m.screenFrame)
    }

    /// The revealed panel: in attached mode it merges into the notch (top at the physical top, content band
    /// below); else it hangs flush below the tab. Both hug their sessions via the shared content-fit solve.
    private func railRectFor(_ m: ScreenMetrics, zone: CGRect) -> CGRect {
        // The rail always renders the persistent "+ New chat" card PLUS one per session, so the width solve
        // must count that extra card — otherwise the panel is one card too narrow and the row scrolls. The
        // dock is non-scrollable: it hugs all cards and EXPANDS as sessions are added.
        let cardCount = overlay.model.sessions.count + 1
        let solved = NotchHomeZoneLayout.solve(count: cardCount, visibleFrame: m.visibleFrame)
        if let notch = m.notch {
            // Size the panel taller so that CENTERING the row (in the view) yields symmetric padding of
            // `notch.height + a little` on top and bottom — the cards clear the notch and sit balanced.
            let contentH = NotchHomeZoneLayout.attachedRailContentHeight(notchHeight: notch.height)
            let contentSize = CGSize(width: solved.contentSize.width, height: contentH)
            return NotchHomeZoneAnchor.attachedPanelRect(
                contentSize: contentSize, notch: notch, screenFrame: m.screenFrame)
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

    /// Edge-gate: the cursor is near the contiguous live region OR near the reveal trigger (cheap idle, like
    /// `nearDockEdge`). Covers the connecting band + the notch pixels above the zone so the cursor isn't
    /// dropped on the way UP into the notch (the dismiss-on-move-into-notch bug); the trigger is included
    /// explicitly because the notchless top-edge band sits ABOVE the menu-bar-capped live region.
    private func nearTopZone(_ point: CGPoint, zone: CGRect, trigger: CGRect, metrics m: ScreenMetrics) -> Bool {
        guard zone != .zero else { return false }
        let railFrame = overlay.isVisible ? overlay.frame : nil
        let live = liveZoneFor(m, zone: zone, rail: railFrame)
        // A small slack ring (the `nearDockEdge` slop) around both the live region and the reveal trigger.
        return live.insetBy(dx: -40, dy: -8).contains(point)
            || trigger.insetBy(dx: -40, dy: -8).contains(point)
    }

}
