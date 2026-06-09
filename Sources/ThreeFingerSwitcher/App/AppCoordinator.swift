import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Owns and wires the whole pipeline: touch → recognizer → overlay highlight → commit raise.
/// Also drives onboarding, settings, and the native-gesture consent flow.
@MainActor
final class AppCoordinator: GestureRecognizerDelegate {
    let settings = AppSettings.shared
    let permissions = PermissionsService()
    let trackpadConfig = TrackpadGestureConfig()

    private let mru = MRUTracker()
    private lazy var windowService = WindowService(mru: mru, settings: settings)
    private let thumbnails = ThumbnailService()
    private let overlay = OverlayController()
    private let touchEngine = TouchEngine()
    private lazy var recognizer = GestureRecognizer(settings: settings)
    let spacesRearrange = SpacesRearrangeConfig()
    let verticalGesture = VerticalGestureConfig()
    let fourFingerGesture = FourFingerGestureConfig()
    private let scrollTap = ScrollEventTap()
    private var cancellables: Set<AnyCancellable> = []

    // Four-finger launcher.
    private let favoritesStore = FavoritesStore.shared
    private let launcherOverlay = LauncherOverlayController()
    private lazy var launchService = LaunchService(
        favoritesProvider: { [weak self] in self?.favoritesStore.favorites ?? Favorites() },
        mover: SpaceWindowMover(),
        // A foreign single-window app can't be pulled to the current Space, so "go to it": reuse the
        // switcher's robust off-Space raise (Space switch + Stage-Manager hold-guard + focus watchdog).
        goToWindow: { [weak self] pid in
            guard let self, let target = self.windowService.snapshot().first(where: { $0.pid == pid })
            else { return false }
            self.windowService.raise(target)
            return true
        },
        // The window a "Close Front Window" action targets — captured when the launcher opened.
        frontAppProvider: { [weak self] in self?.capturedFrontApp ?? NSWorkspace.shared.frontmostApplication },
        // After a Next/Previous Space shortcut, focus the destination Space's front window once the
        // switch settles (the OS leaves it visually front but not key — same as the native shortcut).
        onSpaceSwitch: { [weak self] in self?.focusFrontWindowAfterSpaceSwitch() },
        // An AI command hands off to the executor, which streams into the overlay's preview canvas.
        // Firing it does NOT dismiss the overlay (the overlay handles that exception).
        onAICommand: { [weak self] command in self?.aiCommandExecutor.fire(command) }
    )

    /// Frontmost app captured at launcher-open time (target for `.action(.closeFrontWindow)`).
    private var capturedFrontApp: NSRunningApplication?

    // Clipboard history (opt-in; the synthetic Clipboard band + the background recorder).
    private let clipboardStore = ClipboardStore.shared
    private lazy var clipboardMonitor = ClipboardMonitor(store: clipboardStore)

    // AI commands (opt-in; the synthetic AI band + the on-device model + the streaming canvas).
    private let aiCommandStore = AICommandStore.shared
    /// Reads/writes the captured front app's selection (and the clipboard / screen region) for an AI
    /// command. Reuses `capturedFrontApp` exactly like `LaunchService`, so output lands in the app the
    /// user was looking at (the overlay is non-activating).
    private lazy var selectionService = SelectionService(
        frontAppProvider: { [weak self] in self?.capturedFrontApp ?? NSWorkspace.shared.frontmostApplication }
    )
    /// Manages the on-device model lifecycle. Until the real MLX/Gemma runtime (phase 10) is wired,
    /// this runs against a **dev stub**: a `StubLLMRuntime` + a registry whose integrity SHA matches a
    /// fabricated dev payload, so download/verify/load succeed WITHOUT a real multi-gigabyte fetch and
    /// the streaming canvas is fully usable in a signed build today. Swapping in the real runtime is a
    /// one-line `runtimeFactory` change (design D1/D7) — feature code never sees a concrete model.
    private lazy var modelManager: ModelManager =
        AIRuntimeInjection.modelManagerFactory?(settings.aiCommandsEnabled)
        ?? DevAIRuntime.makeModelManager(optedIn: settings.aiCommandsEnabled)
    /// The agentic task layer (calendar / save-to-project / open-tool / send-to), driven by the model's
    /// structured output. Calendar permission is requested lazily at first calendar-task use.
    private lazy var taskDispatcher = TaskDispatcher(modelManager: modelManager, permissions: permissions)
    /// Orchestrates one AI command fire end-to-end (acquire → stream → commit), exposing the observable
    /// state the launcher's preview canvas binds to. The context provider supplies the captured app
    /// name so `{app}` resolves; input is filled by acquisition.
    private lazy var aiCommandExecutor = AICommandExecutor(
        modelManager: modelManager,
        selection: selectionService,
        dispatcher: taskDispatcher,
        contextProvider: { [weak self] in
            FireContext(capturedAppName: self?.capturedFrontApp?.localizedName)
        }
    )

    /// Whether the app currently has Mission Control open (it triggers MC itself via the vertical
    /// gesture). Lets the switcher float above MC and a commit dismiss it before raising.
    private var missionControlOpen = false

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var favoritesEditorWindow: NSWindow?

    private(set) var isEnabled = false
    var isTrackpadAvailable: Bool { touchEngine.isAvailable }

    var onStateChange: (() -> Void)?

    /// Live finger count from the most recent touch frame; drives the scroll tap's consume rule
    /// (the switcher owns all three-finger scroll so it never leaks to the background).
    private var currentFingerCount = 0

    /// Pure decision for the scroll tap: consume (swallow) scroll while three or more fingers are
    /// down OR while the launcher overlay is open OR while the switcher overlay is open. The
    /// overlay-open clauses capture the two-finger movement that drives launcher / switcher
    /// navigation (after a three- or four-finger trigger relaxes to two) so it doesn't scroll the
    /// window underneath; with both overlays closed it reverts to the `≥3`-fingers rule, leaving
    /// normal two-finger scroll alone.
    static func shouldConsumeScroll(fingerCount: Int, launcherOpen: Bool, switcherOpen: Bool) -> Bool {
        fingerCount >= 3 || launcherOpen || switcherOpen
    }

    init() {
        recognizer.delegate = self
        touchEngine.onFrame = { [weak self] frame in
            self?.currentFingerCount = frame.fingerCount
            self?.recognizer.feed(frame)
        }
        scrollTap.consumePredicate = { [weak self] in
            guard let self else { return false }
            return Self.shouldConsumeScroll(fingerCount: self.currentFingerCount,
                                            launcherOpen: self.launcherOverlay.isVisible,
                                            switcherOpen: self.overlay.isVisible)
        }
        thumbnails.onThumbnail = { [weak self] id, image in self?.overlay.model.setThumbnail(image, for: id) }
        launcherOverlay.onFire = { [weak self] item, band in self?.launchService.fire(item, inBand: band) }
        launcherOverlay.onTogglePin = { [weak self] item in
            guard case let .clipboardEntry(entry) = item.kind else { return }
            self?.clipboardStore.togglePin(id: entry.id)
        }
        // AI preview canvas: the executor it observes, and the two-stage commit / discard gestures.
        launcherOverlay.executor = aiCommandExecutor
        launcherOverlay.onCommitCanvas = { [weak self] in
            // A fresh four-finger DOWN swipe commits: route the ready result per the command's output
            // target (or fire the reviewed side effect). Errors surface in the executor's `.failed`
            // state (the canvas is already dismissed by the controller, but the executor records them).
            Task { @MainActor in try? await self?.aiCommandExecutor.commit() }
        }
        launcherOverlay.onDiscardCanvas = { [weak self] in self?.aiCommandExecutor.cancel() }
        // When the canvas opens, put the recognizer in canvas-resolution mode so a FRESH four-finger
        // swipe resolves it (horizontal = discard, down = apply) instead of re-opening the launcher.
        launcherOverlay.onCanvasStateChanged = { [weak self] active in
            self?.recognizer.launcherCanvasResolutionActive = active
        }
        observeSleepWake()
        observeSpacesRearrangeToggle()
        observeVerticalGestureToggle()
        observeLauncherToggle()
        observeClipboardToggle()
        observeAICommandsToggle()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for token in wakeObservers { center.removeObserver(token) }
    }

    /// Print the window-enumeration funnel and exit (used by `--diag`).
    func runDiagnostics() {
        print(windowService.diagnosticReport())
    }

    /// Write the enumeration funnel (AX-enabled, from the running app) to a file for debugging.
    /// The post-commit focus log (ring buffer) is appended below the cross-space funnel so a
    /// single dump after a freeze shows what we targeted, whether the key window materialized,
    /// whether the watchdog recovered, and whether secure input was the real culprit.
    func writeDiagnostics() {
        let path = "/tmp/tfs-cross-space-diag.txt"
        let base = windowService.diagnosticReport() + "\n\n" + FocusLog.shared.dump()
        // The ScreenCaptureKit frame probe is async; append it before writing so a single capture
        // carries both the listing (ghost) data and the thumbnail (set-aside) data.
        Task { @MainActor in
            let scFrames = await thumbnails.diagnosticFrames()
            let report = base + "\n\n" + scFrames
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            infoAlert(title: "Diagnostics written", text: "Saved to \(path)")
        }
    }

    /// Put the focus log (ring buffer) on the pasteboard for quick sharing after a freeze.
    func copyFocusLog() {
        let text = FocusLog.shared.pasteboardString()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        infoAlert(title: "Focus log copied", text: "The focus log is on the clipboard.")
    }

    func start() {
        // Off-Space support preflight: if any private CGS/SkyLight symbol is missing, the app
        // still runs and enumeration/raising fall back to the current Space only.
        if !cgs.offSpaceSupported {
            NSLog("[ThreeFingerSwitcher] off-Space window support disabled (private CGS symbols unavailable); using current-Space only.")
        }
        permissions.refresh()
        // Reapply the vertical-gesture relocation before enabling so the recognizer's row-switching
        // gate reflects the effective state from the first gesture.
        applyVerticalGestureOnLaunchIfManaged()
        applyLauncherGestureOnLaunchIfManaged()
        if settings.enabled { enable() }
        refreshRowSwitchingGate()
        refreshClipboardMonitor()
        maybePromptNativeGestureSetup()
        applySpacesRearrangeOnLaunchIfManaged()
        maybePromptSpacesRearrange()
        maybePromptVerticalGesture()
        maybePromptLauncher()
        if !permissions.allRequiredGranted { showOnboarding() }
    }

    // MARK: - Enable / disable

    func enable() {
        guard !isEnabled else { return }
        permissions.refresh()
        mru.start()
        touchEngine.start()
        isEnabled = touchEngine.isAvailable
        settings.enabled = true
        refreshRowSwitchingGate()
        refreshClipboardMonitor()
        onStateChange?()
    }

    func disable() {
        guard isEnabled else { return }
        recognizer.reset()
        touchEngine.stop()
        scrollTap.stop()
        mru.stop()
        overlay.hide()
        launcherOverlay.cancel()
        clipboardMonitor.stop()
        isEnabled = false
        settings.enabled = false
        onStateChange?()
    }

    func toggleEnabled() { isEnabled ? disable() : enable() }

    // MARK: - Sleep / wake recovery

    /// Observer tokens for the workspace sleep/wake notifications (removed in deinit).
    private var wakeObservers: [NSObjectProtocol] = []

    /// The OpenMultitouchSupport stream typically goes silent after a sleep/wake cycle, so the
    /// trackpad listener must be re-subscribed. Observe the workspace notifications and, on wake,
    /// restart the touch engine (stop → start) to attach a fresh listener.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in wakeNames {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartTouchEngineAfterWake() }
            }
            wakeObservers.append(token)
        }
        // willSleep is observed so any future teardown can hook in; we just stop motion tracking
        // to avoid feeding a stale velocity baseline into the first post-wake frame.
        let sleepToken = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        wakeObservers.append(sleepToken)
    }

    private func handleWillSleep() {
        // Drop any in-flight gesture/overlay so we don't wake into a half-committed state.
        guard isEnabled else { return }
        recognizer.reset()
        overlay.hide()
        launcherOverlay.cancel()
        // CRITICAL: stop the multitouch listener NOW, while its CFRunLoopSource is still valid. The OS
        // invalidates the device source during system sleep; calling `manager.stopListening()` AFTER
        // wake then traps on a freed source (EXC_BREAKPOINT in MTDeviceStop — observed during long
        // model downloads that span a sleep). Stopping pre-sleep makes the post-wake `stop()` a no-op,
        // and `restartTouchEngineAfterWake()` attaches a fresh listener on `didWake`.
        touchEngine.stop()
    }

    /// Re-subscribe the multitouch listener after wake. Idempotent and guarded against
    /// double-start: stop() / start() are no-ops when already in the target state.
    private func restartTouchEngineAfterWake() {
        guard isEnabled else { return }
        recognizer.reset()
        touchEngine.stop()
        touchEngine.start()
        // If the trackpad couldn't be re-acquired, reflect that in the menu state.
        let available = touchEngine.isAvailable
        if isEnabled != available {
            isEnabled = available
            onStateChange?()
        }
    }

    // MARK: - Open at login

    /// Whether the app is currently registered to launch at login (SMAppService.mainApp).
    var isOpenAtLogin: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Toggle "Open at Login" using the modern ServiceManagement API. Registration requires the
    /// app to live in a stable, signed location (e.g. /Applications); on failure we surface a
    /// short alert rather than crashing or blocking.
    func toggleOpenAtLogin() {
        guard #available(macOS 13.0, *) else {
            infoAlert(title: "Not supported",
                      text: "Opening at login requires macOS 13 or later.")
            return
        }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            infoAlert(
                title: "Couldn't change ‘Open at Login’",
                text: """
                \(error.localizedDescription)

                This usually means the app isn't in a stable, signed location. Move \
                ThreeFingerSwitcher.app to /Applications and try again. You can also enable it \
                manually in System Settings ▸ General ▸ Login Items.
                """
            )
        }
        onStateChange?()
    }

    // MARK: - GestureRecognizerDelegate

    func gestureDidActivate() {
        let windows = windowService.snapshot()
        guard !windows.isEmpty else { return }
        let grid = SpaceGrouping.group(windows)
        // When the app has Mission Control open, float the overlay above it (otherwise it renders
        // behind the MC windows). The elevated config is scoped to this case in `OverlayController`.
        overlay.show(rows: grid.rows, labels: grid.labels, startRow: grid.startRow, column: 0,
                     aboveMissionControl: missionControlOpen)
        prefetchCurrentRow()
    }

    func gestureDidStep(_ direction: Int) {
        guard overlay.isVisible else { return }
        let count = overlay.model.windows.count
        guard count > 0 else { return }
        var idx = overlay.selectedColumn + direction
        if settings.wrapAtEnds {
            idx = ((idx % count) + count) % count
        } else {
            idx = min(max(idx, 0), count - 1)
        }
        overlay.updateColumn(idx)
    }

    func gestureDidStepRow(_ direction: Int) {
        guard overlay.isVisible else { return }
        let count = overlay.rowCount
        guard count > 1 else { return }
        var row = overlay.currentRow + direction
        if settings.wrapAtEnds {
            row = ((row % count) + count) % count
        } else {
            row = min(max(row, 0), count - 1)
        }
        guard row != overlay.currentRow else { return }
        overlay.updateRow(row)
        prefetchCurrentRow()
    }

    func gestureDidTriggerMissionControl(up: Bool) {
        // A fresh three-finger vertical swipe while we own the gesture: open the OS overview
        // ourselves (the native gesture is disabled to a scroll, which the scroll tap consumes).
        MissionControl.trigger(up: up)
        // Track Mission Control's open state so a following switcher can float above it and a commit
        // can dismiss it. `up` toggles MC; App Exposé (down) is a different overview, so MC is no
        // longer considered open.
        missionControlOpen = up ? !missionControlOpen : false
    }

    private func prefetchCurrentRow() {
        let windows = overlay.model.windows
        thumbnails.seed(into: overlay.model, ids: windows.map(\.id))  // instant from cache (no icon-only flash)
        thumbnails.prefetch(windows)                                  // refresh only cleanly-visible windows
    }

    func gestureDidCommit() {
        guard overlay.isVisible, let window = overlay.model.selectedWindow else {
            overlay.hide()
            return
        }
        overlay.hide()
        guard permissions.accessibility == .granted else {
            permissions.requestAccessibility()
            return
        }
        // If Mission Control is open, close it first (so the raise lands on the live desktop, not the
        // overview), then raise once its close animation has settled. Otherwise raise immediately.
        if missionControlOpen {
            missionControlOpen = false
            MissionControl.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.windowService.raise(window)
            }
        } else {
            windowService.raise(window)
        }
    }

    func gestureDidCancel() {
        overlay.hide()
    }

    // MARK: - GestureRecognizerDelegate (four-finger launcher)

    func launcherDidActivate() {
        // Defensive: while the AI preview canvas is open the recognizer is in canvas-resolution mode and
        // routes swipes to `launcherCanvasResolve` (down = commit, horizontal = discard), so it does NOT
        // call this. Should it ever reach here, do NOT re-show — that would discard the canvas and reset
        // to the grid; let the open canvas keep handling the gesture.
        guard !launcherOverlay.canvasActive else { return }

        let fav = favoritesStore.favorites
        // When clipboard history is on, append the synthetic Clipboard band as the LAST band, built
        // fresh from the store (recent slice, pinned-first). It is never persisted and never the home.
        var bands = fav.bands
        var clipboardBandIndex: Int?
        var aiCommandBandIndex: Int?
        if settings.keepClipboardHistory {
            let entries = clipboardStore.recentWindow(limit: settings.clipboardRecentWindow)
            bands.append(ClipboardBandBuilder.build(from: entries))
            clipboardBandIndex = bands.count - 1
        }
        // When AI commands are on AND at least one command exists, append the synthetic AI band, built
        // fresh from the command store. Never persisted, never the home (mirrors the Clipboard band).
        if AICommandBandBuilder.shouldPresent(optedIn: settings.aiCommandsEnabled,
                                              commands: aiCommandStore.commands) {
            bands.append(AICommandBandBuilder.build(from: aiCommandStore.commands))
            aiCommandBandIndex = bands.count - 1
        }
        guard !bands.isEmpty else { return }
        // Capture the app the user was looking at before the (non-activating) overlay appears, so a
        // `.action(.closeFrontWindow)` item — a clipboard paste, and an AI command's selection I/O —
        // targets that window.
        let front = NSWorkspace.shared.frontmostApplication
        capturedFrontApp = (front?.processIdentifier == getpid()) ? capturedFrontApp : front
        launcherOverlay.edgeAcceleration = settings.clipboardEdgeAcceleration
        // Convert the deliberate pin-flick distance into a count of fine horizontal steps (also reused
        // as the canvas discard-flick threshold).
        launcherOverlay.clipboardPinSteps =
            max(2, Int((settings.clipboardPinDistance / max(settings.launcherStepDistance, 0.01)).rounded()))
        launcherOverlay.show(bands: bands,
                             startBand: fav.homeBandIndex,
                             startColumn: fav.resolvedHomeColumn,
                             dwell: settings.dwellToArmDuration,
                             clipboardBandIndex: clipboardBandIndex,
                             aiCommandBandIndex: aiCommandBandIndex)
    }

    func launcherDidStepItem(_ direction: Int) {
        guard launcherOverlay.isVisible else { return }
        launcherOverlay.stepHorizontal(direction)   // grid cursor / batch switch (on the headers row)
    }

    func launcherDidStepContext(_ direction: Int) {
        guard launcherOverlay.isVisible else { return }
        launcherOverlay.stepVertical(direction)      // grid rows / rise onto the headers row
    }

    func launcherFocusIsOnHeaders() -> Bool {
        launcherOverlay.isVisible && launcherOverlay.focusIsOnHeaders
    }

    func launcherDidEnd() {
        // Lift: the controller fires the armed item (or dismisses if nothing armed). Firing is
        // heterogeneous (app/path/url/shortcut/script/preset); the AX-dependent paths degrade on
        // their own if Accessibility isn't granted, so we don't gate the whole commit on it.
        launcherOverlay.end()
    }

    func launcherDidCancel() {
        launcherOverlay.cancel()
    }

    /// A fresh four-finger swipe while the AI preview canvas is open resolves it: a DOWN swipe applies
    /// the result (`dy == -1` — "bring it into the document"), a horizontal swipe discards. An UP swipe
    /// (`dy == +1`) is intentionally ignored so a stray upward motion never throws the result away.
    func launcherCanvasResolve(dx: Int, dy: Int) {
        guard launcherOverlay.canvasActive else { return }
        if dy < 0 {
            launcherOverlay.resolveCanvasCommit()   // swipe DOWN → apply (replace / paste / run task)
        } else if dx != 0 {
            launcherOverlay.discardCanvas()          // horizontal swipe → discard
        }
        // dy > 0 (up) → no-op
    }

    func launcherEdgeChanged(dx: Int, dy: Int) {
        guard launcherOverlay.isVisible else { return }
        var h = dx, v = dy
        if settings.reverseDirection { h = -h }            // match manual horizontal stepping
        if settings.reverseVerticalDirection { v = -v }    // match manual vertical stepping
        launcherOverlay.setEdgeAutoScroll(dx: h, dy: v)
    }

    // MARK: - Clipboard history monitor lifecycle

    /// React to the "Keep clipboard history" toggle: start/stop the recorder. The pause toggle just
    /// updates the monitor's pause flag (it early-returns while paused, keeping the band intact).
    /// Both sinks use the **emitted** value, not a re-read of the property: `@Published` fires in
    /// `willSet`, so `settings.keepClipboardHistory` would still report the OLD value here (the same
    /// reason the gesture toggles pass `enabled` through).
    private func observeClipboardToggle() {
        settings.$keepClipboardHistory
            .dropFirst()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.setClipboardRecording(on) } }
            .store(in: &cancellables)
        settings.$clipboardPaused
            .dropFirst()
            .sink { [weak self] paused in MainActor.assumeIsolated { self?.clipboardMonitor.isPaused = paused } }
            .store(in: &cancellables)
    }

    /// Push the tunables (retention, poll interval, exclusions) into the store/monitor. Does NOT read
    /// the start/stop or pause toggles (those are driven by their emitted values to avoid the
    /// `@Published` willSet staleness).
    private func applyClipboardTunables() {
        clipboardStore.retention = ClipboardStore.Retention(
            maxCount: settings.clipboardMaxCount,
            maxBytes: settings.clipboardMaxBytes,
            maxAge: settings.clipboardMaxAgeDays * 86_400)
        clipboardMonitor.pollInterval = settings.clipboardPollInterval
        clipboardMonitor.excludedBundleIDs = Set(settings.clipboardExcludedApps)
    }

    /// Start the recorder when recording is on AND the app is enabled; otherwise stop it. `on` is the
    /// authoritative recording state (the toggle's emitted value, or a stable read at launch/enable).
    private func setClipboardRecording(_ on: Bool) {
        applyClipboardTunables()
        clipboardMonitor.isPaused = settings.clipboardPaused
        if on && isEnabled {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

    /// Launch/enable/disable refresh: the opt-in value is stable at these call sites, so reading it is safe.
    private func refreshClipboardMonitor() {
        setClipboardRecording(settings.keepClipboardHistory)
    }

    // MARK: - AI commands opt-in lifecycle

    /// React to the "Enable AI commands" toggle: drive the model manager's opt-in. Turning it OFF
    /// evicts any resident model and forgets download progress (privacy + frees weights — handled in
    /// `ModelManager`); turning it ON only allows a download (it never auto-fetches — the user starts
    /// it from Settings). Uses the EMITTED value, not a re-read (the `@Published` willSet would still
    /// report the OLD value here — same reason the gesture toggles pass `enabled` through).
    private func observeAICommandsToggle() {
        settings.$aiCommandsEnabled
            .dropFirst()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.modelManager.setOptedIn(on) } }
            .store(in: &cancellables)
    }

    /// Begin (or retry) the on-device model download from Settings. Gated on the opt-in by the manager
    /// itself; surfaces a non-fatal alert if the (dev-stub today) download/verify fails. The real
    /// MLX/Gemma fetch is deferred (phase 10) — this drives the dev-stub path so the model loads.
    private func downloadAIModel() {
        modelManager.setOptedIn(settings.aiCommandsEnabled)
        guard let descriptor = modelManager.registry.defaultDescriptor
            ?? modelManager.registry.models.first else { return }
        Task { @MainActor in
            do {
                try await modelManager.downloadAndVerify(descriptor)
            } catch {
                // The manager already reflects `.failed`/`.notDownloaded` in its observable state for
                // the Settings surface; this alert is a belt-and-suspenders for an unexpected failure.
                infoAlert(title: "Couldn't prepare the model",
                          text: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    // MARK: - Post-Space-switch cleanup & focus

    /// A Next/Previous Space action only synthesizes the OS shortcut; once the switch lands the
    /// destination's front window is visually front but *not key* (same as the native shortcut), so the
    /// user would have to click before typing. Poll until the active Space actually flips, then focus
    /// the window the user last had front there.
    private func focusFrontWindowAfterSpaceSwitch() {
        let before = SpaceService.currentModel()?.currentSpaceIDs ?? []
        afterSpaceSettles(before: before, attempt: 0)
    }

    /// Poll until the active Space flips, then wait for the WindowServer transition (and the
    /// Stage-Manager front-steal ~300ms post-switch) to finish before focusing — acting on the flip
    /// instant gets steamrolled by the rest of the transition.
    private func afterSpaceSettles(before: Set<CGSSpaceID>, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            let now = SpaceService.currentModel()?.currentSpaceIDs ?? []
            if !now.isEmpty, now != before {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.focusFrontWindowOnCurrentSpace()
                }
                return
            }
            // A ⌃→ with no neighbour Space never flips — bail after ~1.9s rather than poll forever.
            if attempt < 30 { afterSpaceSettles(before: before, attempt: attempt + 1) }
        }
    }

    /// Focus the window the user last had front on the new current Space — the MRU-top window in the
    /// app's own snapshot. We do NOT use `NSWorkspace.frontmostApplication`: under Stage Manager, when
    /// the destination Space has multiple windows it stays `WindowManager` indefinitely and never
    /// yields to the real app (because that app's window isn't key — the very bug we're fixing). The
    /// MRU-ranked snapshot is independent of that limbo and matches what the OS keeps visually front.
    private func focusFrontWindowOnCurrentSpace() {
        launcherOverlay.hide()   // belt-and-suspenders; panel is normally already gone
        guard let w = windowService.snapshot().first(where: { $0.isOnCurrentSpace }) else { return }
        windowService.raise(w)
    }

    // MARK: - Native gesture consent

    private let didPromptKey = "didPromptNativeGesture"

    private func maybePromptNativeGestureSetup() {
        let alreadyPrompted = UserDefaults.standard.bool(forKey: didPromptKey)
        guard !alreadyPrompted, trackpadConfig.isClaimed else { return }
        UserDefaults.standard.set(true, forKey: didPromptKey)
        promptNativeGestureSetup()
    }

    func promptNativeGestureSetup() {
        guard trackpadConfig.isClaimed else {
            infoAlert(title: "Already set up",
                      text: "The horizontal three-finger swipe is already free. Mission Control and App Exposé still work on up/down.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Free the three-finger horizontal swipe?"
        alert.informativeText = """
        macOS currently uses a horizontal three-finger swipe to switch full-screen apps. \
        To use it for window switching instead, this app will move that gesture to four fingers.

        Mission Control and App Exposé (three-finger up/down) are not affected. \
        Your previous setting is saved and can be restored. A logout/restart may be required for it to take effect.
        """
        alert.addButton(withTitle: "Free the gesture")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let ok = trackpadConfig.disableThreeFingerHorizontal()
            infoAlert(
                title: ok ? "Done — restart to finish" : "Couldn't change the setting",
                text: ok ? "Log out and back in (or restart) so macOS stops claiming the horizontal three-finger swipe."
                         : "Writing the trackpad setting failed. You can change it manually in System Settings ▸ Trackpad ▸ More Gestures (turn off ‘Swipe between full-screen applications’)."
            )
            onStateChange?()
        }
    }

    func restoreNativeGestureSetting() {
        guard trackpadConfig.hasBackup else {
            infoAlert(title: "Nothing to restore", text: "No saved trackpad setting was found.")
            return
        }
        let ok = trackpadConfig.restore()
        infoAlert(title: ok ? "Restored" : "Restore failed",
                  text: ok ? "Your original trackpad setting was restored. Log out and back in for it to take effect."
                           : "Could not restore the setting. Adjust it manually in System Settings ▸ Trackpad.")
        onStateChange?()
    }

    /// Called on quit: offer to restore the trackpad setting if we changed it.
    func offerRestoreOnQuit() {
        guard trackpadConfig.hasBackup else { return }
        let alert = NSAlert()
        alert.messageText = "Restore the trackpad setting?"
        alert.informativeText = "This app changed ‘Swipe between full-screen applications’. Restore your original setting before quitting?"
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Keep as is")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = trackpadConfig.restore()
        }
    }

    // MARK: - Spaces auto-rearrange

    private let didPromptSpacesKey = "didPromptSpacesRearrange"

    /// React to the Settings toggle: enabling applies the setting, disabling restores it. The
    /// initial persisted value is skipped (`dropFirst`); launch-apply is handled in `start()`.
    private func observeSpacesRearrangeToggle() {
        settings.$manageSpacesRearrange
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.handleSpacesRearrangeToggle(enabled) }
            }
            .store(in: &cancellables)
    }

    private func handleSpacesRearrangeToggle(_ enabled: Bool) {
        if enabled {
            applySpacesRearrange()
        } else if spacesRearrange.hasBackup {
            _ = spacesRearrange.restore()
        }
    }

    private func applySpacesRearrangeOnLaunchIfManaged() {
        guard settings.manageSpacesRearrange else { return }
        applySpacesRearrange()
    }

    /// Disable Spaces auto-rearrange; surface a non-fatal warning if the write/Dock restart failed
    /// (e.g. a managed preference). A no-op when the setting is already fixed.
    private func applySpacesRearrange() {
        guard !spacesRearrange.disableAutoRearrange() else { return }
        infoAlert(
            title: "Couldn't change the Spaces setting",
            text: """
            Turning off “Automatically rearrange Spaces based on most recent use” (or restarting \
            the Dock) didn't succeed. If your Mac is managed (MDM), this setting may be locked. \
            You can turn it off manually in System Settings ▸ Desktop & Dock ▸ Mission Control.
            """
        )
    }

    /// First-run consent, mirroring the native-gesture prompt: ask once, only when the setting is
    /// actually on and the user hasn't already opted in.
    private func maybePromptSpacesRearrange() {
        let alreadyPrompted = UserDefaults.standard.bool(forKey: didPromptSpacesKey)
        guard !alreadyPrompted, !settings.manageSpacesRearrange, spacesRearrange.isAutoRearrangeOn else { return }
        UserDefaults.standard.set(true, forKey: didPromptSpacesKey)
        promptSpacesRearrangeSetup()
    }

    func promptSpacesRearrangeSetup() {
        guard spacesRearrange.isAutoRearrangeOn else {
            infoAlert(title: "Already set",
                      text: "Spaces are already kept in a fixed order — macOS isn't rearranging them by recent use.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Keep Spaces in a fixed order?"
        alert.informativeText = """
        macOS is set to “Automatically rearrange Spaces based on most recent use,” which reorders \
        your Spaces as you move between them — so the switcher's row order keeps shifting.

        Turn this off so each Space stays put. This changes a system setting (Mission Control, \
        everywhere) and briefly restarts the Dock. The app restores your original setting when you \
        quit and reapplies it on launch. You can change this anytime in Settings.
        """
        alert.addButton(withTitle: "Keep Spaces fixed")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.manageSpacesRearrange = true   // observer applies the change and persists the opt-in
            onStateChange?()
        }
    }

    /// Called on quit: if we disabled auto-rearrange this session, restore the original value
    /// (synchronously, so the Dock restart finishes before the app exits).
    func restoreSpacesRearrangeOnQuit() {
        guard spacesRearrange.changedThisSession else { return }
        _ = spacesRearrange.restore()
    }

    // MARK: - Space-row switching (vertical gesture)

    private let didPromptVerticalKey = "didPromptVerticalGesture"

    /// Whether vertical Space-row switching is *effective*: the opt-in is on AND the native
    /// three-finger vertical gesture has actually been relocated (freed) and that change has taken
    /// effect at runtime (not merely written this session — the trackpad change needs a re-login).
    var isSpaceRowSwitchingEffective: Bool {
        settings.manageVerticalGesture && verticalGesture.isEffectivelyFree
    }

    /// Whether the four-finger launcher is *effective*: the opt-in is on AND the native four-finger
    /// swipes have actually been freed and that change has taken runtime effect (re-login), not
    /// merely been written this session.
    var isLauncherEffective: Bool {
        settings.enableLauncher && fourFingerGesture.isEffectivelyFree
    }

    /// Push the effective state into the recognizer so vertical motion only steps Space-rows (and a
    /// fresh vertical swipe only triggers Mission Control ourselves) when the OS has genuinely
    /// released the three-finger vertical swipe, and so four fingers only drive the launcher once the
    /// native four-finger swipes are freed. The scroll tap now runs whenever the switcher is *enabled*
    /// — two-finger switcher navigation depends on it to consume the relaxed two-finger movement while
    /// the overlay is open — which subsumes the row/launcher cases (both require the switcher enabled).
    /// The tap consumes nothing outside its predicate (three-finger contact isn't a native scroll, and
    /// the overlay-open clauses are only true mid-gesture), so an always-on-when-enabled tap is
    /// observationally identical to a per-gesture one while being simpler and race-free.
    private func refreshRowSwitchingGate() {
        recognizer.rowSwitchingEnabled = isSpaceRowSwitchingEffective
        recognizer.launcherEnabled = isLauncherEffective
        if isEnabled {
            _ = scrollTap.start()
        } else {
            scrollTap.stop()
        }
    }

    /// React to the Settings toggle: enabling relocates the native vertical gesture, disabling
    /// restores it. The persisted initial value is skipped (`dropFirst`); launch-apply is handled
    /// in `start()`. Mirrors `observeSpacesRearrangeToggle`.
    private func observeVerticalGestureToggle() {
        settings.$manageVerticalGesture
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.handleVerticalGestureToggle(enabled) }
            }
            .store(in: &cancellables)
    }

    private func handleVerticalGestureToggle(_ enabled: Bool) {
        if enabled {
            applyVerticalGesture()
        } else if verticalGesture.hasBackup {
            _ = verticalGesture.restore()
        }
        refreshRowSwitchingGate()
    }

    private func applyVerticalGestureOnLaunchIfManaged() {
        guard settings.manageVerticalGesture else { return }
        applyVerticalGesture()
    }

    /// Relocate the native three-finger vertical gesture to four fingers; surface a non-fatal
    /// warning if the write failed (e.g. a managed preference). A no-op when already free.
    private func applyVerticalGesture() {
        guard !verticalGesture.relocateToFourFingers() else { return }
        infoAlert(
            title: "Couldn't change the trackpad setting",
            text: """
            Moving Mission Control / App Exposé to four fingers didn't succeed. If your Mac is \
            managed (MDM), this setting may be locked. You can change it manually in System \
            Settings ▸ Trackpad ▸ More Gestures (set Mission Control to “Swipe Up with Four Fingers”).
            """
        )
    }

    /// First-run consent, mirroring the spaces-rearrange prompt: ask once, only when the gesture is
    /// actually on three fingers and the user hasn't already opted in.
    private func maybePromptVerticalGesture() {
        let alreadyPrompted = UserDefaults.standard.bool(forKey: didPromptVerticalKey)
        guard !alreadyPrompted, !settings.manageVerticalGesture, verticalGesture.isClaimed else { return }
        UserDefaults.standard.set(true, forKey: didPromptVerticalKey)
        promptVerticalGestureSetup()
    }

    func promptVerticalGestureSetup() {
        guard verticalGesture.isClaimed else {
            infoAlert(title: "Already set up",
                      text: "Three-finger up/down is already free for Space-row switching. Mission Control / App Exposé are on four fingers.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable Space-row switching?"
        alert.informativeText = """
        Switch between Spaces by sliding three fingers up/down while the switcher is open. To free \
        that gesture, this app moves Mission Control and App Exposé to four fingers.

        They keep working on four-finger up/down. Your previous setting is saved — turn Space-row \
        switching off (or pick Restore from the menu) to put it back. A logout/restart is required \
        for the change to take effect, and it stays applied across logins until you turn it off.
        """
        alert.addButton(withTitle: "Enable Space-row switching")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.manageVerticalGesture = true   // observer applies the change and persists the opt-in
            infoAlert(
                title: "Almost there — restart to finish",
                text: "Log out and back in (or restart) so macOS frees the three-finger vertical swipe. Space-row switching turns on automatically after that."
            )
            onStateChange?()
        }
    }

    func restoreVerticalGestureSetting() {
        guard verticalGesture.hasBackup else {
            infoAlert(title: "Nothing to restore", text: "No saved trackpad setting was found.")
            return
        }
        let ok = verticalGesture.restore()
        settings.manageVerticalGesture = false
        infoAlert(title: ok ? "Restored" : "Restore failed",
                  text: ok ? "Mission Control / App Exposé were restored to three fingers. Log out and back in for it to take effect."
                           : "Could not restore the setting. Adjust it manually in System Settings ▸ Trackpad.")
        onStateChange?()
    }

    // The vertical-gesture relocation is intentionally not restored on quit (see AppDelegate):
    // it needs a re-login to take effect, so reverting on logout would prevent it ever engaging.
    // Restore happens only on explicit opt-out (`handleVerticalGestureToggle`) or the menu action.

    // MARK: - Four-finger launcher opt-in

    private let didPromptLauncherKey = "didPromptLauncher"

    /// React to the Settings toggle: enabling frees the native four-finger swipes, disabling
    /// restores them. The persisted initial value is skipped (`dropFirst`); launch-apply is handled
    /// in `start()`. Mirrors `observeVerticalGestureToggle`.
    private func observeLauncherToggle() {
        settings.$enableLauncher
            .dropFirst()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.handleLauncherToggle(enabled) }
            }
            .store(in: &cancellables)
    }

    private func handleLauncherToggle(_ enabled: Bool) {
        if enabled {
            applyLauncherGesture()
        } else if fourFingerGesture.hasBackup {
            _ = fourFingerGesture.restore()
        }
        refreshRowSwitchingGate()
    }

    private func applyLauncherGestureOnLaunchIfManaged() {
        guard settings.enableLauncher else { return }
        applyLauncherGesture()
    }

    /// Free the native four-finger horizontal/vertical swipes; surface a non-fatal warning if the
    /// write failed (e.g. a managed preference). A no-op when already free.
    private func applyLauncherGesture() {
        guard !fourFingerGesture.freeFourFingerSwipes() else { return }
        infoAlert(
            title: "Couldn't change the trackpad setting",
            text: """
            Freeing the four-finger swipes for the launcher didn't succeed. If your Mac is managed \
            (MDM), this setting may be locked. You can change it manually in System Settings ▸ \
            Trackpad ▸ More Gestures (turn off the four-finger swipe gestures).
            """
        )
    }

    /// First-run consent, mirroring the vertical-gesture prompt: ask once, only when the four-finger
    /// gesture is still claimed by the OS and the user hasn't already opted in.
    private func maybePromptLauncher() {
        let alreadyPrompted = UserDefaults.standard.bool(forKey: didPromptLauncherKey)
        guard !alreadyPrompted, !settings.enableLauncher, fourFingerGesture.isClaimed else { return }
        UserDefaults.standard.set(true, forKey: didPromptLauncherKey)
        promptLauncherSetup()
    }

    func promptLauncherSetup() {
        // "Already set up" only when the launcher is on AND the relocation is effective. With the
        // trackpad keys at their factory default (absent), the gesture still needs freeing, so we
        // offer rather than reporting it as done.
        if settings.enableLauncher && fourFingerGesture.isEffectivelyFree {
            infoAlert(title: "Already set up",
                      text: "Four-finger swipes are already free and the launcher is on.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable the four-finger launcher?"
        alert.informativeText = """
        Open a launcher of your favorite apps, scripts, and presets by sliding four fingers \
        horizontally — then dwell on an item and lift to fire it. To free that gesture, this app \
        turns off the native four-finger swipe gestures (full-screen-app swipe and four-finger \
        Mission Control).

        Mission Control / App Exposé still work via three-finger up/down. Your previous setting is \
        saved — turn the launcher off (or pick Restore from the menu) to put it back. A \
        logout/restart is required for the change to take effect, and it stays applied across \
        logins until you turn it off.
        """
        alert.addButton(withTitle: "Enable the launcher")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            settings.enableLauncher = true   // observer applies the change and persists the opt-in
            infoAlert(
                title: "Almost there — restart to finish",
                text: "Log out and back in (or restart) so macOS frees the four-finger swipes. The launcher turns on automatically after that."
            )
            onStateChange?()
        }
    }

    func restoreLauncherGestureSetting() {
        guard fourFingerGesture.hasBackup else {
            infoAlert(title: "Nothing to restore", text: "No saved trackpad setting was found.")
            return
        }
        let ok = fourFingerGesture.restore()
        settings.enableLauncher = false
        infoAlert(title: ok ? "Restored" : "Restore failed",
                  text: ok ? "The native four-finger swipe gestures were restored. Log out and back in for it to take effect."
                           : "Could not restore the setting. Adjust it manually in System Settings ▸ Trackpad.")
        onStateChange?()
    }

    /// Open the favorites editor — the "small IDE" for arranging launcher bands and items.
    func showFavoritesEditor() {
        if favoritesEditorWindow == nil {
            let host = NSHostingController(rootView: FavoritesEditorView(store: favoritesStore))
            let window = NSWindow(contentViewController: host)
            window.title = "Favorites"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            // Persist position + size across launches/builds (stored in UserDefaults by the autosave
            // name). Restore any saved frame; only center on the very first run.
            let restored = window.setFrameUsingName("FavoritesEditorWindow")
            window.setFrameAutosaveName("FavoritesEditorWindow")
            if !restored { window.center() }
            favoritesEditorWindow = window
        }
        present(favoritesEditorWindow)
    }

    /// Menu-bar quick-add: append the frontmost app to a band without opening the editor (10.2).
    func addFrontAppToBand(_ bandID: UUID) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let url = app.bundleURL else {
            infoAlert(title: "No front app", text: "Couldn't determine the frontmost application.")
            return
        }
        let title = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        favoritesStore.addItem(LaunchItem(title: title, icon: .appDefault,
                                          kind: .app(bundleURL: url, strategy: nil)), toBand: bandID)
    }

    /// Bands for the status-menu quick-add submenu.
    var favoriteBands: [ContextBand] { favoritesStore.favorites.bands }

    // MARK: - Windows

    func showSettings() {
        // Rebuild the root view on each open so the actions are wired and `showRestoreMissionControl`
        // reflects the current backup state (Setup & Permissions and the MC restore live here now).
        let view = SettingsView(
            settings: settings,
            onOpenSetup: { [weak self] in self?.showOnboarding() },
            onRestoreMissionControl: { [weak self] in self?.restoreVerticalGestureSetting() },
            showRestoreMissionControl: verticalGesture.hasBackup,
            onClearClipboard: { [weak self] includingPinned in self?.clipboardStore.clear(includingPinned: includingPinned) },
            aiCommandStore: aiCommandStore,
            modelManager: modelManager,
            onDownloadModel: { [weak self] in self?.downloadAIModel() }
        )
        if let settingsWindow {
            (settingsWindow.contentViewController as? NSHostingController<SettingsView>)?.rootView = view
        } else {
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        permissions.refresh()
        if onboardingWindow == nil {
            let view = OnboardingView(
                permissions: permissions,
                trackpadClaimed: trackpadConfig.isClaimed,
                trackpadNeedsRelogin: trackpadConfig.needsReloginWarning,
                spacesAutoRearrangeOn: spacesRearrange.isAutoRearrangeOn,
                spaceRowSwitchingOn: settings.manageVerticalGesture,
                spaceRowNeedsRelogin: verticalGesture.needsReloginWarning,
                launcherOn: settings.enableLauncher,
                launcherNeedsRelogin: fourFingerGesture.needsReloginWarning,
                onSetupNativeGesture: { [weak self] in self?.promptNativeGestureSetup() },
                onKeepSpacesFixed: { [weak self] in self?.promptSpacesRearrangeSetup() },
                onEnableSpaceRowSwitching: { [weak self] in self?.promptVerticalGestureSetup() },
                onEnableLauncher: { [weak self] in self?.promptLauncherSetup() },
                onRefresh: { [weak self] in self?.permissions.refresh() }
            )
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Windows that persist their own frame (a non-empty autosave name) keep their saved position;
        // only center the transient ones (Settings / Setup).
        if window.frameAutosaveName.isEmpty { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func infoAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Order the overlay out (idempotent) — used on resign-active to avoid a leaked panel.
    func hideOverlay() {
        overlay.hide()
    }
}
