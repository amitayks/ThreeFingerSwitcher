import AppKit
import CoreGraphics

/// Orchestrates the Dock-hover preview: it wires the cursor monitor → Dock reader → pure `DockHoverModel`
/// → window enumeration → thumbnail capture → the mouse-interactive overlay → raise-on-commit. Owned by
/// `AppCoordinator`, gated by the `showDockPreviews` opt-in (`setEnabled`).
///
/// Tracking is **edge-gated**: while nothing is shown, the Dock is read only when the cursor is near a
/// screen edge (cheap idle path); while the popup is open, a short repeating timer re-reads + re-feeds so
/// grace-dismiss, magnification (the anchor re-glues to the growing tile), and the live peek all advance
/// without depending solely on move events. The Dock reader caches nothing, so an auto-hidden Dock simply
/// reads as empty (idle) until it reveals.
@MainActor
final class DockPreviewController {
    private let cursor: CursorMonitor
    private let reader: DockReader
    private let hover = DockHoverModel()
    private let overlay = DockPreviewOverlayController()
    private let windowService: WindowService
    /// Cache + capture conduit for the tab thumbnails. The tab shows a STATIC last-good image: seeded from
    /// this cache on open, and refreshed by a single one-shot screenshot once a peeked window has settled
    /// (no continuous screen recording / SCStream — the live view is the fronted real window itself).
    private let thumbnails = ThumbnailService()
    /// The switcher's thumbnail service, shared by reference so a frame captured here ALSO refreshes the
    /// switcher's cache — and vice-versa when seeding tabs.
    private let switcherThumbnails: ThumbnailService

    /// Cursor distance (points) from a screen edge that arms a fresh Dock read while idle.
    private let edgeBand: CGFloat = 130
    /// The hover/dock-read/grace loop cadence. Coarse on purpose — grace dismissal and magnification
    /// re-anchor don't need 60fps, and each tick does a synchronous Accessibility walk of the Dock.
    private let hoverTickInterval: TimeInterval = 0.12

    private var enabled = false
    private var snapshot: DockSnapshot?
    private var shownPID: pid_t?
    private var emptyPID: pid_t?
    /// The tile whose native action menu we just opened with a right-click. While the cursor lingers on
    /// this tile we suppress re-showing the popup (so a stray move doesn't pop it back up behind the open
    /// menu); cleared the moment the cursor leaves the tile.
    private var menuSuppressedPID: pid_t?
    private var currentWindows: [WindowInfo] = []
    private var lastCommitID: CGWindowID?
    /// Hover/dock-read/grace loop (AX-heavy, coarse cadence). The tab image is a one-shot static capture.
    private var hoverTimer: Timer?

    /// The window that was frontmost when the peek session began — re-fronted (restored) on leave so a
    /// peek is reversible. Captured once at the first popup open, cleared on dismiss/commit.
    private var restoreTarget: WindowInfo?
    /// The window currently fronted by a peek (nil when nothing has been peeked yet this session).
    private var peekedID: CGWindowID?
    /// Pending (delayed) one-shot capture — cancelled if the cursor retargets or the popup dismisses first.
    private var captureTask: Task<Void, Never>?
    /// How long after fronting a window to grab its static frame. The window animates forward when it's
    /// fronted; capturing immediately grabs that mid-transition ("sideways, coming from the Dock") frame,
    /// so we wait for it to settle. The seeded last-good frame holds the tab during the delay.
    private let captureDelay: TimeInterval = 0.5

    init(cursor: CursorMonitor, reader: DockReader, windowService: WindowService,
         switcherThumbnails: ThumbnailService) {
        self.cursor = cursor
        self.reader = reader
        self.windowService = windowService
        self.switcherThumbnails = switcherThumbnails

        thumbnails.onThumbnail = { [weak self] id, image in
            guard let self else { return }
            self.overlay.model.setThumbnail(image, for: id)
            // A peek fronted the window so this is a GOOD frame — refresh the switcher's cache (and its
            // live model, if open) with it too, so the switcher shows the same fresh thumbnail next time.
            self.switcherThumbnails.inject(image, for: id)
        }
        overlay.onHover = { [weak self] id, inside in self?.setHover(id, inside: inside) }
        overlay.onCommit = { [weak self] id in self?.commit(id) }
        overlay.onRetryError = { [weak self] in self?.retryError() }
    }

    // MARK: - Lifecycle (opt-in)

    /// Install/tear down the whole subsystem off the `showDockPreviews` toggle. Idempotent.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            cursor.onMove = { [weak self] point in self?.handleCursor(point) }
            cursor.onRightClick = { [weak self] point in self?.handleRightClick(point) }
            cursor.start()
        } else {
            cursor.stop()
            cursor.onMove = nil
            cursor.onRightClick = nil
            dismiss()
        }
    }

    // MARK: - Cursor handling

    private func handleCursor(_ point: CGPoint) {
        guard enabled else { return }
        // Edge-gate: only read the Dock when something is shown or the cursor is near a screen edge.
        guard overlay.isVisible || nearDockEdge(point) else { return }

        let snap = reader.read()
        snapshot = snap
        let tiles = snap?.tiles ?? []

        // Right-click suppression: while the cursor still rests on the tile whose native menu we just
        // opened, do nothing — don't feed the hover model, don't re-show the popup (it would appear behind
        // the menu). The moment the cursor leaves that tile, clear it and resume normal hover tracking.
        if let pid = menuSuppressedPID {
            if tiles.first(where: { $0.pid == pid })?.frame.contains(point) == true { return }
            menuSuppressedPID = nil
        }

        let popupFrame = overlay.isVisible ? overlay.frame : nil
        let decision = hover.feed(cursor: point, tiles: tiles, popupFrame: popupFrame, now: now())

        switch decision {
        case .idle:
            if overlay.isVisible { dismiss() }
        case .dismiss:
            dismiss()
        case let .open(pid):
            if pid == shownPID, overlay.isVisible {
                reanchor(pid)                       // keep glued to a magnifying tile
            } else if pid != emptyPID {
                openApp(pid)
            }
            // NB: capturing is NOT done here — `peek` schedules a single delayed static capture, so the
            // AX-heavy work above doesn't gate it.
        }

        manageHoverTimer()
    }

    /// A right-click landed somewhere. If the preview is open and the click hit a Dock app tile, the user
    /// is opening that tile's native action menu — dismiss the preview (restoring any peeked window) so
    /// the menu owns the stage. The click itself is never consumed (passive monitor), so the native menu
    /// opens unmodified.
    private func handleRightClick(_ point: CGPoint) {
        guard enabled else { return }
        let tiles = reader.read()?.tiles ?? snapshot?.tiles ?? []
        guard hover.rightClick(at: point, tiles: tiles) == .dismiss,
              let pid = DockHoverModel.tile(at: point, in: tiles)?.pid else { return }
        if overlay.isVisible { dismiss(restore: true) }
        // The tile's native action menu is now opening; keep the popup closed for this tile until the
        // cursor leaves it, so a stray move (cursor still on the icon) doesn't re-show it behind the menu.
        menuSuppressedPID = pid
    }

    /// Open (or swap to) the preview for `pid`: enumerate its current-Space windows (incl. minimized),
    /// suppress the popup when there are none, otherwise fill the model, anchor, and show.
    private func openApp(_ pid: pid_t) {
        guard let snap = snapshot, let tile = snap.tiles.first(where: { $0.pid == pid }) else { return }
        emptyPID = nil
        let windows = windowService.currentSpaceWindows(forApp: pid)
        guard !windows.isEmpty else {
            // No current-Space windows → show nothing (spec). Remember so we don't re-enumerate per move.
            emptyPID = pid
            if overlay.isVisible { dismiss() }
            return
        }
        // Capture the window to restore once, at the start of the peek session (before anything is
        // fronted) — our overlay is non-activating, so this is the user's real frontmost window.
        if restoreTarget == nil { restoreTarget = windowService.frontmostWindow() }
        currentWindows = windows
        let appName = windows.first?.appName ?? tile.title
        let icons = Dictionary(windows.compactMap { w in w.appIcon.map { (w.id, $0) } },
                               uniquingKeysWith: { a, _ in a })
        overlay.model.setWindows(windows.map {
            DockPreviewWindow(id: $0.id, title: $0.displayTitle, isMinimized: $0.isMinimized, aspect: Self.aspect(of: $0))
        }, appName: appName, icons: icons)
        shownPID = pid

        // Seed each tab with its last-good captured frame from the persistent cache (the switcher's
        // `seed` safety): a previously-captured frame shows IMMEDIATELY, so the popup never opens on
        // bare icons when we've seen these windows before — and the immediate refresh below can only
        // REPLACE it with another good capture (a degraded/occluded one is discarded by ThumbnailService),
        // so a tab never reverts to the icon once it has a frame.
        for w in windows {
            if let cached = thumbnails.cached(w.id) ?? switcherThumbnails.cached(w.id) {
                overlay.model.setThumbnail(cached, for: w.id)
            }
        }

        let size = DockPreviewLayout.size(forAspects: overlay.model.windows.map(\.aspect),
                                          maxWidth: snap.screenFrame.width)
        let anchor = DockHoverModel.anchorRect(for: tile.frame, orientation: snap.orientation,
                                               popupSize: size, screenFrame: snap.screenFrame)
        overlay.show(at: anchor)
        // No bulk capture here: only a FRONTED window yields a good frame, and fronting happens on hover
        // (`peek`) — which then grabs one static frame for that window. Non-hovered tabs hold their seeded
        // last-good frame (or app icon).
    }

    /// The window's width/height ratio for aspect-correct tab sizing (real AX frame preferred over the
    /// CGWindowList bounds); 16:10 fallback when no usable size is known.
    private static func aspect(of w: WindowInfo) -> CGFloat {
        let f = w.realFrame.width > 1 ? w.realFrame : w.frame
        return f.height > 1 ? f.width / f.height : 1.6
    }

    /// Recompute and apply the anchor for the already-shown app (tracks magnification / tile motion).
    private func reanchor(_ pid: pid_t) {
        guard let snap = snapshot, let tile = snap.tiles.first(where: { $0.pid == pid }) else { return }
        let size = DockPreviewLayout.size(forAspects: overlay.model.windows.map(\.aspect),
                                          maxWidth: snap.screenFrame.width)
        let anchor = DockHoverModel.anchorRect(for: tile.frame, orientation: snap.orientation,
                                               popupSize: size, screenFrame: snap.screenFrame)
        overlay.move(to: anchor)        // reposition only — never re-front (would stomp the native menu)
    }

    // MARK: - Peek & commit

    private func setHover(_ id: CGWindowID, inside: Bool) {
        // Like the switcher's selection: a card stays selected (and live) until ANOTHER card is hovered
        // or the popup dismisses. We deliberately ignore `inside == false` — the hover scale-up makes
        // SwiftUI's onHover flicker false/true, and clearing on false would keep blanking the live pump
        // so the tab only refreshed on enter/leave. Swaps happen via the next card's `inside == true`;
        // the highlight is cleared in `dismiss`.
        guard inside else { return }
        overlay.model.highlightedID = id
        peek(id)
    }

    /// Peek the hovered window: front the REAL window so it renders live at its true position/size (the
    /// live view IS that fronted window), then grab ONE static frame for its tab — no continuous stream.
    /// Minimized windows are NOT fronted (that would need de-minimizing) — they can't yield a fresh frame,
    /// so they keep their last-good tab thumbnail and surface only on commit. Previously-front window is
    /// restored on leave.
    private func peek(_ id: CGWindowID) {
        guard let w = currentWindows.first(where: { $0.id == id }) else { return }
        captureTask?.cancel()
        guard !w.isMinimized else { return }
        windowService.peekRaise(w)             // front the window NOW (it comes to view immediately)
        peekedID = id
        // Grab a single static frame only AFTER the front animation settles, so we don't capture (and then
        // persist as "last good") the mid-transition frame. The seeded frame holds the tab until then.
        let delay = captureDelay
        let logical = w.realFrame.width > 1 ? w.realFrame : w.frame
        captureTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled, self.peekedID == id else { return }
            await self.thumbnails.captureOne(id, logicalFrame: logical)    // one-shot; degraded-gated safety
        }
    }

    private func commit(_ id: CGWindowID) {
        guard let w = currentWindows.first(where: { $0.id == id }) else {
            overlay.model.setError(.windowUnavailable(name: "this window"))
            return
        }
        lastCommitID = id
        if windowService.raiseDeminimizing(w) {
            dismiss(restore: false)        // keep the chosen window front — do NOT put the old one back
        } else {
            overlay.model.setError(.windowUnavailable(name: w.displayTitle))
        }
    }

    private func retryError() {
        overlay.model.dismissError()
        if let id = lastCommitID { commit(id) }
    }

    // MARK: - Dismiss & timer

    /// Tear down the popup. When `restore` is true and a window was peeked (fronted) but not committed,
    /// re-front the window that was frontmost when the peek began — so a hover-and-leave leaves the
    /// desktop exactly as it was. A commit passes `restore: false` to keep the chosen window.
    private func dismiss(restore: Bool = true) {
        captureTask?.cancel()
        captureTask = nil
        if restore, peekedID != nil, let target = restoreTarget {
            windowService.peekRaise(target)
        }
        overlay.hide()                 // synchronous orderOut
        overlay.model.clear()
        currentWindows = []
        shownPID = nil
        emptyPID = nil
        menuSuppressedPID = nil
        peekedID = nil
        restoreTarget = nil
        hover.reset()
        manageHoverTimer()
    }

    /// Run the hover/dock-read/grace loop only while the popup is open. (The tab image is a one-shot
    /// static capture scheduled per peek, not a timer.)
    private func manageHoverTimer() {
        if overlay.isVisible, hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverTickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleCursor(NSEvent.mouseLocation) }
            }
        } else if !overlay.isVisible, let t = hoverTimer {
            t.invalidate()
            hoverTimer = nil
        }
    }

    // MARK: - Helpers

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// True when the cursor is within `edgeBand` of the bottom/left/right edge of its screen — where any
    /// Dock could be. Cheap (no AX), so it gates the idle path without reading the Dock on every move.
    private func nearDockEdge(_ point: CGPoint) -> Bool {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.frame else { return false }
        return point.y - f.minY <= edgeBand
            || point.x - f.minX <= edgeBand
            || f.maxX - point.x <= edgeBand
    }
}
