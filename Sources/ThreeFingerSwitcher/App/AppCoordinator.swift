import AppKit
import Combine
import ServiceManagement
import SwiftUI
import DeviceLinkProtocol

/// Owns and wires the whole pipeline: touch → recognizer → overlay highlight → commit raise.
/// Also drives onboarding, settings, and the native-gesture consent flow.
@MainActor
final class AppCoordinator: GestureRecognizerDelegate {
    let settings = AppSettings.shared
    let permissions = PermissionsService()
    let trackpadConfig = TrackpadGestureConfig()
    /// First Touch wizard progress (persisted stage machine + the legacy-flag bridge).
    let firstRun = FirstRunStore()

    private let mru = MRUTracker()
    private let focus = WindowFocusTracker()
    private lazy var windowService = WindowService(mru: mru, focus: focus, settings: settings)
    private let thumbnails = ThumbnailService()
    private let overlay = OverlayController()
    /// The transient on-receive notch HUD (success/failure feedback for inbound device-link items).
    private lazy var receiveHUD = ReceiveHUDController()
    private let touchEngine = TouchEngine()
    private lazy var recognizer = GestureRecognizer(settings: settings)
    let spacesRearrange = SpacesRearrangeConfig()
    let verticalGesture = VerticalGestureConfig()
    let fourFingerGesture = FourFingerGestureConfig()
    /// Persisted pending-re-login markers (audit-session-keyed). Stateless over UserDefaults, so
    /// this instance and the configs' own instances observe the same state.
    private let reloginMarkers = ReloginMarkers()
    /// The ONE write path for trackpad relocations: computes final key values from the full active
    /// feature set (resolving the shared four-finger keys) and snapshots pristine backups first.
    private let relocationApplier = RelocationApplier()
    private let scrollTap = ScrollEventTap()
    private var cancellables: Set<AnyCancellable> = []

    // Dock-hover window previews (opt-in; the switcher "from another angle"). Reuses windowService for
    // enumeration + raise; owns its own cursor monitor, Dock AX reader, thumbnails, and overlay.
    private lazy var dockPreviewController = DockPreviewController(
        cursor: GlobalCursorMonitor(),
        reader: AXDockReader(),
        windowService: windowService,
        switcherThumbnails: thumbnails
    )

    // Four-finger launcher.
    private let favoritesStore = FavoritesStore.shared
    private let launcherOverlay = LauncherOverlayController()
    /// The interactive screen-region picker (vision capture). Shown after a `screenRegion` AI command
    /// dismisses the launcher; on a drag it captures the region and re-opens the canvas, on a
    /// click-without-drag it cancels (`screen-region-picker`).
    private let regionPicker = RegionPickerOverlay()
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
        onAICommand: { [weak self] command in self?.aiCommandExecutor.fire(command) },
        // Persist the folder picked at fire time for a choose-folder-at-launch item, so its chooser
        // re-opens there next time (the item is the single source of truth for its last-used folder).
        onPromptedFolderChosen: { [weak self] itemID, bandID, folder in
            self?.favoritesStore.updateItem(itemID, inBand: bandID) { $0.kind = $0.kind.withLastFolder(folder) }
        }
    )

    /// Frontmost app captured at launcher-open time (target for `.action(.closeFrontWindow)`).
    private var capturedFrontApp: NSRunningApplication?

    // Files band (opt-in; the synthetic Files band + the on-demand directory navigator). Like Clipboard,
    // the band is synthetic and ephemeral — projected fresh on every launcher open from the current
    // directory column, never persisted into Favorites.
    /// Opens a chosen Files entry (a file in its default app / via Open-With, a folder as a Finder window)
    /// as a defusable held open (design D7). Reuses `capturedFrontApp` exactly like `LaunchService` /
    /// `SelectionService`, so the open targets the app the user was looking at before the non-activating
    /// overlay appeared. `SystemFileWorkspace` maps every OS error to a typed `FileActionError` at the
    /// boundary, surfaced only through the service's bounded `.failed` state.
    private lazy var fileOpenService = FileOpenService(
        workspace: SystemFileWorkspace(),
        activateFrontAppContext: { [weak self] in
            // Re-assert the captured front app before the open fires (mirrors `SelectionService`), so the
            // opened document lands in the context the user was looking at, not the frontmost app at fire
            // time. The `activate` result is best-effort and intentionally discarded.
            _ = self?.capturedFrontApp?.activate(options: [])
        }
    )

    /// The last Files open that was fired (default open / Open-With), captured so the failure row's **Retry**
    /// can re-fire the identical open through `FileOpenService`. Set in `filesOpen`/`filesOpenWith`, replaced
    /// by each new open; nil until the first Files open. A closure (not the entry) so the same defusable
    /// prepare→commit path runs verbatim on a retry.
    private var lastFilesOpen: (() -> Void)?

    /// When the Open-With app grid was reached via the action menu's "Open in ▸", the entry it was opened
    /// for — so a discard backs out to the **action menu** (one level), not straight to the folder list.
    /// Nil when the picker isn't open or was opened directly.
    private var filesPickerOriginEntry: FileEntry?

    /// A pending **Cut** (move-on-Paste, Finder ⌘X): the file(s) cut and the pasteboard `changeCount` at cut
    /// time. The next `pasteInto` MOVES them only while `NSPasteboard.general.changeCount` still equals this
    /// (the pasteboard is still that cut); a Copy or any other write since bumps the count → the cut is
    /// superseded and Paste copies. Cleared after the move (or when superseded). Coordinator state, so a cut
    /// persists across launcher sessions until consumed — matching Finder.
    private var pendingCut: (sources: [URL], changeCount: Int)?

    // Clipboard history (opt-in; the synthetic Clipboard band + the background recorder).
    private let clipboardStore = ClipboardStore.shared
    private lazy var clipboardMonitor = ClipboardMonitor(store: clipboardStore)

    // Device link (opt-in; the iPhone↔Mac local-network bridge). Received items are adapted into the
    // clipboard store (so they appear in the Clipboard band); the service is started/stopped by the
    // `enableDeviceLink` toggle, like the clipboard recorder. Security (pinned TLS) is a pairing follow-up.
    private var deviceLinkService: DeviceLinkService?
    private let pairedDeviceStore = PairedDeviceStore(directory: PairedDeviceStore.defaultDirectory())
    /// Host coordinator for QR pairing (show a code on the Hub, accept a scanner, pin it).
    private lazy var macPairingCoordinator = MacPairingCoordinator(store: pairedDeviceStore, identity: localDeviceIdentity)
    /// Received-item adapter: files land in a `received/` inbox beside the clipboard store.
    private lazy var linkInboundAdapter = LinkInboundAdapter(
        inboxDirectory: ClipboardStore.defaultDirectory().appendingPathComponent("inbox", isDirectory: true))
    private let linkOutboundAdapter = LinkOutboundAdapter()
    /// This Mac's stable link identity (id persisted so a peer's pin survives relaunches; name = host name).
    private var localDeviceIdentity: DeviceIdentity {
        let key = "deviceLinkLocalID"
        let id = UserDefaults.standard.string(forKey: key) ?? {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: key)
            return fresh
        }()
        return DeviceIdentity(id: id, name: Host.current().localizedName ?? "Mac")
    }

    // AI commands (opt-in; the on-device model + the streaming canvas). AI commands now live as
    // persisted items inside the favorites bands (configuration-hub fold-in), so there is no separate
    // command store — a fired `.aiCommand` item carries its `AICommand` to the executor directly.
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
    private lazy var taskDispatcher = TaskDispatcher(
        modelManager: modelManager,
        permissions: permissions
    )
    /// Orchestrates one AI command fire end-to-end (acquire → stream → commit), exposing the observable
    /// state the launcher's preview canvas binds to. The context provider supplies the captured app
    /// name so `{app}` resolves; input is filled by acquisition.
    private lazy var aiCommandExecutor = AICommandExecutor(
        modelManager: modelManager,
        selection: selectionService,
        dispatcher: taskDispatcher,
        contextProvider: { [weak self] in
            FireContext(capturedAppName: self?.capturedFrontApp?.localizedName)
        },
        loadLanguage: { [weak self] id in self?.settings.rememberedLanguage(for: id) },
        saveLanguage: { [weak self] id, lang in self?.settings.rememberLanguage(lang, for: id) },
        reasoning: { [weak self] in self?.settings.aiReasoningEnabled ?? false }
    )

    // Per-app keyboard language (opt-in; remembers and re-selects the input source per app/site). Gated
    // on its OWN toggle, independent of the switcher master enable. The store holds the learned
    // context-key → source map; the service ties it to the pure policy and the Carbon
    // `InputSourceController` seam. The `ContextResolver` maps the frontmost app to that context key
    // (a bundle id, or `bundleID|host` for a supported browser when the per-site sub-toggle is on); the
    // service learns/applies against whatever key it returns (design D1).
    private let keyboardLanguageStore = KeyboardLanguageStore.shared
    private lazy var keyboardLanguageContextResolver = ContextResolver(
        // The active host reader: Apple Events (exact per-host, incl. Safari) when "allow browser control"
        // is on, else Accessibility (no new permission). Swapped in place when that opt-in flips (see
        // `observeKeyboardLanguagePerSiteToggle`). Read once here for the initial provider.
        hostProvider: settings.keyboardLanguageAllowBrowserControl
            ? AppleEventsHostProvider() : AXHostProvider(),
        // Read the per-site sub-toggle live (a closure, not a captured bool) so flipping it takes effect on
        // the very next resolution. Off ⇒ every app — browsers included — resolves to its bundle id, so the
        // per-app path stays byte-for-byte the established behavior.
        perSiteEnabled: { [weak self] in self?.settings.keyboardLanguagePerSiteEnabled ?? false }
    )

    /// The within-browser host-change signal (design D4): while a supported browser is frontmost it ticks
    /// and nudges the service to re-resolve its context, so a mid-tab host change is handled exactly like
    /// an app switch (which emits no `didActivateApplication`). Gated on BOTH the master keyboard-language
    /// toggle AND the per-site sub-toggle; fully inert otherwise.
    private lazy var keyboardLanguageBrowserMonitor = BrowserContextMonitor(
        isSupportedBrowserFront: {
            BrowserRegistry.isSupported(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        },
        onTick: { [weak self] in self?.keyboardLanguageService.reevaluate() }
    )
    private lazy var keyboardLanguageService = KeyboardLanguageService(
        store: keyboardLanguageStore,
        controller: CarbonInputSourceController(),
        globalDefault: { [weak self] in
            // Normalize the picker's "None" (empty string) to nil so an unset default reads as "no default".
            let value = self?.settings.keyboardLanguageDefaultSourceID
            return (value?.isEmpty == false) ? value : nil
        },
        currentContextID: { [weak self] in
            self?.keyboardLanguageContextResolver.contextID(
                forFrontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        }
    )

    /// Whether the app currently has Mission Control open (it triggers MC itself via the vertical
    /// gesture). Lets the switcher float above MC and a commit dismiss it before raising.
    private var missionControlOpen = false

    /// Drives the periodic preview refresh: while the switcher overlay is open, each tick re-captures the
    /// whole VISIBLE Space-row (not just the highlighted card) on a slow cadence, so previews stay fresh and
    /// any slipped-through frame self-heals on the next sweep. Captures self-pace below this interval via
    /// ThumbnailService's `inFlight` guard (a window whose capture is still in flight is skipped, not queued).
    private var previewRefreshTimer: Timer?
    static let previewRefreshInterval: TimeInterval = 0.8

    // The unified configuration Hub: one reusable window, its navigation state, and the wiring context.
    private var hubWindow: NSWindow?
    private let hubNav = HubNavigation()
    /// The Hub gesture-preview rehearse seam (§2.3 / §2.4): at most one previewed page registers as the
    /// active rehearse target; this controller publishes the live fingertips and the ownership verdict.
    /// Shared between the touch feed (below) and every `HubGesturePreview` via `HubContext`.
    private let hubRehearse = HubRehearseController()
    private lazy var hubContext: HubContext = makeHubContext()
    /// The Space the Hub was last presented on (captured in `showHub`). Used to place the synthetic
    /// Hub switcher entry on its own Space-row — the Hub deliberately does NOT join all Spaces, so it
    /// stays where it was opened and the card lands in the right row (committing it raises across
    /// Spaces like any other off-Space window).
    private var hubSpaceID: CGSSpaceID?

    private(set) var isEnabled = false
    var isTrackpadAvailable: Bool { touchEngine.isAvailable }

    var onStateChange: (() -> Void)?

    /// The wizard's menu-bar moment: pulses the real status-item mark (wired by
    /// `StatusItemController`) so the wizard can point at the actual pixel the user returns to.
    var onMenuBarPulse: (() -> Void)?

    /// Live finger count from the most recent touch frame; drives the scroll tap's consume rule
    /// (the switcher owns all three-finger scroll so it never leaks to the background).
    private var currentFingerCount = 0

    /// Pure decision for the scroll tap: consume (swallow) scroll while three or more fingers are
    /// down OR while the launcher overlay is open OR while the switcher overlay is open. The
    /// overlay-open clauses capture the two-finger movement that drives launcher / switcher
    /// navigation (after a three- or four-finger trigger relaxes to two) so it doesn't scroll the
    /// window underneath; with both overlays closed it reverts to the `≥3`-fingers rule, leaving
    /// normal two-finger scroll alone.
    ///
    /// `3+` finger is always consumed (gesture territory — a 4-finger resolve swipe's incidental
    /// scroll must not leak to the front app); the normal launcher / switcher still consume 1-2
    /// finger so stray scroll doesn't leak during nav; but while the AI **canvas** is active we
    /// DON'T consume 1-2 finger scroll, so it reaches the canvas's SwiftUI ScrollView (the panel is
    /// key + interactive and under the cursor) to scroll the thinking / response.
    static func shouldConsumeScroll(fingerCount: Int, launcherOpen: Bool, switcherOpen: Bool, canvasActive: Bool) -> Bool {
        fingerCount >= 3 || ((launcherOpen || switcherOpen) && !canvasActive)
    }

    /// Read-only tap on the touch stream for the wizard's live-hand act (the recognizer path is
    /// untouched; this only mirrors frames).
    var onWizardTouchFrame: ((TouchFrame) -> Void)?

    /// Tap on the touch stream for the Hub's gesture-preview **rehearse** seam (§2.3). Unlike the wizard
    /// mirror this is NOT read-only: while a Hub preview is the active rehearse target with ≥2 fingers
    /// down, the frame is routed here and the recognizer is SKIPPED (`hubPreviewOwnsGestures`), so
    /// rehearsing never fires the real feature. `HubRehearseController` extracts the live fingertips.
    var onHubPreviewTouchFrame: ((TouchFrame) -> Void)?

    /// The Hub-preview analogue of `wizardOwnsGestures`: true while a Hub preview is being rehearsed on
    /// the real trackpad (a preview is the active target AND ≥2 fingers are down). When true, the touch
    /// frame is routed to the preview and `recognizer.feed(_:)` is skipped — the gate closes (and normal
    /// feeding resumes) the instant the fingers lift or the preview loses focus. Guarded against the
    /// wizard so the two ownerships never both apply (their windows are never up together, but defensive).
    ///
    /// FAIL-SAFE on the Hub window's key state: suppression can ONLY happen while the Hub is the **key
    /// window** (the user is actively in front of it, i.e. genuinely rehearsing). If the Hub is closed or
    /// merely backgrounded, this is false no matter what — so a registration that went stale (SwiftUI
    /// `.onDisappear` is unreliable on window close) can never keep swallowing the switcher/launcher after
    /// the Hub is gone. Reading `isKeyWindow` here is consistent with `wizardOwnsGestures` reading
    /// `wizardWindow?.isVisible` on the same frame path.
    private var hubPreviewOwnsGestures: Bool {
        guard hubWindow?.isKeyWindow == true else { return false }
        return !wizardOwnsGestures && hubRehearse.ownsGestures
    }

    init() {
        recognizer.delegate = self
        touchEngine.onFrame = { [weak self] frame in
            guard let self else { return }
            self.currentFingerCount = frame.fingerCount
            // The wizard's live-hand act still mirrors every frame (read-only). The Hub rehearse seam
            // also always sees the frame (so its ≥2-finger gate + lift-clear stay accurate), but it
            // additionally OWNS the gesture while rehearsing: when it does, the real recognizer is
            // skipped so the rehearsal can't open the launcher / switch a window / fire a command.
            self.onWizardTouchFrame?(frame)
            self.onHubPreviewTouchFrame?(frame)
            guard !self.hubPreviewOwnsGestures else { return }
            self.recognizer.feed(frame)
        }
        scrollTap.consumePredicate = { [weak self] in
            guard let self else { return false }
            return Self.shouldConsumeScroll(fingerCount: self.currentFingerCount,
                                            launcherOpen: self.launcherOverlay.isVisible,
                                            switcherOpen: self.overlay.isVisible,
                                            canvasActive: self.launcherOverlay.canvasActive)
        }
        thumbnails.onThumbnail = { [weak self] id, image in
            self?.overlay.model.setThumbnail(image, for: id)
            // The wizard's demo strip listens along while it lives (the post-Screen-Recording reveal).
            self?.wizardModel?.demo.setThumbnail(image, for: id)
        }
        launcherOverlay.onFire = { [weak self] item, band in self?.launchService.fire(item, inBand: band) }
        launcherOverlay.onTogglePin = { [weak self] item in
            guard case let .clipboardEntry(entry) = item.kind else { return }
            self?.clipboardStore.togglePin(id: entry.id)
        }
        // AI preview canvas: the executor it observes, and the two-stage commit / discard gestures.
        launcherOverlay.executor = aiCommandExecutor
        // Enable/download wiring for the canvas's `.unavailable` state (fired an AI item while AI is
        // off or the model isn't downloaded → the canvas offers Enable/Download + a model picker).
        launcherOverlay.aiAvailability = AICanvasAvailability(
            settings: settings,
            models: modelManager,
            onDownload: { [weak self] in self?.downloadAIModel() }
        )
        launcherOverlay.onCommitCanvas = { [weak self] in
            // A fresh four-finger DOWN swipe commits: route the ready result per the command's output
            // target (or fire the reviewed side effect). Errors surface in the executor's `.failed`
            // state (the canvas is already dismissed by the controller, but the executor records them).
            Task { @MainActor in try? await self?.aiCommandExecutor.commit() }
        }
        launcherOverlay.onDiscardCanvas = { [weak self] in self?.aiCommandExecutor.cancel() }
        // Screen-region (vision) command: the launcher already dismissed to reveal the desktop. Run the
        // interactive region picker; on a drag, capture the designated region and re-open the canvas
        // firing the executor with the captured image (the executor maps a permission gap → .failed and an
        // unavailable capture → .noInput). A click-without-drag cancels — no canvas, nothing generated; the
        // captured front app already retains focus (both the launcher and the picker are non-activating).
        launcherOverlay.onScreenRegionCommand = { [weak self] command in
            guard let self else { return }
            self.regionPicker.show { [weak self] resolution in
                guard let self else { return }
                switch resolution {
                case .cancel:
                    break   // defused — the front app was never deactivated, so there is nothing to restore
                case let .region(rect):
                    Task { @MainActor in
                        let outcome = await self.selectionService.captureScreenRegion(rect)
                        self.launcherOverlay.showCanvas(for: command)
                        self.aiCommandExecutor.fire(command, screenCapture: outcome)
                    }
                }
            }
        }
        // When the canvas opens, put the recognizer in canvas-resolution mode so a FRESH four-finger
        // swipe resolves it (horizontal = discard, down = apply) instead of re-opening the launcher.
        launcherOverlay.onCanvasStateChanged = { [weak self] active in
            self?.recognizer.launcherCanvasResolutionActive = active
        }
        // When the Files band becomes current, put the recognizer in the sustained Files-drill mode so a
        // FRESH contact drills the directory tree (horizontal = depth, vertical = highlight) and a
        // resolving lift opens / Open-Withs the highlighted entry — instead of stepping the grid. Mirrors
        // the canvas-resolution wiring above.
        launcherOverlay.onFilesColumnStateChanged = { [weak self] active in
            self?.recognizer.filesDrillActive = active
        }
        // Persist the per-root remembered deepest location as the Files navigator drills (so the next open
        // restores where the user left each root). Keyed/valued by standardized path.
        launcherOverlay.model.onFilesRememberLocation = { [weak self] path, rootPath in
            self?.settings.rememberLocation(path, forRoot: rootPath)
        }
        // The Files-band failure row's Retry re-fires the last open through `FileOpenService` (which the
        // state sink mirrors back into `model.filesOpenFailure`), so a transient open failure can be retried
        // without re-navigating. No-op when nothing was opened yet.
        launcherOverlay.model.onFilesRetryOpen = { [weak self] in self?.retryLastFilesOpen() }
        observeSleepWake()
        observeEnabledToggle()
        observeSpacesRearrangeToggle()
        observeVerticalGestureToggle()
        observeLauncherToggle()
        observeClipboardToggle()
        observeDeviceLinkToggle()
        observeFileOpenState()
        observeAICommandsToggle()
        observeKeyboardLanguageToggle()
        observeKeyboardLanguagePerSiteToggle()
        observeKeyboardLanguageBrowserControlToggle()
        observeDockPreviewsToggle()
        reconcileAIModelAtLaunch()
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
        // Sweep stale pending-re-login markers FIRST (a marker from a previous login session means
        // the re-login happened — the relocation is live), so the apply-on-launch no-ops below and
        // the effectiveness gates read accurate pending state from the first gesture.
        reloginMarkers.sweepAtLaunch()
        // Reapply the vertical-gesture relocation before enabling so the recognizer's row-switching
        // gate reflects the effective state from the first gesture.
        applyVerticalGestureOnLaunchIfManaged()
        applyLauncherGestureOnLaunchIfManaged()
        if settings.enabled { enable() }
        // Per-app keyboard language is gated ONLY on its own toggle, independent of the switcher master
        // enable above — it observes app activations / input-source changes regardless (design D9).
        if settings.keyboardLanguageEnabled { keyboardLanguageService.start() }
        // The within-browser host-change poll is gated on the master toggle AND the per-site sub-toggle.
        refreshKeyboardLanguageBrowserMonitor()
        // Dock-hover previews are gated ONLY on their own opt-in (independent of the switcher master
        // enable, like per-app keyboard language): a cursor-driven surface, no gesture involved.
        dockPreviewController.setEnabled(settings.showDockPreviews)
        refreshRowSwitchingGate()
        refreshClipboardMonitor()
        applySpacesRearrangeOnLaunchIfManaged()
        // Render the switcher overlay once, off-screen, so the first trigger's continuous open-swipe
        // animates the reel smoothly instead of stalling on a cold hosting view (first-session only).
        overlay.prewarm()
        // Pay ScreenCaptureKit's cold-start cost in the background NOW, so the first switcher session's
        // captures don't stall the reel slide mid-animation (SCK stays warm process-wide thereafter —
        // the reason only the first run stutters). No-op without Screen Recording permission.
        Task { await thumbnails.warmUp() }
        // The First Touch wizard IS the first-run flow: it replaced the four one-shot consent
        // alerts (didPrompt* — set on the wizard's completion so they can never fire) and the
        // open-Hub-on-Setup fallback. Resume-aware: any interruption (relaunch, re-login, plain
        // quit) reopens at the right act.
        maybeShowFirstTouchWizard()
    }

    // MARK: - Enable / disable

    func enable() {
        guard !isEnabled else { return }
        permissions.refresh()
        mru.start()
        focus.start()
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
        focus.stop()
        overlay.hide()
        stopPreviewRefresh()
        launcherOverlay.cancel()
        receiveHUD.hide()
        clipboardMonitor.stop()
        isEnabled = false
        settings.enabled = false
        onStateChange?()
    }

    func toggleEnabled() { isEnabled ? disable() : enable() }

    /// Guards `observeEnabledToggle` against re-entrancy: `enable()`/`disable()` themselves set
    /// `settings.enabled`, which re-emits on this publisher. Without the guard, the no-trackpad case
    /// (where `enable()` cannot set `isEnabled = true`, so its `guard !isEnabled` never trips) would
    /// recurse forever.
    private var applyingEnabledToggle = false

    /// React to the switcher master toggle bound directly to `settings.enabled` (the Hub's Overview
    /// and Switcher pages): start/stop the engine to match, so flipping it actually takes effect (a raw
    /// binding only wrote the pref). Uses the EMITTED value (the `@Published` willSet reports the new
    /// value to the sink). `dropFirst()` skips the persisted initial value (launch is handled in
    /// `start()`); the re-entrancy guard absorbs the `settings.enabled =` that `enable()`/`disable()`
    /// perform internally.
    private func observeEnabledToggle() {
        settings.$enabled
            .dropFirst()
            .sink { [weak self] on in
                // Defer off the `willSet` emission so the master toggle updates in place immediately;
                // enabling/disabling starts or tears down the touch engine + taps, which otherwise stalled
                // the SwiftUI render until the page was rebuilt. See observeSpacesRearrangeToggle.
                DispatchQueue.main.async {
                    guard let self, !self.applyingEnabledToggle else { return }
                    self.applyingEnabledToggle = true
                    if on { self.enable() } else { self.disable() }
                    self.applyingEnabledToggle = false
                }
            }
            .store(in: &cancellables)
    }

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
        stopPreviewRefresh()
        launcherOverlay.cancel()
        // CRITICAL: stop the multitouch listener NOW, while its CFRunLoopSource is still valid. The OS
        // invalidates the device source during system sleep; calling `manager.stopListening()` AFTER
        // wake then traps on a freed source (EXC_BREAKPOINT in MTDeviceStop — observed during long
        // model downloads that span a sleep). Stopping pre-sleep makes the post-wake `stop()` a no-op,
        // and `restartTouchEngineAfterWake()` attaches a fresh listener on `didWake`.
        touchEngine.stop()
        // Tear down the focus tracker's AX observer (its main-run-loop source) pre-sleep, alongside
        // the multitouch listener; `restartTouchEngineAfterWake()` re-attaches a fresh one on wake.
        focus.stop()
    }

    /// Re-subscribe the multitouch listener after wake. Idempotent and guarded against
    /// double-start: stop() / start() are no-ops when already in the target state.
    private func restartTouchEngineAfterWake() {
        guard isEnabled else { return }
        recognizer.reset()
        touchEngine.stop()
        touchEngine.start()
        // Re-attach the focus tracker's AX observer torn down in `handleWillSleep`. Idempotent.
        focus.stop()
        focus.start()
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
        // While the wizard is on stage it owns the trackpad: its demo strip is the only thing
        // that responds (the live-hand act mirrors the same frames), so the real overlay would
        // double the scene. Commits stay inert via the first-run Accessibility gate.
        guard !wizardOwnsGestures else { return }
        var windows = windowService.snapshot()
        // Inject the configuration Hub as a synthetic switcher entry whenever it is open. The snapshot
        // filters out our own PID (so the overlay panels never leak); the Hub is the one window we add
        // back, on purpose, icon-only, on the Space it was opened on. Accessory mode is unchanged.
        if let hub = hubSwitcherEntry(snapshot: windows) {
            windows.append(hub)
        }
        guard !windows.isEmpty else { return }
        let grid = SpaceGrouping.group(windows)
        // When the app has Mission Control open, float the overlay above it (otherwise it renders
        // behind the MC windows). The elevated config is scoped to this case in `OverlayController`.
        overlay.show(rows: grid.rows, labels: grid.labels, startRow: grid.startRow, column: 0,
                     aboveMissionControl: missionControlOpen,
                     // Opted in but the relocation hasn't survived its re-login yet: the row dots
                     // dim with a pending glyph so the gated vertical axis explains itself.
                     rowSwitchingPending: settings.manageVerticalGesture && !isSpaceRowSwitchingEffective,
                     windowScale: CGFloat(settings.switcherWindowScale))
        seedAllRows()         // every Space's cached previews present up front (no first-visit rebuild)
        prefetchCurrentRow()  // immediate capture of the whole visible row (no highlight needed)
        startPreviewRefresh()
    }

    /// Build the synthetic Hub switcher entry from live state, or `nil` when the Hub isn't open. Reads
    /// the current Space so the card can fall back to the active row when no other window shares the
    /// Hub's Space. The app name (and so the card title) derives from the bundle/ProcessInfo with a
    /// literal fallback.
    private func hubSwitcherEntry(snapshot: [WindowInfo]) -> WindowInfo? {
        guard let hubWindow, hubWindow.isVisible else { return nil }
        let model = SpaceService.currentModel()
        let currentSpaceID = model?.currentSpaceIDs.first
        let currentSpaceIndex = currentSpaceID.flatMap { model?.indexBySpace[$0] } ?? 0
        return HubSwitcherEntry.make(
            isVisible: true,
            windowNumber: hubWindow.windowNumber,
            appName: Self.appDisplayName,
            icon: NSApp.applicationIconImage,
            hubSpaceID: hubSpaceID,
            snapshot: snapshot,
            currentSpaceID: currentSpaceID,
            currentSpaceIndex: currentSpaceIndex
        )
    }

    /// The app's display name (drives the Hub card title "<name> Hub"), derived from the bundle, then
    /// ProcessInfo, with the literal fallback the design specifies.
    private static var appDisplayName: String {
        let info = Bundle.main.infoDictionary
        if let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String),
           !name.isEmpty {
            return name
        }
        let proc = ProcessInfo.processInfo.processName
        return proc.isEmpty ? "ThreeFingerSwitcher" : proc
    }

    func gestureDidStep(_ direction: Int) {
        guard overlay.isVisible else { return }
        guard overlay.model.windows.count > 0 else { return }
        // Horizontal scrub moves WITHIN the current visual row of the grid (the model clamps/wraps).
        overlay.moveHorizontal(direction, wrap: settings.wrapAtEnds)
    }

    func gestureDidStepRow(_ direction: Int) {
        guard overlay.isVisible else { return }
        // Vertical scrub navigates the grid's visual rows; only a top/bottom-edge crossing switches Space.
        switch overlay.moveVertical(direction) {
        case .moved:
            break   // highlight only; the periodic sweep keeps the visible row's previews fresh
        case .atEdge(let spaceDelta):
            switchSpace(by: spaceDelta)
        }
    }

    /// Switch to an adjacent Space-row (from a grid-edge vertical scrub), clamping or wrapping per the
    /// setting, and refresh thumbnails/live preview for the new Space exactly as before.
    private func switchSpace(by delta: Int) {
        let count = overlay.rowCount
        guard count > 1 else { return }
        var row = overlay.currentRow + delta
        if settings.wrapAtEnds {
            row = ((row % count) + count) % count
        } else {
            row = min(max(row, 0), count - 1)
        }
        guard row != overlay.currentRow else { return }
        overlay.updateRow(row)
        prefetchCurrentRow()   // seed the new Space's cached thumbnails now + immediately re-capture the row
        // …then freeze: async captures landing during the slide are buffered (so they can't snap it) and
        // cut in once it settles. Must follow the seed (done inside prefetchCurrentRow) and precede the
        // captures it kicks.
        overlay.beginSlideFreeze()
    }

    func gestureDidTriggerMissionControl(up: Bool) {
        guard !wizardOwnsGestures else { return }   // no OS overviews over the wizard's stage
        // A fresh three-finger vertical swipe while we own the gesture: open the OS overview
        // ourselves (the native gesture is disabled to a scroll, which the scroll tap consumes).
        MissionControl.trigger(up: up)
        // Track Mission Control's open state so a following switcher can float above it and a commit
        // can dismiss it. `up` toggles MC; App Exposé (down) is a different overview, so MC is no
        // longer considered open.
        missionControlOpen = up ? !missionControlOpen : false
    }

    private func prefetchCurrentRow() {
        // Never attempt a ScreenCaptureKit capture of our OWN Hub window (it's the synthetic icon-only
        // card) — exclude its id from both the cache seed and the live prefetch so no self-capture is
        // tried; the switcher already renders the app icon for it.
        let hubID = hubWindow.map { CGWindowID($0.windowNumber) }
        let windows = overlay.model.windows.filter { $0.id != hubID }
        thumbnails.seed(into: overlay.model, ids: windows.map(\.id))  // instant from cache (no icon-only flash)
        thumbnails.prefetch(windows)                                  // refresh only cleanly-visible windows
    }

    /// Seed cached thumbnails for EVERY Space's windows the moment the switcher opens — not just the
    /// current row. The reel already builds every Space's cards eagerly, but their previews were
    /// otherwise only seeded when a Space first became current, so its cards (and their highlight
    /// border) re-rendered icon→thumbnail on first visit — the "rebuild on first visible" pop. With all
    /// Spaces seeded up front, switching to any Space is a pure slide with nothing left to rebuild.
    /// Off-screen Spaces can't be freshly captured anyway, so cache is their only preview source; the
    /// seed is idempotent (identical frames don't republish), so re-seeding the current row is free.
    private func seedAllRows() {
        let hubID = hubWindow.map { CGWindowID($0.windowNumber) }
        let allIDs = overlay.model.rows.flatMap { $0 }.map(\.id).filter { $0 != hubID }
        thumbnails.seed(into: overlay.model, ids: allIDs)
    }

    /// Begin the periodic preview refresh for the open switcher (unconditional — no setting). Schedules a
    /// repeating timer whose ticks re-capture the whole visible Space-row via `prefetchCurrentRow()`.
    /// Invalidates any prior timer first so it is safe to call again. The immediate first capture is done by
    /// `prefetchCurrentRow()` at the call sites (open / Space switch); the timer handles subsequent sweeps.
    private func startPreviewRefresh() {
        guard overlay.isVisible else { return }
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.previewRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefetchCurrentRow() }
        }
    }

    /// Stop the periodic preview refresh. Idempotent — safe when already stopped (the timer is nil) — so it
    /// can be paired with every overlay teardown site unconditionally. The thumbnail cache persists as the
    /// last-good-frame store.
    private func stopPreviewRefresh() {
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
    }

    func gestureDidCommit() {
        guard overlay.isVisible, let window = overlay.model.selectedWindow else {
            overlay.hide()
            stopPreviewRefresh()
            return
        }
        overlay.hide()
        stopPreviewRefresh()
        // The synthetic Hub card: focus our OWN window directly (accessory mode → reliable via
        // activate + makeKeyAndOrderFront, exactly what `present` does), switching to its Space if it's
        // off the current one — never the cross-Space SkyLight raise meant for foreign windows. This
        // also short-circuits the Accessibility gate below: focusing our own window needs no AX. If
        // Mission Control is open, dismiss it first (as the normal commit does) so the Hub lands on the
        // live desktop, then present after the close animation settles.
        if HubSwitcherEntry.isHub(selectedID: window.id, hubWindowNumber: hubWindow?.windowNumber) {
            if missionControlOpen {
                missionControlOpen = false
                MissionControl.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.present(self?.hubWindow)
                }
            } else {
                present(hubWindow)
            }
            return
        }
        guard permissions.accessibility == .granted else {
            // While first-run onboarding is incomplete the wizard owns first contact — the OS
            // Accessibility prompt must never fire mid-gesture; the commit is simply inert. After
            // completion this is the safety net for the granted-then-revoked case.
            if FirstRunMachine.shouldPromptAccessibilityOnCommit(firstRunCompleted: firstRun.isCompleted) {
                permissions.requestAccessibility()
            }
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
        stopPreviewRefresh()
    }

    // MARK: - GestureRecognizerDelegate (four-finger launcher)

    func launcherDidActivate() {
        // The wizard's stage owns the trackpad — and on the playground act it puts real launcher
        // intents to work: the embedded tour responds to the user's actual four-finger gestures
        // (the recognizer only emits these when the relocation is effective, so this is exactly
        // the post-re-login / replay case).
        if wizardOwnsGestures { wizardModel?.launcherTourActivate(); return }
        // Defensive: while the AI preview canvas is open the recognizer is in canvas-resolution mode and
        // routes swipes to `launcherCanvasResolve` (down = commit, horizontal = discard), so it does NOT
        // call this. Should it ever reach here, do NOT re-show — that would discard the canvas and reset
        // to the grid; let the open canvas keep handling the gesture.
        guard !launcherOverlay.canvasActive else { return }

        let fav = favoritesStore.favorites
        // AI commands are persisted band items now (configuration-hub fold-in), so they project from
        // `fav.bands` like any item — no synthetic AI band, no opt-in filtering (a fired AI item
        // resolves its availability in the canvas). Only the Clipboard band remains synthetic.
        var bands = fav.bands
        var clipboardBandIndex: Int?
        if settings.keepClipboardHistory {
            let entries = clipboardStore.recentWindow(limit: settings.clipboardRecentWindow)
            bands.append(ClipboardBandBuilder.build(from: entries))
            clipboardBandIndex = bands.count - 1
        }
        // The Files band is synthetic + ephemeral like Clipboard (never persisted into Favorites): build a
        // fresh directory navigator over the configured roots, project its current column as the band, and
        // thread both the band index and the controller through `show`. The controller owns the on-demand
        // listing cache + the column state machine; the model routes the recognizer's drill into it.
        var filesBandIndex: Int?
        var filesColumn: FilesColumnController?
        if settings.filesBandEnabled {
            let controller = makeFilesColumnController()
            bands.append(FilesBandBuilder.build(currentColumn: controller.visibleEntries))
            filesBandIndex = bands.count - 1
            filesColumn = controller
        }
        guard !bands.isEmpty else { return }
        // Capture the app the user was looking at before the (non-activating) overlay appears, so a
        // `.action(.closeFrontWindow)` item — a clipboard paste, and an AI command's selection I/O —
        // targets that window.
        let front = NSWorkspace.shared.frontmostApplication
        capturedFrontApp = (front?.processIdentifier == getpid()) ? capturedFrontApp : front
        // Edge-triggered auto-repeat acceleration.
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
                             filesBandIndex: filesBandIndex,
                             filesColumn: filesColumn)
    }

    /// Build a fresh `FilesColumnController` for a launcher open: the configured roots, the per-root
    /// remembered deepest locations restored from settings, and the sort key/direction mapped from
    /// settings. The controller seeds its current column synchronously from the cache (empty on a cold
    /// open) and warms the landing column asynchronously; the band's items reproject when the listing
    /// lands (via the model's `onColumnChanged` binding). Orphaned remembered locations (a removed root)
    /// are pruned opportunistically so the map doesn't grow unbounded.
    private func makeFilesColumnController() -> FilesColumnController {
        let roots = settings.filesRoots.map { URL(fileURLWithPath: $0).standardizedFileURL }
        // Restore root → deepest-folder from settings, keyed by the SAME standardized path the model
        // persists with (`root.standardizedFileURL.path`), so the lookup matches what was written.
        var remembered: [URL: URL] = [:]
        for root in roots {
            if let path = settings.rememberedLocation(forRoot: root.path) {
                remembered[root] = URL(fileURLWithPath: path).standardizedFileURL
            }
        }
        // Drop orphaned remembered entries whose root is no longer configured (standardized key space).
        settings.pruneRememberedLocations(keepingRoots: Set(roots.map(\.path)))
        return FilesColumnController(
            roots: roots,
            remembered: remembered,
            sortOrder: FilesColumnController.sortOrder(field: settings.filesSortField),
            sortDirection: settings.filesSortDirection,
            // Open displaying the last folder visited (so crossing in from the band icon lands there,
            // no jump) when the user has the Hub toggle on; otherwise land on the roots list.
            restoreLastLocation: settings.filesRememberLocation)
    }

    func launcherDidStepItem(_ direction: Int) {
        if wizardOwnsGestures { wizardModel?.launcherTourStepItem(direction); return }
        guard launcherOverlay.isVisible else { return }
        launcherOverlay.stepHorizontal(direction)   // grid cursor / cross between band list and grid
    }

    func launcherDidStepContext(_ direction: Int) {
        if wizardOwnsGestures { wizardModel?.launcherTourStepContext(direction); return }
        guard launcherOverlay.isVisible else { return }
        launcherOverlay.stepVertical(direction)      // band switch (on the band list) / grid rows
    }

    /// The cursor is on the band list (left title column), where the coarse band-step applies to the
    /// VERTICAL axis. Lets the recognizer use the coarser context-step for vertical band switching and
    /// the finer item-step everywhere else.
    func launcherFocusIsOnBandList() -> Bool {
        if wizardOwnsGestures { return wizardModel?.launcherTourFocusOnBandList ?? false }
        return launcherOverlay.isVisible && launcherOverlay.focusIsOnBandList
    }

    func launcherDidEnd() {
        if wizardOwnsGestures { wizardModel?.launcherTourEnd(); return }
        // Lift: the controller fires the armed item (or dismisses if nothing armed). Firing is
        // heterogeneous (app/path/url/shortcut/script/preset); the AX-dependent paths degrade on
        // their own if Accessibility isn't granted, so we don't gate the whole commit on it.
        launcherOverlay.end()
    }

    func launcherDidCancel() {
        if wizardOwnsGestures { wizardModel?.launcherTourEnd(); return }
        launcherOverlay.cancel()
    }

    /// The action a canvas resolve excursion resolves to, once the binding is consulted. `commit` is
    /// further gated by `canvasAtTop` at the call site (binding-independent); `discard`/`ignore` are not.
    enum CanvasResolveDecision: Equatable { case commit, discard, ignore }

    /// Pure decision: given the recognizer's axis-locked excursion (exactly one of `dx`/`dy` non-zero) and
    /// the user's `canvas` binding, resolve which action it performs (`add-gesture-previews-and-bindings`
    /// §9.3). The recognizer's sign convention is fixed: `dy<0 → swipeDown`, `dy>0 → swipeUp`,
    /// `dx<0 → swipeLeft`, `dx>0 → swipeRight`. The rule (reproducing today's defaults and honoring any
    /// remap): the excursion bound to commit → commit; to ignore → ignore; to dismiss → discard; the one
    /// spare (unbound) excursion → discard if HORIZONTAL ("any horizontal = dismiss"), ignore if VERTICAL.
    static func canvasResolveDecision(
        dx: Int, dy: Int, binding: GestureBindings.CanvasBinding
    ) -> CanvasResolveDecision {
        let performed: GestureBindings.CanvasExcursion?
        if dy < 0 { performed = .swipeDown }
        else if dy > 0 { performed = .swipeUp }
        else if dx < 0 { performed = .swipeLeft }
        else if dx > 0 { performed = .swipeRight }
        else { performed = nil }
        guard let performed else { return .ignore }

        if performed == binding.commit { return .commit }
        if performed == binding.ignore { return .ignore }
        if performed == binding.dismiss { return .discard }
        // The one spare (unbound) excursion: a HORIZONTAL spare discards, a VERTICAL spare is ignored.
        return (performed == .swipeLeft || performed == .swipeRight) ? .discard : .ignore
    }

    /// A fresh TWO-finger swipe while the AI preview canvas is open resolves it (change
    /// `positional-navigation`, D5 — 4 fingers open/dismiss the platform, 2 fingers act within it). The
    /// recognizer has already axis-locked; the performed excursion is mapped to an action through the
    /// user's **configured canvas binding** (`add-gesture-previews-and-bindings` §9.3). Defaults reproduce
    /// today's grammar exactly: down = commit-at-top, up = ignore, left = dismiss, spare (right) = discard.
    func launcherCanvasResolve(dx: Int, dy: Int) {
        guard launcherOverlay.canvasActive else { return }
        switch AppCoordinator.canvasResolveDecision(dx: dx, dy: dy, binding: settings.gestureBindings.canvas) {
        case .commit:
            // The commit-bound excursion applies — but ONLY when the canvas is scrolled to the TOP. Off the
            // top the same two-finger pan is the user SCROLLING the response/thinking back up (the native
            // scroll already handled it), so it must not insert the result. This at-top guard is
            // binding-independent: it holds for whatever excursion is bound to commit.
            guard aiCommandExecutor.canvasAtTop else { return }
            launcherOverlay.resolveCanvasCommit()   // at top → apply (replace / paste / run task)
        case .discard:
            launcherOverlay.discardCanvas()
        case .ignore:
            break                                   // no-op (e.g. default up scrolls toward the tail)
        }
    }

    func launcherEdgeChanged(dx: Int, dy: Int) {
        guard !wizardOwnsGestures else { return }   // no edge auto-repeat in the wizard's tour
        guard launcherOverlay.isVisible else { return }
        var h = dx, v = dy
        if settings.reverseDirection { h = -h }            // match manual horizontal stepping
        if settings.reverseVerticalDirection { v = -v }    // match manual vertical stepping
        launcherOverlay.setEdgeAutoScroll(dx: h, dy: v)
    }

    // MARK: - GestureRecognizerDelegate (Files-band drill)

    /// Horizontal drill while the Files band is current: descend / ascend the directory tree (the
    /// direction is already reverse-adjusted in the recognizer). Forwarded to the overlay, which routes it
    /// into the navigator and reprojects the band, then **recharges the dwell-to-arm** on the new row
    /// (`filesManageDwell` — add-files-band-dwell-arm): a Files lift fires only when the row has armed.
    ///
    /// While the Open-With picker is open it is **vertical-only** (the apps are a single scrubbable column),
    /// so a depth step is ignored — horizontal must not drill folders out from under the open popup.
    func filesDepth(_ direction: Int) {
        guard launcherOverlay.isVisible else { return }
        // A popup (the Open-With grid or the action menu) is vertical-only — depth doesn't drill the tree.
        if launcherOverlay.model.filesPicker != nil || launcherOverlay.model.filesActionMenu != nil { return }
        launcherOverlay.filesDepth(direction)
        launcherOverlay.filesManageDwell()   // descend/ascend lands on a new row → recharge the dwell-to-arm
    }

    /// Vertical highlight move while the Files band is current (reverse-adjusted upstream): an up-step at
    /// the top of the column overflows into a focus-search request inside the model.
    ///
    /// While the Open-With picker is open the same vertical scrub moves the **picker** highlight (the app
    /// list), not the folder list — the popup is what the user is navigating.
    func filesHighlight(_ direction: Int) {
        guard launcherOverlay.isVisible else { return }
        // Route the vertical scrub to whichever popup is open (action menu, then Open-With grid), else the
        // folder list — a popup is what the user is navigating while it is up.
        if launcherOverlay.model.filesActionMenu != nil {
            launcherOverlay.model.filesActionMenuMove(direction)
        } else if launcherOverlay.model.filesPicker != nil {
            launcherOverlay.model.filesPickerMove(direction)
        } else {
            launcherOverlay.filesHighlight(direction)
        }
        launcherOverlay.filesManageDwell()   // recharge the dwell-to-arm on the row/cell we landed on
    }

    /// The resolving lift with no added finger. Two cases:
    ///
    /// - **Picker open:** a lift CHOOSES the highlighted app — Open-With the highlighted file using that
    ///   app's URL (the same defusable held open), then leave the picker and dismiss the navigator.
    /// - **Picker closed:** open the highlighted entry in its default app (a folder as a Finder window),
    ///   then dismiss.
    ///
    /// The open is a **defusable held open** under the hood (design D7): prepared then committed after a
    /// short fuse, so a discard within the fuse window still cancels it. A failure surfaces ONLY through
    /// `FileOpenService`'s bounded `.failed` state (its clean `FileActionError` headline) — never an alert
    /// from here. A no-op (dismiss only) when nothing is highlighted (empty column / empty picker).
    func filesOpen() {
        guard launcherOverlay.isVisible else { return }
        // DWELL GATE (mirrors the launcher's `end()`): a committing Files lift fires only when the highlighted
        // row has armed (rested past the dwell); an unarmed scrub-and-lift just DISMISSES, acting on nothing.
        // One gate covers every committing branch below — picker app, menu row, and the default deliver/open.
        guard launcherOverlay.model.armed else { launcherOverlay.hide(); return }
        // Picker open: the lift chooses the highlighted app and Open-Withs the file with it.
        if launcherOverlay.model.filesPicker != nil {
            defer { filesPickerOriginEntry = nil; launcherOverlay.model.exitFilesPicker(); launcherOverlay.hide() }
            guard let entry = launcherOverlay.filesHighlightedEntry,
                  case let .external(candidate)? = launcherOverlay.model.filesPickerSelected() else { return }
            fireFilesOpen { [weak self] in
                self?.fileOpenService.prepareOpenWith(entry, appURL: candidate.app.url)
                    .commit(afterFuse: Self.filesOpenFuse)
            }
            return
        }
        // Action menu open: a lift COMMITS the highlighted row ("Open in ▸" descends into the app grid; a
        // tool row opens the folder in that terminal/editor; any other action runs its effect).
        if let menu = launcherOverlay.model.filesActionMenu {
            filesCommitMenuRow(menu)
            return
        }
        // Picker closed: perform the configured lift action on the highlighted entry — DELIVER it to the
        // captured front app (the default — `files-contextual-delivery`) or OPEN it (file → default app,
        // folder → Finder window). Open dismisses immediately (the defusable held open fires after a fuse);
        // deliver keeps the navigator up until the async paste lands, so a no-front-app failure surfaces as
        // a bounded row (mirroring `surfaceNoApplication` — `hide()` destroys the panel synchronously, so a
        // failure can only show while the navigator is still open), and hides on success.
        guard let entry = launcherOverlay.filesHighlightedEntry else { launcherOverlay.hide(); return }
        switch settings.filesLiftAction {
        case .open:
            launcherOverlay.hide()
            fireFilesOpen { [weak self] in
                self?.fileOpenService.prepareOpen(entry).commit(afterFuse: Self.filesOpenFuse)
            }
        case .deliver:
            filesDeliver(entry)
        }
    }

    /// Deliver the highlighted entry to the captured front app (the default lift — `files-contextual-delivery`):
    /// write the dual-representation payload (path string + file reference) and synthesize a paste, so a text
    /// target receives the **path** and a Finder window receives the **file** — no context detection on our
    /// side. On success the navigator dismisses; when there is **no captured front app** to deliver into, the
    /// delivery surfaces a **bounded, non-blocking** failure row (never a false "Done", never an alert) and the
    /// navigator stays open with the drill re-armed so the user can retry or discard. The keystroke landing
    /// itself is unobservable, so a successful attempt is "delivered," not a confirmed paste.
    private func filesDeliver(_ entry: FileEntry) {
        let payload = FilesDelivery.payload(for: entry)
        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if await self.selectionService.deliverFile(url: payload.url, path: payload.path) {
                    self.launcherOverlay.hide()
                } else {
                    self.launcherOverlay.model.filesOpenFailure = LauncherModel.FilesOpenFailure(
                        headline: "Couldn't deliver — no app was frontmost to receive it.", details: nil)
                    self.recognizer.rearmDrill()   // keep navigation alive for another try / discard
                    self.launcherOverlay.filesRearmDwell()   // a re-lift must re-dwell first (Retry bypasses)
                }
            }
        }
        lastFilesOpen = deliver   // the failure row's Retry re-runs the identical delivery
        deliver()
    }

    /// Capture `open` as the retryable last Files open (so the failure row's Retry re-runs the identical
    /// prepare→commit), then fire it. The single fire path for both default opens and Open-With, so a retry
    /// reproduces exactly what the lift did.
    private func fireFilesOpen(_ open: @escaping () -> Void) {
        lastFilesOpen = open
        open()
    }

    /// The resolving lift after a relative +1 finger: open the **action menu** for the highlighted file or
    /// folder (`files-action-menu`). Builds the per-type rows (the configured menu + the live pasteboard /
    /// installed-tools context) and enters the navigable menu (the user scrubs vertically and lifts to commit
    /// — see `filesOpen`/`filesCommitMenuRow`), then **re-arms** the drill so a fresh gesture scrubs the popup
    /// (the firing lift already raised the fingers). A no-op when a popup is already open (a stray +1 inside
    /// it must not reset it). The method name is retained because it is the recognizer's `+1`-finger delegate
    /// hook; its action is now "open the menu" (Open-With folds in as the menu's "Open in ▸").
    func filesOpenWith() {
        guard launcherOverlay.isVisible else { return }
        // Already in a popup: a stray +1 must not reset it — re-arm so it stays scrubbable (the lift latched
        // the drill as resolved). The dwell is NOT recharged here (the same popup row stays highlighted).
        guard launcherOverlay.model.filesPicker == nil, launcherOverlay.model.filesActionMenu == nil else {
            recognizer.rearmDrill(); return
        }
        // DWELL GATE: the menu opens only over an armed row — a quick scrub-and-`+1`-lift dismisses, never
        // popping a menu you didn't dwell on (the `+1`-finger morph itself moved no highlight, so the arm the
        // user charged on this row is the same arm gating it here).
        guard launcherOverlay.model.armed else { launcherOverlay.hide(); return }
        defer { recognizer.rearmDrill() }
        guard let entry = launcherOverlay.filesHighlightedEntry else { return }
        let rows = buildActionMenuRows(for: entry)
        guard !rows.isEmpty else { return }   // defensive — the default menus always have at least one row
        launcherOverlay.model.enterFilesActionMenu(entry: entry, rows: rows)
        launcherOverlay.filesManageDwell()   // entering the menu lands on row 0 → a fresh dwell there
    }

    /// Resolve the configured action menu into the concrete rows for `entry`, applying live context: whether
    /// the pasteboard holds a file (gates Paste-into) and the installed, user-curated terminals/editors.
    private func buildActionMenuRows(for entry: FileEntry) -> [FilesMenuRow] {
        let hasFile = NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true])
        let tools = detectFilesTools()
        return settings.filesActionMenu.visibleRows(for: entry, pasteboardHasFile: hasFile,
                                                    terminals: tools.terminals, editors: tools.editors)
    }

    /// Probe which catalog terminals/editors are installed (`NSWorkspace.urlForApplication(withBundleIdentifier:)`)
    /// and apply the user's curation (`filesToolsDisabled`). No new permission — a bundle-id lookup.
    private func detectFilesTools() -> (terminals: [FilesTool], editors: [FilesTool]) {
        let disabled = Set(settings.filesToolsDisabled)
        func detect(_ seeds: [(bundleID: String, name: String)], role: FilesTool.Role) -> [FilesTool] {
            seeds.compactMap { seed in
                guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: seed.bundleID) != nil else { return nil }
                return FilesTool(bundleID: seed.bundleID, name: seed.name, role: role,
                                 enabled: !disabled.contains(seed.bundleID))
            }
        }
        return (detect(FilesToolCatalog.terminals, role: .terminal),
                detect(FilesToolCatalog.editors, role: .editor))
    }

    /// Commit the highlighted action-menu row. "Open in ▸" descends into the Open-With app grid (remembering
    /// it came from the menu, so a discard backs out to the menu); a tool row opens the folder in that
    /// terminal/editor; any other action runs its effect (which dismisses, or surfaces a bounded failure).
    private func filesCommitMenuRow(_ menu: LauncherModel.FilesActionMenuState) {
        guard let row = menu.highlighted else {
            launcherOverlay.model.exitFilesActionMenu(); recognizer.rearmDrill(); return
        }
        let entry = menu.entry
        switch row {
        case .action(.openIn):
            launcherOverlay.model.exitFilesActionMenu()
            filesPickerOriginEntry = entry
            presentOpenWithPicker(for: entry)
        case let .tool(_, tool):
            openEntry(entry, inToolBundleID: tool.bundleID)
            launcherOverlay.hide()
        case let .action(action):
            performMenuAction(action, on: entry)
        }
    }

    /// Present the Open-With **app grid** for `entry`: for a **file**, the apps that can open it (default
    /// indicated); for a **folder**, the folder-openers (Finder + the curated editors/terminals). When the
    /// candidate list is empty, surface the bounded `noApplicationForFile` notice and keep the navigator
    /// open. Always re-arms the drill so a fresh gesture scrubs the grid.
    private func presentOpenWithPicker(for entry: FileEntry) {
        // Entering the grid lands on the default app (or, on empty candidates, drops back to the folder row) —
        // recharge the dwell so the landing cell must itself be dwelled before a lift opens it.
        defer { recognizer.rearmDrill(); launcherOverlay.filesManageDwell() }
        let candidates = entry.isDirectory
            ? folderOpenerCandidates()
            : fileOpenService.openWithCandidates(for: entry)
        let entries = OpenWithEntries.build(externalApps: candidates)
        guard !entries.isEmpty else {
            fileOpenService.surfaceNoApplication(for: entry)
            return
        }
        launcherOverlay.model.enterFilesPicker(entries)
    }

    /// The "Open in ▸" candidates for a **folder**: Finder (the default), then the installed, enabled
    /// editors and terminals — a folder has no LaunchServices opener list of its own (which is exactly why
    /// the menu was empty on folders before). Each opens the folder with that app via `prepareOpenWith`.
    private func folderOpenerCandidates() -> [OpenWithCandidate] {
        var candidates: [OpenWithCandidate] = []
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            candidates.append(OpenWithCandidate(app: AppCandidate(url: finder), isDefault: true))
        }
        let tools = detectFilesTools()
        for tool in (tools.editors + tools.terminals) where tool.enabled {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tool.bundleID) {
                candidates.append(OpenWithCandidate(app: AppCandidate(url: url), isDefault: false))
            }
        }
        return candidates
    }

    /// Open the entry's folder (a folder itself, or a file's containing folder) as `bundleID`'s working
    /// directory — the ‹terminals› / Open-in-‹editor› rows. Reuses the no-new-permission `NSWorkspace.open`
    /// handoff; most terminals/editors set a folder argument as their CWD.
    private func openEntry(_ entry: FileEntry, inToolBundleID bundleID: String) {
        let folder = entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            surfaceFilesFailure(.openFailed(name: entry.name, details: "That app isn’t installed."))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true   // the user chose this tool — bring it forward
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.surfaceFilesFailure(.openFailed(name: entry.name, details: String(describing: error)))
            }
        }
    }

    /// Run a non-navigation menu action and resolve the navigator. The copy/reveal/name/favorite actions
    /// complete the interaction (dismiss); Paste-into keeps the navigator open on failure (a bounded row +
    /// retry), and the copies land in clipboard history via the live monitor (no manual insert).
    private func performMenuAction(_ action: FilesMenuAction, on entry: FileEntry) {
        let pb = NSPasteboard.general
        switch action {
        case .copyAsPath:
            pendingCut = nil                        // an explicit copy supersedes any pending cut
            pb.clearContents()
            pb.setString(entry.url.standardizedFileURL.path, forType: .string)
            launcherOverlay.hide()
        case .copy:
            pendingCut = nil
            pb.clearContents()
            pb.writeObjects([entry.url as NSURL])   // the file/folder OBJECT (paste-in-Finder copies it)
            launcherOverlay.hide()
        case .cut:
            // Mark for move: write the object like Copy, then record the cut keyed on the pasteboard's NEW
            // change-count, so the next Paste moves it only while the pasteboard is still this cut.
            pb.clearContents()
            pb.writeObjects([entry.url as NSURL])
            pendingCut = (sources: [entry.url], changeCount: pb.changeCount)
            launcherOverlay.hide()
        case .copyName:
            pendingCut = nil
            pb.clearContents()
            pb.setString(entry.name, forType: .string)
            launcherOverlay.hide()
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            launcherOverlay.hide()
        case .addToFavorites:
            addEntryToFavorites(entry)
            launcherOverlay.hide()
        case .pasteInto:
            pasteIntoFolder(for: entry)
        case .delete:
            deleteEntry(entry)
        case .openIn, .openInTerminals, .openInEditor:
            // openIn descends (handled in `filesCommitMenuRow`); the tool groups expand to `.tool` rows, so
            // a bare `.action` here is an unreachable fallthrough — dismiss to be safe.
            launcherOverlay.hide()
        }
    }

    /// Paste-into: put the pasteboard's file(s) INTO the target folder (a highlighted folder, or a file's
    /// containing folder) — **dual-mode**: a **move** when fulfilling a pending Cut (the pasteboard is still
    /// that cut), else a **copy**; **keep-both** on conflict (auto-rename) either way, never overwriting.
    /// Dismisses on success; on failure surfaces a bounded `pasteFailed` row and keeps the navigator open
    /// (re-armed). File URLs only in v1.
    private func pasteIntoFolder(for entry: FileEntry) {
        // Capture the paste as the retryable last action, so the failure row's Retry re-pastes (not a stale
        // open). Keep-both makes a re-paste safe (it never overwrites).
        let paste: () -> Void = { [weak self] in self?.performPasteInto(for: entry) }
        lastFilesOpen = paste
        paste()
    }

    private func performPasteInto(for entry: FileEntry) {
        let destination = entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
        let sources = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !sources.isEmpty else {
            surfaceFilesFailure(.pasteFailed(name: destination.lastPathComponent,
                                             details: "The clipboard holds no file to paste."))
            recognizer.rearmDrill(); return
        }
        // MOVE iff the live pasteboard is still the pending cut (its change-count is unchanged); otherwise
        // COPY. Any Copy / external write since the Cut bumps the count → the cut is superseded → we copy.
        let isMove = pendingCut.map { $0.changeCount == NSPasteboard.general.changeCount } ?? false
        let fm = FileManager.default
        do {
            var taken = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
            for source in sources {
                let unique = FilesPasteName.uniqueName(for: source.lastPathComponent, existing: taken)
                let target = destination.appendingPathComponent(unique)
                if isMove { try fm.moveItem(at: source, to: target) }
                else      { try fm.copyItem(at: source, to: target) }
                taken.insert(unique)
            }
            if isMove { pendingCut = nil }   // the cut is consumed by the move
            launcherOverlay.hide()
        } catch {
            surfaceFilesFailure(.pasteFailed(name: destination.lastPathComponent, details: String(describing: error)))
            recognizer.rearmDrill()
        }
    }

    /// Delete: move the entry to the **Trash** (recoverable from Finder) — never a permanent `removeItem`.
    /// Dismisses on success (the entry is simply gone on the next listing); on failure surfaces a bounded
    /// `trashFailed` row and keeps the navigator open (re-armed). Committed by the dwell-armed lift, so a
    /// stray scrub-and-lift never deletes (`add-files-band-dwell-arm`).
    private func deleteEntry(_ entry: FileEntry) {
        let delete: () -> Void = { [weak self] in self?.performDelete(for: entry) }
        lastFilesOpen = delete   // the failure row's Retry re-tries the trash
        delete()
    }

    private func performDelete(for entry: FileEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            launcherOverlay.hide()
        } catch {
            surfaceFilesFailure(.trashFailed(name: entry.name, details: String(describing: error)))
            recognizer.rearmDrill()
        }
    }

    /// Add `entry` to the launcher as a persistent favorite (`.path` opens it in its default handler) — the
    /// opt-in "Add to Favorites" item, bridging the Files band back into the launcher. Lands in the home
    /// band, else the first band, else a fresh "Files" band.
    private func addEntryToFavorites(_ entry: FileEntry) {
        let item = LaunchItem(title: entry.name, icon: .fileIcon, kind: .path(entry.url))
        let fav = favoritesStore.favorites
        let bandID = fav.homeBandID ?? fav.bands.first?.id ?? favoritesStore.addBand(name: "Files")
        favoritesStore.addItem(item, toBand: bandID)
    }

    /// Surface a Files-band action failure as the existing bounded, non-blocking row (clean headline + opt-in
    /// copyable details) — never an alert, never raw text in a headline.
    private func surfaceFilesFailure(_ error: FileActionError) {
        launcherOverlay.model.filesOpenFailure = LauncherModel.FilesOpenFailure(
            headline: error.errorDescription ?? "Something went wrong.", details: error.copyableDetails)
    }

    /// A fresh deliberate four-finger horizontal swipe-away while drilled: discard.
    ///
    /// - **Picker open:** the swipe backs OUT of the picker to the folder list — the navigator stays open
    ///   (it is not a full dismiss), and any pending open is defused.
    /// - **Picker closed:** dismiss the navigator. Defuses any held open (it never terminates an
    ///   already-running app — `cancelPending` only cancels a not-yet-fired open).
    func filesDiscard() {
        guard launcherOverlay.isVisible else { return }
        fileOpenService.cancelPending()
        // Action menu open: back out to the folder list (navigator stays).
        if launcherOverlay.model.filesActionMenu != nil {
            launcherOverlay.model.exitFilesActionMenu()
            recognizer.rearmDrill()
            launcherOverlay.filesManageDwell()        // landed back on the folder row → recharge its dwell
            return
        }
        if launcherOverlay.model.filesPicker != nil {
            launcherOverlay.model.exitFilesPicker()
            // If the grid was reached via the action menu's "Open in ▸", back out ONE level — re-open the
            // menu — rather than dropping straight to the folder list.
            if let origin = filesPickerOriginEntry {
                filesPickerOriginEntry = nil
                let rows = buildActionMenuRows(for: origin)
                if !rows.isEmpty { launcherOverlay.model.enterFilesActionMenu(entry: origin, rows: rows) }
            }
            recognizer.rearmDrill()                   // a fresh gesture resumes navigation
            launcherOverlay.filesManageDwell()        // landed back on the menu / folder row → recharge
            return
        }
        launcherOverlay.hide()
    }

    /// Short pre-launch fuse on a committed Files open, so a discard issued within the window still defuses
    /// it (design D7). Tiny — the held → swipe-to-resolve UI (a longer visible hold) is the view stage; here
    /// the fuse just preserves the defuse seam.
    private static let filesOpenFuse: Duration = .milliseconds(120)

    /// Mirror `FileOpenService`'s observable state into `model.filesOpenFailure`, so a failed open surfaces
    /// as a **bounded, non-blocking** row in the navigator (never an app-modal alert — spec: bounded +
    /// non-blocking, never silent). On `.failed` it sets the clean headline + opt-in details; on
    /// `.idle`/`.opening`/`.opened` it clears the row to nil (a fresh / in-flight / succeeded open has no
    /// failure to show). Mirrors `observeClipboardToggle`'s emitted-value sink pattern (the `@Published`
    /// `willSet` reports the new value); no `dropFirst()` — the service starts `.idle`, which clears anyway.
    private func observeFileOpenState() {
        fileOpenService.$state
            .sink { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case let .failed(headline, details):
                        self.launcherOverlay.model.filesOpenFailure =
                            LauncherModel.FilesOpenFailure(headline: headline, details: details)
                    case .idle, .opening, .opened:
                        self.launcherOverlay.model.filesOpenFailure = nil
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Re-fire the last Files open (the failure row's Retry). Re-running it transitions `FileOpenService`
    /// back through `.opening` (which the state sink clears the failure row on) and then to `.opened` or a
    /// fresh `.failed` — so a transient failure can be retried in place. A no-op when nothing has been opened.
    private func retryLastFilesOpen() {
        lastFilesOpen?()
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

    // MARK: - Dock-preview lifecycle

    /// React to the `showDockPreviews` toggle: install/tear down the cursor monitor + Dock reader. Uses
    /// the emitted value (not a re-read), since `@Published` fires in `willSet` (mirrors the others).
    /// There is no `is…Effective` gate, no re-login, and no new permission — flipping it ON arms the
    /// hover detection immediately, OFF tears it down.
    private func observeDockPreviewsToggle() {
        settings.$showDockPreviews
            .dropFirst()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.dockPreviewController.setEnabled(on) } }
            .store(in: &cancellables)
    }

    // MARK: - Device link lifecycle

    /// React to the `enableDeviceLink` toggle (mirrors `observeClipboardToggle` — uses the emitted value,
    /// since `@Published` fires in `willSet`).
    private func observeDeviceLinkToggle() {
        settings.$enableDeviceLink
            .dropFirst()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.setDeviceLink(on) } }
            .store(in: &cancellables)
    }

    /// Start the device-link service when opted in AND the app is enabled; otherwise stop it. Received
    /// items are adapted into the clipboard store (where the Clipboard band surfaces them, tagged by
    /// device). `on` is the authoritative state (the toggle's emitted value, or a stable read at launch).
    private func setDeviceLink(_ on: Bool) {
        if on && isEnabled {
            guard deviceLinkService == nil else { return }
            let service = DeviceLinkService(
                localIdentity: localDeviceIdentity,
                staticKey: MacLocalIdentity.privateKey,
                pinnedFingerprints: { [weak self] in self?.pairedDeviceStore.pinnedFingerprints() ?? [] },
                device: { [weak self] fingerprint in self?.pairedDeviceStore.device(forFingerprint: fingerprint) })
            service.onItem = { [weak self] item in self?.receiveLinkItem(item) }
            do {
                try service.start()
                deviceLinkService = service
            } catch {
                // Local-network start can fail (e.g. permission not yet granted) — leave the service nil
                // so a later toggle / permission grant retries. Surfaced on the Devices page.
                deviceLinkService = nil
            }
        } else {
            deviceLinkService?.stop()
            deviceLinkService = nil
        }
    }

    /// A received item → `ClipboardEntry` (files written to the inbox) → the existing store. Runs on the
    /// main queue (the service hops there before calling `onItem`).
    private func receiveLinkItem(_ item: LinkItem) {
        do {
            let entry = try linkInboundAdapter.entry(from: item)
            clipboardStore.insert(entry)
            // Auto-paste: make the received item the system clipboard so it's immediately pasteable. Reuse
            // the launcher's pasteboard writer (PNG+TIFF / color-hex / path fallbacks), without synthesizing
            // a ⌘V. Then suppress the monitor's re-capture of THIS write by its `changeCount`, so the
            // already-inserted `.peer(deviceName:)` entry keeps its origin/`capturedAt` and no duplicate is
            // recorded. Suppression is a no-op when clipboard history is off (the monitor isn't polling).
            LaunchService.writeToPasteboard(entry)
            clipboardMonitor.suppressSelfWrite(changeCount: NSPasteboard.general.changeCount)
            // Fire-and-forget feedback — the LAST, non-throwing step, so a HUD problem can never break
            // receive/storage. On the failure path (a malformed representation / unwritable file, which
            // `entry(from:)` throws) the same HUD surfaces what was previously a silent drop.
            receiveHUD.show(kind: item.kind, from: item.origin?.name, success: true)
        } catch {
            receiveHUD.show(kind: item.kind, from: item.origin?.name, success: false)
        }
    }

    /// v1 outbound trigger: send the most recent clipboard entry to every online paired peer. Per-device
    /// targeting (a picker over `send(_:to:)`) is a later change; `sendToAll` is the thin convenience over
    /// the per-peer primitive until then.
    private func sendLatestClipboardToDevices() {
        guard let entry = clipboardStore.recentWindow(limit: 1).first,
              let item = try? linkOutboundAdapter.linkItem(from: entry, origin: localDeviceIdentity) else { return }
        deviceLinkService?.sendToAll(item)
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
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.modelManager.setOptedIn(on)
                    // Re-enabling rediscovers an already-downloaded model (→ .ready) so the user isn't
                    // asked to "Download" again; the heavy load stays lazy (first command). Then settle
                    // the displayed status to the SELECTED model (reconcile probes only the default).
                    if on {
                        self.modelManager.reconcileWithDisk()
                        if let d = self.selectedAIModelDescriptor() { self.modelManager.showStatus(for: d) }
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// At launch, if AI commands are already opted in, rediscover a previously-downloaded model so its
    /// status shows "Downloaded" (and a command can lazy-load it) instead of resetting to "Not
    /// downloaded" and forcing the user to click Download again every relaunch. Pure disk probe — no
    /// network, no heavy load (that happens on first command). No-op if nothing is on disk.
    private func reconcileAIModelAtLaunch() {
        guard settings.aiCommandsEnabled else { return }
        modelManager.reconcileWithDisk()
        if let d = selectedAIModelDescriptor() { modelManager.showStatus(for: d) }
    }

    /// The model the AI surfaces act on: the user's pinned selection if it resolves, else the registry
    /// default. Single source of truth for the download action and the displayed-status settle
    /// (`showStatus`) across launch and the opt-in observer.
    private func selectedAIModelDescriptor() -> ModelDescriptor? {
        let registry = modelManager.registry
        return settings.aiSelectedModelID.flatMap { registry.descriptor(id: $0) }
            ?? registry.defaultDescriptor ?? registry.models.first
    }

    // MARK: - Keyboard language opt-in lifecycle

    /// React to the "Remember the keyboard language per app" toggle: start/stop the service so its
    /// activation and input-source observers exist only while the feature is on (design D9 — fully inert
    /// when off). Gated solely on this toggle, independent of the switcher master enable. Uses the
    /// EMITTED value, not a re-read (the `@Published` willSet would still report the OLD value here —
    /// same reason the gesture and clipboard toggles pass `on` through).
    private func observeKeyboardLanguageToggle() {
        settings.$keyboardLanguageEnabled
            .dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if on { self.keyboardLanguageService.start() } else { self.keyboardLanguageService.stop() }
                    // Stopping the per-app feature must stop the within-browser poll too (and starting it
                    // re-arms the poll if the per-site sub-toggle is also on). The EMITTED value is passed
                    // through: `@Published` fires on willSet, so a property re-read here would still see
                    // the OLD value — the bug that used to need a quit-and-reopen to start the poll.
                    self.refreshKeyboardLanguageBrowserMonitor(master: on)
                }
            }
            .store(in: &cancellables)
    }

    /// React to the "Per-site language in browsers" sub-toggle: start/stop the within-browser host-change
    /// poll to match (it is gated on this AND the master toggle). The resolver reads `perSiteEnabled` live,
    /// so the toggle takes effect on the next resolution without re-wiring — this only governs the poll
    /// lifecycle. Mirrors `observeClipboardToggle`: uses the EMITTED value, not a re-read (the `@Published`
    /// willSet would still report the OLD value here).
    private func observeKeyboardLanguagePerSiteToggle() {
        settings.$keyboardLanguagePerSiteEnabled
            .dropFirst()
            .sink { [weak self] on in
                // Pass the EMITTED value through — a property re-read here still sees the OLD value
                // (`@Published` fires on willSet), which silently kept the poll off until relaunch.
                MainActor.assumeIsolated { self?.refreshKeyboardLanguageBrowserMonitor(perSite: on) }
            }
            .store(in: &cancellables)
    }

    /// React to the "Allow browser control" opt-in: swap the resolver's host reader in place — Apple Events
    /// (exact per-host, incl. Safari) when on, Accessibility (no new permission) when off — without
    /// rebuilding the resolver or the service it feeds (design D3/D8). No permission pre-prompt: the Apple
    /// Events reader triggers the OS Automation prompt lazily on its first read and degrades to AX (nil →
    /// app-level) until granted (6.3). Uses the EMITTED value.
    private func observeKeyboardLanguageBrowserControlToggle() {
        settings.$keyboardLanguageAllowBrowserControl
            .dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    self?.keyboardLanguageContextResolver.hostProvider =
                        on ? AppleEventsHostProvider() : AXHostProvider()
                }
            }
            .store(in: &cancellables)
    }

    /// Start the within-browser host-change poll only while BOTH the master keyboard-language toggle and
    /// the per-site sub-toggle are on; otherwise stop it (it then holds no timer and is fully inert). The
    /// per-app activation path is independent of this monitor, so plain app switches keep working whether
    /// or not the poll runs. Called at launch and from the two relevant toggle observers — which MUST pass
    /// their emitted value (a re-read inside a `@Published` willSet sink still sees the old value).
    private func refreshKeyboardLanguageBrowserMonitor(master: Bool? = nil, perSite: Bool? = nil) {
        let masterOn = master ?? settings.keyboardLanguageEnabled
        let perSiteOn = perSite ?? settings.keyboardLanguagePerSiteEnabled
        if masterOn && perSiteOn {
            keyboardLanguageBrowserMonitor.start()
        } else {
            keyboardLanguageBrowserMonitor.stop()
        }
    }

    /// Begin (or retry) the on-device model download from Settings. Gated on the opt-in by the manager
    /// itself. The PRIMARY (and only) error surface is the in-window `.failed` status row + its Retry
    /// button — the manager's observable state already carries the clean headline (and copyable
    /// details) for it. No app-modal `NSAlert.runModal()` here: its nested run loop would freeze the
    /// Settings window, and it would just duplicate the row's message (spec: "Error surfaces are
    /// non-blocking and bounded"; design D3).
    private func downloadAIModel() {
        modelManager.setOptedIn(settings.aiCommandsEnabled)
        // Honor the user's pinned model selection (the AI page / unavailable canvas picker), falling
        // back to the registry default.
        guard let descriptor = selectedAIModelDescriptor() else { return }
        Task { @MainActor in
            do {
                try await modelManager.downloadAndVerify(descriptor)
            } catch is CancellationError {
                // User cancelled — not a failure; the manager already reset its state.
            } catch RuntimeError.cancelled {
                // Same: a cancelled provision is not a failure surface.
            } catch {
                // The manager already reflects `.failed` (clean headline + details) in its observable
                // state, which the Settings row renders with a Retry action. Just log for diagnostics.
                NSLog("[ThreeFingerSwitcher] AI model download failed: \(AIError.message(for: error).details ?? AIError.message(for: error).headline)")
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

    /// The OTHER gesture features currently active, passed to the applier as value-resolution
    /// context so the shared four-finger keys land on their combined end-state values (a launcher
    /// that is on keeps the four-finger keys freed no matter which feature is being applied).
    private func gestureFeatureContext(excluding excluded: GestureFeatures) -> GestureFeatures {
        var ctx: GestureFeatures = []
        if settings.manageVerticalGesture { ctx.insert(.spaceRows) }
        if settings.enableLauncher { ctx.insert(.launcher) }
        ctx.subtract(excluded)
        return ctx
    }

    // The legacy one-shot startup prompts (didPrompt* keys) are retired: the First Touch wizard is
    // the first-run consent surface, and its completion sets all four keys (FirstRunStore). The
    // prompt* methods below remain as the Hub Setup page's re-invokable consent flows.

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
            let result = relocationApplier.apply(requested: .horizontal,
                                                 context: gestureFeatureContext(excluding: .horizontal))
            let ok = result.failed.isEmpty
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

    // MARK: - Self-relaunch (Screen Recording's TCC grant needs a fresh process)

    /// True while a programmatic quit-and-reopen is in flight; quit-time restore behaviors must
    /// not fire (the user isn't leaving — restoring/prompting would sabotage the relaunch).
    private(set) var isRelaunching = false

    /// Quit and reopen the app in place. A detached shell waits for this PID to exit, then `open`s
    /// the bundle (the same wait-then-open shape as `LaunchService`'s quit-and-reopen for launcher
    /// items). Wizard/Hub state is persisted on write, so the fresh process resumes correctly.
    func relaunchApp() {
        guard !isRelaunching else { return }
        isRelaunching = true
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        // Wait for THIS pid to fully exit, give LaunchServices a beat to register the death (an
        // `open` fired the instant the old instance dies can silently no-op against the dying
        // record), then open — with one retry. The relauncher detaches via a backgrounded subshell
        // with its IO severed, so nothing ties it to this process; a breadcrumb log lands in /tmp
        // for diagnosis if the reopen ever fails.
        let script = """
        nohup /bin/sh -c '
        exec >/tmp/tfs-relaunch.log 2>&1
        echo "relaunch: waiting for pid \(pid)"
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done
        /bin/sleep 0.4
        echo "relaunch: opening"
        /usr/bin/open "\(bundlePath)" || { echo "relaunch: retry"; /bin/sleep 1; /usr/bin/open "\(bundlePath)"; }
        echo "relaunch: done"
        ' >/dev/null 2>&1 &
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()   // only the outer shell (it exits immediately after backgrounding)
        } catch {
            isRelaunching = false
            infoAlert(title: "Couldn't relaunch",
                      text: "Quit and reopen ThreeFingerSwitcher manually to finish applying the change.")
            return
        }
        NSApp.terminate(nil)
    }

    /// Whether the in-flight quit is part of a logout/restart/shutdown (the Apple quit event's
    /// `why?` attribute). A session-end quit must NOT offer the trackpad restore: the re-login it
    /// leads to is what makes the relocation effective — restoring at that boundary would undo the
    /// change exactly when it is about to apply (the same rationale as the vertical relocation's
    /// no-restore-on-quit), and a modal there can stall the logout.
    static func quitIsSessionEnd() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue ?? 0
        let sessionEnd: [OSType] = [
            OSType(kAELogOut), OSType(kAEReallyLogOut),
            OSType(kAERestart), OSType(kAEShowRestartDialog),
            OSType(kAEShutDown), OSType(kAEShowShutdownDialog)
        ]
        return sessionEnd.contains(why)
    }

    /// Called on quit: offer to restore the trackpad setting if we changed it.
    func offerRestoreOnQuit() {
        guard !isRelaunching else { return }            // programmatic relaunch: the user isn't leaving
        guard !Self.quitIsSessionEnd() else { return }  // logout/restart: never offer to undo it here
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

    /// React to the Settings toggle: enabling applies the setting, disabling restores it. The
    /// initial persisted value is skipped (`dropFirst`); launch-apply is handled in `start()`.
    private func observeSpacesRearrangeToggle() {
        settings.$manageSpacesRearrange
            .dropFirst()
            .sink { [weak self] enabled in
                // Apply on the NEXT main-loop turn, not inside this `@Published` `willSet` emission: the
                // system work (a Dock restart, plus a modal alert on failure) is blocking, and running it
                // synchronously here stalled the SwiftUI update the bound toggle had just triggered — so
                // the row only refreshed once the page was rebuilt (e.g. navigating away and back).
                // Deferring lets the toggle re-render in place first; the change then applies a beat later.
                DispatchQueue.main.async { self?.handleSpacesRearrangeToggle(enabled) }
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
    /// (synchronously, so the Dock restart finishes before the app exits). Skipped during a
    /// programmatic relaunch — restoring would restart the Dock twice for a quit the user never made.
    func restoreSpacesRearrangeOnQuit() {
        guard !isRelaunching else { return }
        guard spacesRearrange.changedThisSession else { return }
        _ = spacesRearrange.restore()
    }

    // MARK: - Space-row switching (vertical gesture)

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
                // Defer off the `willSet` emission so the bound toggle updates in place immediately; the
                // relocation rewrite (and a modal alert on failure) is blocking and otherwise stalled the
                // SwiftUI render until the page was rebuilt. See observeSpacesRearrangeToggle.
                DispatchQueue.main.async { self?.handleVerticalGestureToggle(enabled) }
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
        let result = relocationApplier.apply(requested: .spaceRows,
                                             context: gestureFeatureContext(excluding: .spaceRows))
        guard result.failed.contains(.spaceRows) else { return }
        infoAlert(
            title: "Couldn't change the trackpad setting",
            text: """
            Moving Mission Control / App Exposé to four fingers didn't succeed. If your Mac is \
            managed (MDM), this setting may be locked. You can change it manually in System \
            Settings ▸ Trackpad ▸ More Gestures (set Mission Control to “Swipe Up with Four Fingers”).
            """
        )
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

    /// React to the Settings toggle: enabling frees the native four-finger swipes, disabling
    /// restores them. The persisted initial value is skipped (`dropFirst`); launch-apply is handled
    /// in `start()`. Mirrors `observeVerticalGestureToggle`.
    private func observeLauncherToggle() {
        settings.$enableLauncher
            .dropFirst()
            .sink { [weak self] enabled in
                // Defer off the `willSet` emission so the bound toggle updates in place immediately; the
                // four-finger relocation rewrite (and a modal alert on failure) is blocking and otherwise
                // stalled the SwiftUI render until the page was rebuilt. See observeSpacesRearrangeToggle.
                DispatchQueue.main.async { self?.handleLauncherToggle(enabled) }
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
        let result = relocationApplier.apply(requested: .launcher,
                                             context: gestureFeatureContext(excluding: .launcher))
        guard result.failed.contains(.launcher) else { return }
        infoAlert(
            title: "Couldn't change the trackpad setting",
            text: """
            Freeing the four-finger swipes for the launcher didn't succeed. If your Mac is managed \
            (MDM), this setting may be locked. You can change it manually in System Settings ▸ \
            Trackpad ▸ More Gestures (turn off the four-finger swipe gestures).
            """
        )
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

    // MARK: - Danger zone (Hub ▸ General)

    private lazy var appDataReset = AppDataReset()

    /// Restore every app-made gesture/Spaces relocation from its absent-aware backup and turn the
    /// opt-ins off. Flipping the flags drives the existing observers (restore + marker clear); the
    /// horizontal relocation has no flag, so its backup is restored directly.
    /// Returns whether anything was actually restored.
    @discardableResult
    func restoreAllNativeGestures(interactive: Bool = true) -> Bool {
        let hadAnything = trackpadConfig.hasBackup || verticalGesture.hasBackup
            || fourFingerGesture.hasBackup || spacesRearrange.hasBackup
            || settings.manageVerticalGesture || settings.enableLauncher || settings.manageSpacesRearrange
        settings.manageVerticalGesture = false     // observer restores when a backup exists
        settings.enableLauncher = false            // observer restores when a backup exists
        settings.manageSpacesRearrange = false     // observer restores when a backup exists
        if trackpadConfig.hasBackup { _ = trackpadConfig.restore() }
        refreshRowSwitchingGate()
        onStateChange?()
        if interactive {
            infoAlert(title: hadAnything ? "Gestures restored" : "Nothing to restore",
                      text: hadAnything
                        ? "Every trackpad and Spaces setting the app changed was put back from its backup. Log out and back in for the trackpad changes to take effect."
                        : "No gesture or Spaces relocation backups were found — the system settings are already yours.")
        }
        return hadAnything
    }

    /// Whether any gesture/Spaces backup exists (drives the Danger zone's restore-first note).
    var anyGestureBackupExists: Bool {
        trackpadConfig.hasBackup || verticalGesture.hasBackup
            || fourFingerGesture.hasBackup || spacesRearrange.hasBackup
    }

    /// The Danger zone's confirmed, selective clear. Ordering is load-bearing (design D1/D3):
    /// gestures restored BEFORE an App-data wipe (the backups live inside it), monitors stopped
    /// before deletion, the preferences domain wiped LAST, and an App-data/Permissions clear ends
    /// in an immediate relaunch so the fresh process reads the cleared state.
    func dangerZoneClear(_ selection: DangerZoneSelection) {
        guard !selection.isEmpty else { return }

        var lines: [String] = []
        if selection.contains(.appData) {
            lines.append("• App data & settings — preferences, bands, AI commands, keyboard-language memory, clipboard history, project outputs, first-run state.")
            if anyGestureBackupExists {
                lines.append("  Gesture relocations will be restored FIRST so their backups aren't lost.")
            }
        }
        if selection.contains(.caches) { lines.append("• Caches.") }
        if selection.contains(.aiModels) { lines.append("• AI models — the downloaded weights are deleted (re-downloadable); the AI opt-in turns off.") }
        if selection.contains(.permissions) { lines.append("• Permissions — every granted permission is reset; macOS will prompt again.") }
        let relaunches = selection.contains(.appData) || selection.contains(.permissions)
        if relaunches { lines.append("\nThe app will relaunch afterwards.") }

        let alert = NSAlert()
        alert.messageText = "Clear the selected data?"
        alert.informativeText = "This cannot be undone.\n\n" + lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 1. Never strand a relocation: the backups are part of the data being deleted.
        if selection.contains(.appData), anyGestureBackupExists {
            restoreAllNativeGestures(interactive: false)
        }
        // 2. Quiesce writers so nothing re-creates what's being removed.
        clipboardMonitor.stop()
        if selection.contains(.aiModels) || selection.contains(.appData) {
            settings.aiCommandsEnabled = false   // evicts residency + forgets download progress
        }
        if selection.contains(.aiModels) {
            // Delete the weights from the dir the runtime actually loads from (the HF cache, via the
            // manager's injected provisioner-delete). `appDataReset` below only removes the app-support
            // `models/` dir — the WRONG location on the real path — so without this the weights survive
            // and the model re-discovers as "Downloaded" on the next opt-in.
            modelManager.deleteAllFromDisk()
        }
        // 3. Delete (preferences last, inside `clear`).
        let outcome = appDataReset.clear(selection)
        // 4. A cleared identity needs a fresh process (and a data wipe replays the wizard).
        if relaunches {
            relaunchApp()
        } else {
            let failures = outcome.failures.isEmpty ? "" : "\n\nIssues:\n" + outcome.failures.joined(separator: "\n")
            infoAlert(title: "Cleared",
                      text: "Removed: \(outcome.cleared.isEmpty ? "nothing (already clean)" : outcome.cleared.joined(separator: ", "))." + failures)
            refreshClipboardMonitor()   // restart the recorder if its opt-in is still on
        }
    }

    /// Menu-bar quick-add: append the frontmost app to a band without opening the Hub (10.2).
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

    // MARK: - First Touch wizard

    private var wizardWindow: NSWindow?
    private var wizardModel: FirstTouchWizardModel?
    private var wizardCloseObserver: NSObjectProtocol?
    private let lanesToast = LanesLiveToast()

    /// Any trackpad relocation still awaiting its re-login (the persisted markers).
    private var relocationsStillPending: Bool {
        trackpadConfig.needsReloginWarning
            || verticalGesture.needsReloginWarning
            || fourFingerGesture.needsReloginWarning
    }

    /// While the wizard is on stage (visible and first-run incomplete) it owns the trackpad: the
    /// real overlays stay closed and Mission Control isn't synthesized, so the demo is the only
    /// thing that responds to the user's hand. Replay re-enters this mode deliberately.
    private var wizardOwnsGestures: Bool {
        (wizardWindow?.isVisible ?? false) && !firstRun.isCompleted
    }

    /// The launch gate that replaced the legacy alert stack: migrate existing installs silently,
    /// surface the one-time lanes-are-live acknowledgment, then resume the wizard if it has acts
    /// left to play.
    private func maybeShowFirstTouchWizard() {
        firstRun.migrateExistingInstallIfNeeded(allRequiredPermissionsGranted: permissions.allRequiredGranted)
        if firstRun.consumeLanesAcknowledgment(relocationsStillPending: relocationsStillPending) {
            lanesToast.show()
        }
        guard FirstRunMachine.shouldShowAtLaunch(stage: firstRun.stage) else {
            // Completed installs keep the old safety net: if a required permission has gone
            // missing (e.g. revoked), open the Hub on Setup rather than failing silently.
            if !permissions.allRequiredGranted { showHub(selecting: .setup) }
            return
        }
        showFirstTouchWizard()
    }

    /// Open (or bring forward) the wizard and resume it at the right act. Also the Hub Setup
    /// page's Resume/Replay entry point.
    func showFirstTouchWizard() {
        if wizardWindow == nil {
            let model = FirstTouchWizardModel(context: makeWizardContext(), store: firstRun)
            wizardModel = model
            let host = NSHostingController(rootView: FirstTouchWizardView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.setContentSize(NSSize(width: 960, height: 640))
            window.center()
            wizardWindow = window
            // Closing the window mid-flow is "later": progress is already persisted, but the
            // model's machinery (attract loop, permission polling, the touch feed) must stop.
            wizardCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.wizardModel?.suspend() }
            }
        }
        let firstPresentation = !(wizardWindow?.isVisible ?? true)
        wizardModel?.resume()
        if firstPresentation, let window = wizardWindow {
            presentWizardWithRise(window)
        } else {
            present(wizardWindow)
        }
    }

    /// The stage's own entrance: the wizard window rises 14 pt and fades in over an easeOut beat —
    /// the first frame of the performance is already motion, not a pop. (Window-level AppKit
    /// animation; the SwiftUI acts choreograph everything inside.)
    private func presentWizardWithRise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        let target = window.frame
        window.setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    /// Replay from the Hub: the same machine from the top; acts render their done states from live
    /// detection and never re-write a setting without a fresh user action.
    func replayFirstTouchWizard() {
        firstRun.beginReplay()
        showFirstTouchWizard()
    }

    private func closeWizard() {
        wizardModel?.suspend()
        onWizardTouchFrame = nil
        if let wizardCloseObserver {
            NotificationCenter.default.removeObserver(wizardCloseObserver)
            self.wizardCloseObserver = nil
        }
        let window = wizardWindow
        wizardWindow = nil
        wizardModel = nil
        guard let window else { return }
        guard window.isVisible else {
            window.orderOut(nil)
            window.close()
            return
        }
        // The exhale: the curtain's last frame drifts up and fades — the performance ends the way
        // every act moved, never on a cut.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            window.animator().setFrame(window.frame.offsetBy(dx: 0, dy: 10), display: true)
        }, completionHandler: {
            window.orderOut(nil)
            window.close()
        })
    }

    private func makeWizardContext() -> WizardContext {
        let ctx = WizardContext(settings: settings, permissions: permissions)
        ctx.requestAccessibility = { [weak self] in self?.permissions.requestAccessibility() }
        ctx.requestScreenRecording = { [weak self] in self?.permissions.requestScreenRecording() }
        ctx.relaunchNow = { [weak self] in self?.relaunchApp() }
        ctx.realWindowRows = { [weak self] in
            guard let self else { return [] }
            // The demo upgrade: the user's actual windows, current Space first. One row is enough.
            let snapshot = self.windowService.snapshot()
            let current = snapshot.filter(\.isOnCurrentSpace)
            return [current.isEmpty ? snapshot : current]
        }
        ctx.seedThumbnails = { [weak self] model in
            guard let self else { return }
            // The fan-out into the demo strip is wired once in init; this kicks the capture.
            // PRODUCTION semantics, deliberately: the switcher's hard-won rule is "never render a
            // degraded frame — last clean observation or the icon" (robust-offspace-window-fidelity;
            // the tilted set-aside proxy is what every capture API returns for a parked window, and
            // the HW-capture alternative was tried and reverted — garbage on Tahoe). So the reveal
            // live-captures every cleanly-presented window and leaves parked/set-aside ones as
            // icon+title — exactly how the real switcher renders them until first visit. Two
            // delayed sweeps retry the cards still missing an image (SCK warms up around launch,
            // and Space switches mid-wizard make more windows cleanly capturable).
            let windows = model.windows
            self.thumbnails.seed(into: model, ids: windows.map(\.id))
            self.thumbnails.prefetch(windows)
            for delay in [0.7, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let demo = self.wizardModel?.demo else { return }
                    let missing = windows.filter { demo.thumbnails[$0.id] == nil }
                    guard !missing.isEmpty else { return }
                    self.thumbnails.seed(into: demo, ids: missing.map(\.id))
                    self.thumbnails.prefetch(missing)
                }
            }
        }
        ctx.trackpadClaimed = { [weak self] in self?.trackpadConfig.isClaimed ?? false }
        ctx.spacesAutoRearrangeOn = { [weak self] in self?.spacesRearrange.isAutoRearrangeOn ?? false }
        ctx.applyLanes = { [weak self] choices in self?.applyLanesFromWizard(choices) ?? LanesApplyOutcome() }
        ctx.relocationsPending = { [weak self] in self?.relocationsStillPending ?? false }
        ctx.logOutNow = { [weak self] in self?.sendLogOutKeystroke() }
        // The tour's fixed composition (WizardTourBands): the flame band of every app across the
        // user's bands, the display band of the twelve window actions, plus the AI band when AI is
        // on and the Clipboard band when history is on (sample entries while the store is empty).
        //
        // The Files band is INTENTIONALLY SKIPPED for the v1 onboarding tour. Unlike Clipboard (a static
        // list of sample entries that reads identically in the tour and the real launcher), the Files band
        // is a LIVE, controller-backed drill surface: its navigation is meaningless without a
        // `FilesColumnController` + the recognizer's `filesDrillActive` routing, neither of which the
        // wizard's static `launcherTour*` path wires. A non-drillable sample Files row would misrepresent
        // the band, so it's discovered via the Hub's Files page + its own opt-in, not the first-touch tour.
        ctx.launcherBands = { [weak self] clipboardOn, aiOn in
            guard let self else { return [] }
            let clipboard: ContextBand? = clipboardOn ? {
                let entries = self.clipboardStore.recentWindow(limit: self.settings.clipboardRecentWindow)
                return ClipboardBandBuilder.build(
                    from: entries.isEmpty ? WizardSampleContent.clipboardEntries() : entries)
            }() : nil
            return WizardTourBands.compose(userBands: self.favoritesStore.favorites.bands,
                                           aiOn: aiOn,
                                           seededAIBand: AIBand.seededBand,
                                           clipboardBand: clipboard)
        }
        ctx.launcherLive = { [weak self] in self?.isLauncherEffective ?? false }
        // The playground lane toggle's OFF side — the wizard's quiet sibling of the Setup page's
        // restore (no modal; the act's row caption reflects the result).
        ctx.restoreLauncherLane = { [weak self] in
            guard let self else { return }
            if self.fourFingerGesture.hasBackup { _ = self.fourFingerGesture.restore() }
            self.settings.enableLauncher = false
            self.refreshRowSwitchingGate()
            self.onStateChange?()
        }
        ctx.isOpenAtLogin = { [weak self] in self?.isOpenAtLogin ?? false }
        ctx.toggleOpenAtLogin = { [weak self] in self?.toggleOpenAtLogin() }
        ctx.finish = { [weak self] in
            guard let self else { return }
            self.firstRun.complete(relocationsStillPending: self.relocationsStillPending)
            self.closeWizard()
            self.onStateChange?()
        }
        ctx.subscribeTouch = { [weak self] handler in self?.onWizardTouchFrame = handler }
        ctx.unsubscribeTouch = { [weak self] in self?.onWizardTouchFrame = nil }
        ctx.pulseMenuBarMark = { [weak self] in self?.onMenuBarPulse?() }
        return ctx
    }

    /// The wizard's single combined apply: one pristine-backup write for everything chosen, then
    /// the opt-in flags (whose observers' re-applies are no-ops — the keys already read freed, so
    /// nothing re-arms the pending markers). Spaces order applies instantly via its own config.
    private func applyLanesFromWizard(_ choices: LaneChoices) -> LanesApplyOutcome {
        var outcome = LanesApplyOutcome()
        var requested: GestureFeatures = trackpadConfig.isClaimed ? .horizontal : []
        if choices.spaceRows { requested.insert(.spaceRows) }
        if choices.launcher { requested.insert(.launcher) }
        if !requested.isEmpty {
            let result = relocationApplier.apply(requested: requested, context: [])
            outcome.failed = result.failed
            outcome.appliedAny = !result.applied.isEmpty
        }
        if choices.spaceRows, !outcome.failed.contains(.spaceRows) { settings.manageVerticalGesture = true }
        if choices.launcher, !outcome.failed.contains(.launcher) { settings.enableLauncher = true }
        if choices.fixedSpaces, spacesRearrange.isAutoRearrangeOn {
            let ok = spacesRearrange.disableAutoRearrange()
            outcome.spacesFailed = !ok
            if ok { settings.manageSpacesRearrange = true }   // observer's re-apply is a no-op
        }
        refreshRowSwitchingGate()
        onStateChange?()
        return outcome
    }

    /// Trigger the OS log-out via the standard ⇧⌘Q keystroke (uses the already-held Accessibility
    /// permission; macOS shows its own confirmation). Without Accessibility this is a no-op — the
    /// act's caption points at the Apple menu as the manual path.
    private func sendLogOutKeystroke() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true),   // Q
              let up = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Configuration Hub

    /// Open (or bring forward) the single configuration Hub window, optionally deep-linking a page.
    /// One reusable window with a persisted frame, mirroring the former Settings/Favorites windows.
    func showHub(selecting destination: HubDestination? = nil) {
        if let destination { hubNav.selection = destination }
        if hubWindow == nil {
            let host = NSHostingController(rootView: HubView(context: hubContext, nav: hubNav))
            let window = NSWindow(contentViewController: host)
            window.title = "ThreeFingerSwitcher"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            let restored = window.setFrameUsingName("HubWindow")
            window.setFrameAutosaveName("HubWindow")
            if !restored {
                window.setContentSize(NSSize(width: 1160, height: 720))
                window.center()
            }
            // Authoritatively pause the self-playing gesture previews whenever the Hub leaves the screen
            // and resume them when it returns. The window + its SwiftUI tree are kept alive for reuse, so
            // SwiftUI's `.onDisappear` is unreliable on close/miniaturize — without this the previews'
            // 30 Hz `HubDemoDriver` loops keep ticking after the Hub is closed, driving the demo models +
            // re-rendering the offscreen overlay on the main run loop and starving the real
            // switcher/launcher gesture. Registered once (the window is reused), scoped to THIS window.
            let nc = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pauseHubPreviews() }
                }
            }
            nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeHubPreviews() }
            }
            hubWindow = window
        }
        present(hubWindow)
        // Re-arm the previews in case the Hub was previously closed/minimized (the window — and so the
        // paused drivers — are reused). Idempotent: a no-op on the first open (no drivers mounted yet;
        // their own `.onAppear` starts them) and when already running.
        resumeHubPreviews()
        // Remember which Space the Hub now lives on so the synthetic switcher entry lands in that
        // Space's row. `present` activates + makes the Hub key on the current Space, so the current
        // Space is where it is now visible (the Hub does not join all Spaces).
        hubSpaceID = SpaceService.currentModel()?.currentSpaceIDs.first
    }

    /// Pause the Hub's self-playing gesture previews (and clear any rehearse target) — called when the
    /// Hub leaves the screen. Stops every `HubDemoDriver` loop via the authoritative notification so none
    /// can keep running on the main run loop after the Hub is gone, and resets the rehearse controller so
    /// no stale target lingers (belt-and-suspenders alongside the `hubPreviewOwnsGestures` `isKeyWindow`
    /// fail-safe).
    private func pauseHubPreviews() {
        NotificationCenter.default.post(name: .hubPreviewsPause, object: nil)
        hubRehearse.reset()
    }

    /// Resume the previews when the Hub returns to the screen (reopen / deminiaturize). `HubDemoDriver`
    /// restart is idempotent — the loop only re-arms if it had been stopped.
    private func resumeHubPreviews() {
        NotificationCenter.default.post(name: .hubPreviewsResume, object: nil)
    }

    /// Wire the Hub's references and callbacks once. Closures are weak-self so the context never
    /// retains the coordinator beyond its lifetime. Live state is provided as closures so each render
    /// reads the current value (backup existence, re-login warnings, opt-in state).
    private func makeHubContext() -> HubContext {
        let ctx = HubContext(settings: settings,
                             favorites: favoritesStore,
                             clipboard: clipboardStore,
                             models: modelManager,
                             permissions: permissions)
        // §2.3 rehearse seam: hand the shared rehearse controller to the previewed pages (each
        // `HubGesturePreview` binds its `liveDots` to it and registers as the active target), and route
        // the touch feed into it. Contacts are mapped to normalized points HERE (the `OMSTouchData`
        // boundary) so `HubRehearseController` stays Core-pure. An empty frame (lift) ingests as 0
        // fingers → the gate closes (dots clear, recognizer resumes).
        ctx.rehearse = hubRehearse
        onHubPreviewTouchFrame = { [weak self] frame in
            let contacts = frame.contacts.map { CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y)) }
            self?.hubRehearse.ingest(fingerCount: frame.fingerCount, contacts: contacts)
        }
        // §11.2 Real demo content for the gesture previews — the SAME providers `makeWizardContext`
        // wires, so the Hub renders the real switcher/launcher seeded with the user's content. No new
        // permission (these read already-available state / reuse granted Screen Recording).
        ctx.realWindowRows = { [weak self] in
            guard let self else { return [] }
            // The user's actual windows, current Space first. One row is enough for the mini.
            let snapshot = self.windowService.snapshot()
            let current = snapshot.filter(\.isOnCurrentSpace)
            return [current.isEmpty ? snapshot : current]
        }
        ctx.seedThumbnails = { [weak self] model in
            guard let self else { return }
            // PRODUCTION semantics (mirrors `makeWizardContext.seedThumbnails`): live-capture every
            // cleanly-presented window now, leaving parked/set-aside ones as icon+title until a later
            // sweep can capture them. Two delayed sweeps retry the cards still missing an image. The
            // wizard sweeps re-capture `self.wizardModel?.demo`; here the PASSED `model` IS the Hub's
            // switcher demo model, so the retries weakly target IT.
            let windows = model.windows
            self.thumbnails.seed(into: model, ids: windows.map(\.id))
            self.thumbnails.prefetch(windows)
            for delay in [0.7, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak model] in
                    guard let self, let model else { return }
                    let missing = windows.filter { model.thumbnails[$0.id] == nil }
                    guard !missing.isEmpty else { return }
                    self.thumbnails.seed(into: model, ids: missing.map(\.id))
                    self.thumbnails.prefetch(missing)
                }
            }
        }
        ctx.launcherBands = { [weak self] clipboardOn, aiOn in
            guard let self else { return [] }
            let clipboard: ContextBand? = clipboardOn ? {
                let entries = self.clipboardStore.recentWindow(limit: self.settings.clipboardRecentWindow)
                return ClipboardBandBuilder.build(
                    from: entries.isEmpty ? WizardSampleContent.clipboardEntries() : entries)
            }() : nil
            return WizardTourBands.compose(userBands: self.favoritesStore.favorites.bands,
                                           aiOn: aiOn,
                                           seededAIBand: AIBand.seededBand,
                                           clipboardBand: clipboard)
        }
        // Clipboard.
        ctx.onClearClipboard = { [weak self] includingPinned in self?.clipboardStore.clear(includingPinned: includingPinned) }
        // AI.
        ctx.onDownloadModel = { [weak self] in self?.downloadAIModel() }
        // Keyboard Language — the picker's source list (forwarded from the service's controller seam so
        // the page never imports Carbon).
        ctx.enabledInputSources = { [weak self] in self?.keyboardLanguageService.controllerEnabledSources() ?? [] }
        // Setup — the welcome tour entry (resume while incomplete, replay after) + self-relaunch.
        ctx.onShowWelcomeTour = { [weak self] in
            guard let self else { return }
            if self.firstRun.isCompleted { self.replayFirstTouchWizard() } else { self.showFirstTouchWizard() }
        }
        ctx.firstRunCompleted = { [weak self] in self?.firstRun.isCompleted ?? true }
        ctx.onRelaunchApp = { [weak self] in self?.relaunchApp() }
        // Overview — the one-re-login banner.
        ctx.relocationsPendingRelogin = { [weak self] in self?.relocationsStillPending ?? false }
        ctx.onLogOutNow = { [weak self] in self?.sendLogOutKeystroke() }
        // Setup — actions.
        ctx.onSetupNativeGesture = { [weak self] in self?.promptNativeGestureSetup() }
        ctx.onRestoreNativeGesture = { [weak self] in self?.restoreNativeGestureSetting() }
        ctx.onKeepSpacesFixed = { [weak self] in self?.promptSpacesRearrangeSetup() }
        ctx.onEnableSpaceRowSwitching = { [weak self] in self?.promptVerticalGestureSetup() }
        ctx.onRestoreMissionControl = { [weak self] in self?.restoreVerticalGestureSetting() }
        ctx.onEnableLauncher = { [weak self] in self?.promptLauncherSetup() }
        ctx.onRestoreLauncher = { [weak self] in self?.restoreLauncherGestureSetting() }
        ctx.onRefreshPermissions = { [weak self] in self?.permissions.refresh() }
        // Setup — live state.
        ctx.trackpadClaimed = { [weak self] in self?.trackpadConfig.isClaimed ?? false }
        ctx.trackpadHasBackup = { [weak self] in self?.trackpadConfig.hasBackup ?? false }
        ctx.trackpadNeedsRelogin = { [weak self] in self?.trackpadConfig.needsReloginWarning ?? false }
        ctx.spacesAutoRearrangeOn = { [weak self] in self?.spacesRearrange.isAutoRearrangeOn ?? false }
        ctx.spaceRowNeedsRelogin = { [weak self] in self?.verticalGesture.needsReloginWarning ?? false }
        ctx.verticalGestureHasBackup = { [weak self] in self?.verticalGesture.hasBackup ?? false }
        ctx.launcherNeedsRelogin = { [weak self] in self?.fourFingerGesture.needsReloginWarning ?? false }
        ctx.launcherHasBackup = { [weak self] in self?.fourFingerGesture.hasBackup ?? false }
        // General.
        ctx.isOpenAtLogin = { [weak self] in self?.isOpenAtLogin ?? false }
        ctx.onToggleOpenAtLogin = { [weak self] in self?.toggleOpenAtLogin() }
        ctx.onWriteDiagnostics = { [weak self] in self?.writeDiagnostics() }
        ctx.onCopyFocusLog = { [weak self] in self?.copyFocusLog() }
        // Devices (device link).
        ctx.pairedDevices = { [weak self] in self?.pairedDeviceStore.all() ?? [] }
        ctx.onForgetDevice = { [weak self] id in self?.pairedDeviceStore.remove(id: id) }
        ctx.onSendLatestToDevices = { [weak self] in self?.sendLatestClipboardToDevices() }
        ctx.pairingCoordinator = macPairingCoordinator
        // Danger zone.
        ctx.onDangerZoneClear = { [weak self] selection in self?.dangerZoneClear(selection) }
        ctx.onRestoreAllGestures = { [weak self] in self?.restoreAllNativeGestures() }
        return ctx
    }

    // MARK: - Windows

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Windows that persist their own frame (a non-empty autosave name, e.g. the Hub) keep their
        // saved position; only center a transient window without one.
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
        stopPreviewRefresh()
    }
}
