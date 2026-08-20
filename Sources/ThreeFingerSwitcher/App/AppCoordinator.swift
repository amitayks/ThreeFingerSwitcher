import AppKit
import Combine
import ServiceManagement
import SwiftUI
import os

private let windowGroupsLog = Logger(subsystem: "ThreeFingerSwitcher", category: "WindowGroups")

/// Owns and wires the whole pipeline: touch → recognizer → overlay highlight → commit raise.
/// Also drives onboarding, settings, and the native-gesture consent flow.
@MainActor
final class AppCoordinator: GestureRecognizerDelegate, KeyboardSwitcherDelegate {
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
    /// The ⌘-Tab keyboard driver (opt-in `commandTabSwitcher`): the tap intercepts ⌘-Tab and feeds the
    /// pure state machine, which emits open/step/first/commit/cancel intents into this coordinator.
    private let keyboardSwitcherTap = KeyboardSwitcherTap()
    private let keyboardSwitcher = KeyboardSwitcher()
    /// Which driver currently owns the switcher overlay — enforces one session at a time (design D7).
    private enum SwitcherOwner { case none, trackpad, keyboard }
    private var switcherOwner: SwitcherOwner = .none
    private var cancellables: Set<AnyCancellable> = []

    // Dock-hover window previews (opt-in; the switcher "from another angle"). Reuses windowService for
    // enumeration + raise; owns its own cursor monitor, Dock AX reader, thumbnails, and overlay.
    private lazy var dockPreviewController = DockPreviewController(
        cursor: GlobalCursorMonitor(),
        reader: AXDockReader(),
        windowService: windowService,
        switcherThumbnails: thumbnails
    )

    // Window groups (opt-in; snap-to-bind): the runtime group store plus the passive drag-end snap
    // monitor that populates it. Groups are validated lazily against live snapshots at consumption
    // (switcher open + commit) — see `WindowGroupStore`.
    private let windowGroups = WindowGroupStore()
    private lazy var snapMonitor = WindowSnapMonitor(store: windowGroups)

    /// The Keep Awake automation's stateful owner (`automations`). Idle until a `.automation(.keepAwake)`
    /// item is fired (which toggles it via `LaunchService.onAutomation`). Fed the touch stream for its
    /// first-touch-to-stop arming, and force-stopped on quit / will-sleep so a dimmed screen is never
    /// stranded. `onActiveChanged` is wired in `init` to rebuild the menu-bar "Active / Stop" line.
    private let keepAwakeController = KeepAwakeController()

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
        // Persist the folder picked at fire time for a choose-folder-at-launch item, so its chooser
        // re-opens there next time (the item is the single source of truth for its last-used folder).
        onPromptedFolderChosen: { [weak self] itemID, bandID, folder in
            self?.favoritesStore.updateItem(itemID, inBand: bandID) { $0.kind = $0.kind.withLastFolder(folder) }
        },
        // An automation item TOGGLES its stateful owner (start if inactive, stop if active) — not a
        // one-shot completion. v1 has one automation: Keep Awake, configured per item (dim level,
        // keyboard-backlight dim, and the any-input guard lock — `keep-awake-guard-effects`).
        onAutomation: { [weak self] kind, settings in
            switch kind {
            case .keepAwake:
                self?.keepAwakeController.toggle(KeepAwakeController.Config(
                    dimLevel: KeepAwakeController.fraction(fromPercent: settings.dimPercent),
                    dimKeyboard: settings.dimKeyboard,
                    lockOnStop: settings.lockOnStop))
            }
        },
        // The band carries only bounded/light clipboard previews (see `bandWindow`); resolve the FULL
        // entry by id at fire time so paste restores the complete payload, not the truncated preview.
        clipboardResolver: { [weak self] id in self?.clipboardStore.materializedEntry(id: id) }
    )

    /// Frontmost app captured at launcher-open time (target for `.action(.closeFrontWindow)`).
    private var capturedFrontApp: NSRunningApplication?

    // Clipboard history (opt-in; the synthetic Clipboard band + the background recorder).
    private let clipboardStore = ClipboardStore.shared
    private lazy var clipboardMonitor = ClipboardMonitor(store: clipboardStore)

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
        isSupportedBrowserFront: { [weak self] in
            guard let front = NSWorkspace.shared.frontmostApplication else { return false }
            // `NSRunningApplication.bundleIdentifier` is a LaunchServices round-trip, and this runs
            // on every 0.5 s poll tick for as long as a browser is front — memoize it per pid.
            let pid = front.processIdentifier
            if let cached = self?.browserFrontByPid, cached.pid == pid { return cached.supported }
            let supported = BrowserRegistry.isSupported(front.bundleIdentifier ?? "")
            self?.browserFrontByPid = (pid, supported)
            return supported
        },
        onTick: { [weak self] in self?.keyboardLanguageService.reevaluate() }
    )
    private var browserFrontByPid: (pid: pid_t, supported: Bool)?
    /// The pending delayed re-seed sweeps for the Hub's / wizard's switcher demos (cancelled and
    /// replaced on each re-seed so repeated seeding can't stack a backlog of delayed sweeps).
    private var hubSeedRetries: [DispatchWorkItem] = []
    private var wizardSeedRetries: [DispatchWorkItem] = []
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
    /// The Hub window's visibility observers — held so they can be removed if the window is ever
    /// released (discarded tokens would stack three permanent observers per re-creation).
    private var hubWindowObservers: [NSObjectProtocol] = []
    /// The Hub's `CGWindowID`, or nil when it has no window device. `NSWindow.windowNumber` is ≤ 0
    /// for a closed (retained) window and `CGWindowID(Int)` traps on a negative — route every
    /// conversion through here.
    private var hubWindowID: CGWindowID? {
        guard let number = hubWindow?.windowNumber, number > 0 else { return nil }
        return CGWindowID(number)
    }
    private let hubNav = HubNavigation()
    private lazy var hubContext: HubContext = makeHubContext()
    /// The Space the Hub was last presented on (captured in `showHub`). Used to place the synthetic
    /// Hub switcher entry on its own Space-row — the Hub deliberately does NOT join all Spaces, so it
    /// stays where it was opened and the card lands in the right row (committing it raises across
    /// Spaces like any other off-Space window).
    private var hubSpaceID: CGSSpaceID?

    private(set) var isEnabled = false
    var isTrackpadAvailable: Bool { touchEngine.isAvailable }

    /// Whether the diagnostic actions (write diagnostics, copy focus log) are surfaced in the status
    /// menu — gated by the General page's "Show diagnostic tools" preference. The menu reads this at
    /// rebuild time (`StatusItemController.menuNeedsUpdate`), so no live observer is needed.
    var showDiagnostics: Bool { settings.showDiagnostics }

    var onStateChange: (() -> Void)?

    /// The wizard's menu-bar moment: pulses the real status-item mark (wired by
    /// `StatusItemController`) so the wizard can point at the actual pixel the user returns to.
    var onMenuBarPulse: (() -> Void)?

    /// Live finger count from the most recent touch frame; drives the scroll tap's consume rule
    /// (the switcher owns all three-finger scroll so it never leaks to the background). Reset to 0
    /// wherever the touch engine stops, and treated as 0 by the tap once `lastTouchFrameTime` is
    /// stale (see the consume predicate).
    private var currentFingerCount = 0
    private var lastTouchFrameTime: CFTimeInterval = 0

    /// Pure decision for the scroll tap: consume (swallow) scroll while three or more fingers are
    /// down OR while the launcher overlay is open OR while the switcher overlay is open. The
    /// overlay-open clauses capture the two-finger movement that drives launcher / switcher
    /// navigation (after a three- or four-finger trigger relaxes to two) so it doesn't scroll the
    /// window underneath; with both overlays closed it reverts to the `≥3`-fingers rule, leaving
    /// normal two-finger scroll alone.
    ///
    /// `3+` finger is always consumed (gesture territory); the launcher / switcher consume 1-2
    /// finger so stray scroll doesn't leak during nav.
    static func shouldConsumeScroll(fingerCount: Int, launcherOpen: Bool, switcherOpen: Bool) -> Bool {
        fingerCount >= 3 || launcherOpen || switcherOpen
    }

    /// Read-only tap on the touch stream for the wizard's live-hand act (the recognizer path is
    /// untouched; this only mirrors frames).
    var onWizardTouchFrame: ((TouchFrame) -> Void)?

    init() {
        recognizer.delegate = self
        keyboardSwitcher.delegate = self
        keyboardSwitcherTap.input = keyboardSwitcher
        touchEngine.onFrame = { [weak self] frame in
            guard let self else { return }
            self.currentFingerCount = frame.fingerCount
            self.lastTouchFrameTime = frame.time
            // The wizard's live-hand act still mirrors every frame (read-only). The Hub gesture previews are
            // pure autoplay (they don't read the touch feed), so nothing else taps the stream here.
            self.onWizardTouchFrame?(frame)
            // Keep Awake's first-touch-to-stop arming (non-consuming — a no-op unless it's active, and it
            // never swallows the frame; the recognizer still sees it below).
            self.keepAwakeController.noteTouch(fingerCount: frame.fingerCount)
            self.recognizer.feed(frame)
        }
        scrollTap.consumePredicate = { [weak self] in
            guard let self else { return false }
            // Staleness guard: if the touch stream died mid-gesture (sleep with fingers down, the
            // multitouch stream going silent), `currentFingerCount` would otherwise stay ≥ 3 and
            // this tap would swallow EVERY scroll, in every app, until the app was quit. A finger
            // count older than half a second is treated as no fingers.
            let stale = CACurrentMediaTime() - self.lastTouchFrameTime > 0.5
            return Self.shouldConsumeScroll(fingerCount: stale ? 0 : self.currentFingerCount,
                                            launcherOpen: self.launcherOverlay.isVisible,
                                            switcherOpen: self.overlay.isVisible)
        }
        thumbnails.onThumbnail = { [weak self] id, image in
            self?.overlay.model.setThumbnail(image, for: id)
            // The wizard's demo strip listens along while it lives (the post-Screen-Recording reveal).
            self?.wizardModel?.demo.setThumbnail(image, for: id)
        }
        // The menu-bar "Keep Awake — Active / Stop" line tracks the automation live (it otherwise
        // only corrected itself on the next menu open).
        keepAwakeController.onActiveChanged = { [weak self] in self?.onStateChange?() }
        launcherOverlay.onFire = { [weak self] item, band in self?.launchService.fire(item, inBand: band) }
        launcherOverlay.onTogglePin = { [weak self] item in
            guard case let .clipboardEntry(entry) = item.kind else { return }
            self?.clipboardStore.togglePin(id: entry.id)
        }
        observeSleepWake()
        observeAccessibilityGrant()
        observeEnabledToggle()
        observeSpacesRearrangeToggle()
        observeVerticalGestureToggle()
        observeCommandTabToggle()
        observeLauncherToggle()
        observeClipboardToggle()
        observeKeyboardLanguageToggle()
        observeKeyboardLanguagePerSiteToggle()
        observeKeyboardLanguageBrowserControlToggle()
        observeDockPreviewsToggle()
        observeWindowGroupsToggle()
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
        // Snap-to-bind window groups: same standalone opt-in shape — when off, the left-mouse
        // monitors aren't even installed.
        snapMonitor.setEnabled(settings.enableWindowGroups)
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
        currentFingerCount = 0
        scrollTap.stop()
        keyboardSwitcherTap.stop()
        keyboardSwitcher.forceCancel()   // tear down any open ⌘-Tab session before hiding the overlay
        mru.stop()
        focus.stop()
        overlay.hide()
        stopPreviewRefresh()
        launcherOverlay.cancel()
        clipboardMonitor.stop()
        isEnabled = false
        settings.enabled = false
        onStateChange?()
    }

    func toggleEnabled() { isEnabled ? disable() : enable() }

    // MARK: - Keep Awake (menu-bar fallback + guaranteed teardown)

    /// Whether the Keep Awake automation is currently running — drives the menu-bar "Active / Stop" line.
    var keepAwakeActive: Bool { keepAwakeController.isActive }

    /// Stop Keep Awake (restore brightness + release the assertion). The menu-bar fallback stop, and the
    /// force-restore path called on quit so a dimmed-to-black screen is never left behind. Idempotent.
    func stopKeepAwake() { keepAwakeController.stop() }

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
            // `@Published` fires on every WRITE (willSet), not every change — and `enable()`/`disable()`
            // re-write `settings.enabled` internally. Because the body below is deferred with
            // `DispatchQueue.main.async`, the `applyingEnabledToggle` flag is already false again by the
            // time the deferred block runs, so a same-value re-emission slipped past the guard. In the
            // no-trackpad case (`enable()` can never set `isEnabled = true`) that produced an UNBOUNDED
            // main-queue ping-pong — enable → write → emission → enable … — each lap re-running the full
            // enable path forever. Dropping same-value emissions ends the cycle after one lap.
            .removeDuplicates()
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

    /// Re-arm the event taps when Accessibility is (re)granted mid-session. `CGEvent.tapCreate` fails
    /// without the grant and its result was discarded — so a user who granted the permission outside
    /// the wizard flow, or revoked and re-granted it, silently lost scroll consumption and ⌘-Tab until
    /// a relaunch or a settings toggle happened to call the gate refresh. `removeDuplicates` keeps the
    /// 1 Hz permission poll from re-running the refresh per tick.
    private func observeAccessibilityGrant() {
        permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard status == .granted, let self, self.isEnabled else { return }
                    self.refreshRowSwitchingGate()
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

        // `missionControlOpen` is our own latch — set when WE synthesize Mission Control — and nothing
        // told us when the user closed it some other way (clicking a window, picking a Space, F3).
        // Stale-true meant every later switcher open floated at screen-saver level and every commit
        // posted a stray Escape into the user's app. The two observable ways out of MC — a regular
        // app being activated, or the active Space changing — clear it. (The Dock is `.prohibited`,
        // so MC opening itself never trips the activation clear.)
        let activation = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, app.processIdentifier != getpid() else { return }
            MainActor.assumeIsolated { self?.missionControlOpen = false }
        }
        wakeObservers.append(activation)
        let spaceChange = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.missionControlOpen = false }
        }
        wakeObservers.append(spaceChange)
    }

    private func handleWillSleep() {
        // Stand Keep Awake down BEFORE the isEnabled guard: if the machine sleeps anyway (e.g. lid
        // close forces it despite the assertion), restore brightness + release the assertion now so we
        // wake into a clean state. Idempotent, so it's harmless when inactive.
        keepAwakeController.stop()
        // Drop any in-flight gesture/overlay so we don't wake into a half-committed state.
        guard isEnabled else { return }
        recognizer.reset()
        keyboardSwitcher.forceCancel()   // don't wake into a half-open ⌘-Tab session
        overlay.hide()
        stopPreviewRefresh()
        launcherOverlay.cancel()
        // CRITICAL: stop the multitouch listener NOW, while its CFRunLoopSource is still valid. The OS
        // invalidates the device source during system sleep; calling `manager.stopListening()` AFTER
        // wake then traps on a freed source (EXC_BREAKPOINT in MTDeviceStop — observed during long
        // model downloads that span a sleep). Stopping pre-sleep makes the post-wake `stop()` a no-op,
        // and `restartTouchEngineAfterWake()` attaches a fresh listener on `didWake`.
        touchEngine.stop()
        // The stream is gone, so the last frame's finger count must not linger (the scroll tap
        // would otherwise keep consuming), and any Mission Control we had open is closed by sleep.
        currentFingerCount = 0
        missionControlOpen = false
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
        currentFingerCount = 0
        // Re-attach the focus tracker's AX observer torn down in `handleWillSleep`. Idempotent.
        focus.stop()
        focus.start()
        // If the trackpad couldn't be re-acquired, reflect that in the menu state — and stand the
        // event taps down with it: flipping `isEnabled` alone left both taps armed against a dead
        // engine, with `disable()` then a no-op (its guard already false), so nothing ever repaired it.
        let available = touchEngine.isAvailable
        if isEnabled != available {
            isEnabled = available
            refreshRowSwitchingGate()
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
        // A ⌘-Tab session owns the overlay: the trackpad gesture defers rather than clobber it (D7).
        guard switcherOwner != .keyboard else { return }
        _ = openSwitcher(owner: .trackpad)
    }

    /// Open the switcher overlay from either driver (the trackpad gesture or ⌘-Tab). Input-agnostic:
    /// snapshot windows (+ the synthetic Hub card when open), group into Space-rows, show, seed every
    /// Space's cached previews, capture the visible row, and start the periodic refresh. Records the
    /// owning driver so only one session runs at a time. Returns whether it actually opened (false when
    /// there are no windows to show).
    @discardableResult
    private func openSwitcher(owner: SwitcherOwner) -> Bool {
        var windows = windowService.snapshot()
        // Inject the configuration Hub as a synthetic switcher entry whenever it is open. The snapshot
        // filters out our own PID (so the overlay panels never leak); the Hub is the one window we add
        // back, on purpose, icon-only, on the Space it was opened on. Accessory mode is unchanged.
        if let hub = hubSwitcherEntry(snapshot: windows) {
            windows.append(hub)
        }
        guard !windows.isEmpty else { return false }
        // Prune the last-good-frame cache to windows that still exist somewhere (the snapshot is the
        // full cross-Space enumeration): closed windows' frames otherwise pin image memory and, under
        // the LRU cap, evict frames of windows that are still alive.
        thumbnails.retain(only: Set(windows.map(\.id)))
        let grid = SpaceGrouping.group(windows)
        // When the app has Mission Control open, float the overlay above it (otherwise it renders
        // behind the MC windows). The elevated config is scoped to this case in `OverlayController`.
        overlay.show(rows: grid.rows, labels: grid.labels, startRow: grid.startRow, column: 0,
                     aboveMissionControl: missionControlOpen,
                     // Opted in but the relocation hasn't survived its re-login yet: the row dots
                     // dim with a pending glyph so the gated vertical axis explains itself.
                     // Read the gate the recognizer already holds — NOT `isSpaceRowSwitchingEffective`,
                     // which shells out to `/usr/bin/defaults` (fork + waitpid, 30–100 ms) on the
                     // main thread. That spawn sat inline in EVERY switcher open for anyone with
                     // Space-row switching on (the `&&` short-circuits it away on default installs).
                     rowSwitchingPending: settings.manageVerticalGesture && !recognizer.rowSwitchingEnabled,
                     windowScale: CGFloat(settings.switcherWindowScale),
                     groups: validatedWindowGroups(against: windows))
        switcherOwner = owner
        seedAllRows()         // every Space's cached previews present up front (no first-visit rebuild)
        prefetchCurrentRow()  // immediate capture of the whole visible row (no highlight needed)
        startPreviewRefresh()
        return true
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
        stepGridRow(direction)
    }

    /// Shared vertical grid step (trackpad scrub + ⌘-Tab Up/Down): move between the grid's visual
    /// rows with positional (sticky-anchor) landing; only a top/bottom-edge crossing switches Space.
    private func stepGridRow(_ direction: Int) {
        switch overlay.moveVertical(direction) {
        case .moved:
            break   // highlight only; the periodic sweep keeps the visible row's previews fresh
        case .atEdge(let spaceDelta):
            switchSpace(by: spaceDelta)
        }
    }

    /// Switch to an adjacent Space-row (from a grid-edge vertical scrub), clamping or wrapping per the
    /// setting, landing positionally — up enters the new grid's bottom visual row, down its top row,
    /// on the card nearest the vertical run's anchor — and refresh thumbnails/live preview for the new
    /// Space exactly as before.
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
        overlay.updateRowPositional(row, upward: delta > 0)
        prefetchCurrentRow()   // seed the new Space's cached thumbnails now + immediately re-capture the row
        // …then freeze: async captures landing during the slide are buffered (so they can't snap it) and
        // cut in once it settles. Must follow the seed (done inside prefetchCurrentRow) and precede the
        // captures it kicks.
        overlay.beginSlideFreeze()
    }

    func gestureDidTriggerMissionControl(up: Bool) {
        guard !wizardOwnsGestures else { return }   // no OS overviews over the wizard's stage
        // The DOWN swipe maps to the configured down-action: when the swipe-down minimize-all opt-in is on,
        // genuinely minimize every current-Space window (reveal the desktop, Windows Win+D) instead of the
        // synthesized App Exposé. The recognizer emits the same one-shot down intent either way — only the
        // action selected here differs. UP is always Mission Control.
        if !up && settings.swipeDownMinimizesAll {
            // Capture each current-Space window's live frame BEFORE minimizing so the switcher shows a real
            // last-good preview for the minimized window (not a bare icon); THEN minimize. The capture is
            // awaited so it grabs the still-on-screen frames, never a mid-genie one. (A tabbed window is one
            // merged window here, so only its front frame is captured — its background tabs keep the icon.)
            let toCapture = windowService.currentSpaceMinimizableWindows()
            Task { [weak self] in
                await self?.thumbnails.captureNow(toCapture)
                self?.windowService.minimizeAllWindows()
            }
            missionControlOpen = false   // no overview opened; nothing for a later commit to dismiss
            return
        }
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
        let hubID = hubWindowID
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
        let hubID = hubWindowID
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
        previewRefreshTimer?.tolerance = 0.2   // drives a capture sweep, not an animation — let it coalesce
    }

    /// Stop the periodic preview refresh. Idempotent — safe when already stopped (the timer is nil) — so it
    /// can be paired with every overlay teardown site unconditionally. The thumbnail cache persists as the
    /// last-good-frame store; only the in-flight SWEEP is cancelled (it would otherwise keep enumerating +
    /// capturing into the now-hidden overlay until it drained).
    private func stopPreviewRefresh() {
        previewRefreshTimer?.invalidate()
        previewRefreshTimer = nil
        thumbnails.cancelSweeps()
    }

    /// The one pending commit action deferred past Mission Control's close animation. Single-slot:
    /// a second commit inside that 0.3 s (MC already marked closed, so it raises immediately) must
    /// not be overridden when the FIRST commit's deferred raise fires a beat later.
    private var missionControlDismissDeferral: DispatchWorkItem?

    private func deferPastMissionControlDismiss(_ body: @escaping @MainActor () -> Void) {
        missionControlDismissDeferral?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        missionControlDismissDeferral = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func gestureDidCommit() {
        switcherOwner = .none   // the session is ending regardless of which branch below runs
        missionControlDismissDeferral?.cancel()   // a newer commit supersedes a pending deferred raise
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
                deferPastMissionControlDismiss { [weak self] in self?.present(self?.hubWindow) }
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
            deferPastMissionControlDismiss { [weak self] in self?.raiseCommitted(window) }
        } else {
            raiseCommitted(window)
        }
    }

    /// Raise a committed switcher/⌘-Tab selection, un-minimizing it first when it is a minimized window
    /// (present only with the include-minimized-windows opt-in). `raiseDeminimizing` clears `kAXMinimized` —
    /// which restores the window's prior position/size — then runs the same hardened `raise`; a non-minimized
    /// selection raises exactly as before. When the selection belongs to a validated window GROUP
    /// (window-groups opt-in), the whole group raises — mates fronted lightly first, the selected member
    /// last with focus — and because this is the ONE shared commit point, trackpad and ⌘-Tab inherit it
    /// identically. (A minimized window is never in a validated group — validation drops minimized
    /// members — so the branches cannot overlap.)
    private func raiseCommitted(_ window: WindowInfo) {
        if let mates = windowGroupMates(of: window), !mates.isEmpty {
            windowService.raiseGroup(mates: mates, selected: window)
        } else if window.isMinimized {
            windowService.raiseDeminimizing(window)
        } else {
            windowService.raise(window)
        }
    }

    /// The validated group-mates of a committed window (window-groups opt-in), resolved from the
    /// overlay's current snapshot rows — the same `WindowInfo`s (with AX elements) the switcher shows.
    /// Nil when the feature is off or the window is ungrouped; validation happens at this consumption
    /// point too, so a member closed/minimized mid-session can never be raised.
    private func windowGroupMates(of window: WindowInfo) -> [WindowInfo]? {
        guard settings.enableWindowGroups else { return nil }
        let shown = overlay.model.rows.flatMap { $0 }
        let validated = validatedWindowGroups(against: shown)
        guard let group = validated.first(where: { $0.contains(window.id) }) else { return nil }
        return shown.filter { group.contains($0.id) && $0.id != window.id }
    }

    /// Validate the group store against a live snapshot (dropping closed/minimized/off-Space members —
    /// the lazy-lifecycle consumption point) and return the surviving groups. Empty when the opt-in
    /// is off, so the layout and commit paths degrade to exactly the pre-groups behavior.
    private func validatedWindowGroups(against windows: [WindowInfo]) -> [Set<CGWindowID>] {
        guard settings.enableWindowGroups else { return [] }
        let stored = windowGroups.groups
        // `realFrame` (AX, top-left global — same handedness as the monitor's CG frames) feeds the
        // geometric validation: members that no longer touch have detached, even when the resize/move
        // that separated them was never seen by the mouse monitor (keyboard/AX-driven).
        let validated = windowGroups.validatedGroups(against: windows.map {
            WindowGroupStore.Candidate(id: $0.id, isMinimized: $0.isMinimized,
                                       spaceID: $0.spaceID, frame: $0.realFrame)
        })
        windowGroupsLog.log("validate: stored \(stored.map { $0.sorted() }, privacy: .public) vs snapshot \(windows.count) windows -> \(validated.map { $0.sorted() }, privacy: .public)")
        return validated
    }

    func gestureDidCancel() {
        switcherOwner = .none
        overlay.hide()
        stopPreviewRefresh()
    }

    // MARK: - KeyboardSwitcherDelegate (⌘-Tab driver)
    //
    // These run INSIDE the keyboard event-tap callback, which the WindowServer blocks on until it
    // returns — so the callback must stay cheap. All heavy work (window snapshot, overlay show,
    // thumbnail prefetch, the cross-Space raise) is dispatched to the next main-runloop tick; only cheap
    // ownership bookkeeping stays synchronous. The blocks queue in event order (FIFO), so open runs
    // before its steps and commit runs last. (The trackpad path calls the SAME shared methods
    // synchronously from the touch-frame handler, which does not block the WindowServer, so it is
    // unaffected.) Doing this work synchronously in the tap callback stalled the whole input pipeline —
    // including trackpad frames + highlight rendering on the same main thread — behind each keypress.

    /// First Tab: claim ownership synchronously (so following steps see it) and open on the next tick.
    /// Refuses (returns false, leaving the session armed to retry) while onboarding owns the stage or a
    /// trackpad gesture already owns the overlay (D7).
    func keyboardSwitcherOpen() -> Bool {
        guard !wizardOwnsGestures else { return false }
        guard switcherOwner != .trackpad else { return false }
        switcherOwner = .keyboard
        DispatchQueue.main.async { [weak self] in
            guard let self, self.switcherOwner == .keyboard else { return }
            if !self.openSwitcher(owner: .keyboard) { self.switcherOwner = .none }   // no windows → release
        }
        return true
    }

    /// Tab (forward) / Shift+Tab (backward): step the selection one window along the flat reel order,
    /// flowing across Spaces in that direction. A cross-Space step refreshes the newly visible row's
    /// previews (as `switchSpace` does for the trackpad).
    func keyboardSwitcherStep(forward: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.switcherOwner == .keyboard, self.overlay.isVisible else { return }
            if self.overlay.selectLinear(delta: forward ? 1 : -1, wrap: self.settings.wrapAtEnds) {
                self.afterKeyboardRowChange()
            }
        }
    }

    /// Up/Down arrow: navigate the grid's visual rows through the SAME path as the trackpad's vertical
    /// scrub (`stepGridRow` — positional landing, Space switch only at the grid's top/bottom edge, wrap
    /// per the setting). The arrow is literal — Up always moves the highlight visually up — so
    /// `reverseVerticalDirection` does NOT flip it: that setting expresses a finger-vs-content *scrub*
    /// preference, which has no meaning for a directional keypress. (When it flipped the old
    /// jump-a-whole-Space arrows, "Up" could move the reel down — with grid-row movement that would
    /// read as the highlight moving against the arrow.)
    func keyboardSwitcherStepSpace(up: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.switcherOwner == .keyboard, self.overlay.isVisible else { return }
            // An edge crossing runs `switchSpace`, which already refreshes + freezes the new row.
            self.stepGridRow(up ? 1 : -1)
        }
    }

    /// ⌘ released: commit through the shared raise path (cross-Space raise, Hub card, and
    /// Mission-Control-open handling all live in `gestureDidCommit` — reuse, don't duplicate).
    ///
    /// DEFERS like open/step (and cancel), so the whole sequence drains in FIFO order — open → step →
    /// commit — keeping the invariant that commit runs AFTER the open that shows the overlay and the step
    /// that advances it. A SYNCHRONOUS commit broke that order on a fast ⌘-Tab press-release: the tap can
    /// process the entire ⌘-down / Tab / ⌘-up burst before the run loop drains the deferred open/step, so
    /// a synchronous commit ran FIRST — it saw `overlay.isVisible == false` (open hadn't run), dismissed
    /// nothing, and the open/step then drained and stranded a now-commitless overlay on screen (§9.7).
    /// Focus no longer needs the raise to be synchronous: `WindowService.raise` arms the polling
    /// hold-guard for EVERY off-Space raise (§9.5), which re-fronts the target for ~1.2s and defeats the
    /// "selected then deselected" steal regardless of WHEN the raise fires. Deferring by one run-loop
    /// tick is imperceptible and is a ONE-TIME end-of-gesture raise (not per-keystroke browsing work), so
    /// it reintroduces neither the focus-steal nor the browsing lag.
    func keyboardSwitcherCommit() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.switcherOwner == .keyboard else { return }
            self.gestureDidCommit()
        }
    }

    /// Esc, or an external teardown: dismiss without raising, through the shared cancel path.
    func keyboardSwitcherCancel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.switcherOwner == .keyboard else { return }
            self.gestureDidCancel()
        }
    }

    /// The tail of a ⌘-Tab Space crossing: seed + capture the new row and freeze late captures for the
    /// slide, exactly as `switchSpace` does for a trackpad grid-edge crossing.
    private func afterKeyboardRowChange() {
        prefetchCurrentRow()
        overlay.beginSlideFreeze()
    }

    // MARK: - GestureRecognizerDelegate (four-finger launcher)

    func launcherDidActivate() {
        // The wizard's stage owns the trackpad — and on the playground act it puts real launcher
        // intents to work: the embedded tour responds to the user's actual four-finger gestures
        // (the recognizer only emits these when the relocation is effective, so this is exactly
        // the post-re-login / replay case).
        if wizardOwnsGestures { wizardModel?.launcherTourActivate(); return }

        let fav = favoritesStore.favorites
        var bands = fav.bands
        var clipboardBandIndex: Int?
        if settings.keepClipboardHistory {
            // `bandWindow` (not `recentWindow`): light entries with bounded previews so building the band
            // never loads full large payloads into memory. Full content is resolved on demand for paste.
            let entries = clipboardStore.bandWindow(limit: settings.clipboardRecentWindow)
            bands.append(ClipboardBandBuilder.build(from: entries))
            clipboardBandIndex = bands.count - 1
        }
        guard !bands.isEmpty else { return }
        // Capture the app the user was looking at before the (non-activating) overlay appears, so a
        // `.action(.closeFrontWindow)` item — and a clipboard paste — targets that window.
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
                             clipboardBandIndex: clipboardBandIndex)
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

    func launcherEdgeChanged(dx: Int, dy: Int) {
        guard !wizardOwnsGestures else { return }   // no edge auto-repeat in the wizard's tour
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

    /// React to the `enableWindowGroups` toggle (mirrors `observeDockPreviewsToggle`): ON installs the
    /// passive left-mouse snap monitor; OFF removes it AND clears the store, so re-enabling never
    /// resurrects stale groups.
    private func observeWindowGroupsToggle() {
        settings.$enableWindowGroups
            .dropFirst()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.snapMonitor.setEnabled(on) } }
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

    // MARK: - Keyboard language opt-in lifecycle

    /// React to the "Remember the keyboard language per app" toggle: start/stop the service so its
    /// activation and input-source observers exist only while the feature is on (design D9 — fully inert
    /// when off). Gated solely on this toggle, independent of the switcher master enable. Uses the
    /// EMITTED value, not a re-read (the `@Published` willSet would still report the OLD value here —
    /// same reason the gesture and clipboard toggles pass `on` through).
    private func observeKeyboardLanguageToggle() {
        settings.$keyboardLanguageEnabled
            .dropFirst()
            // Same-value writes re-emit (`@Published` fires on willSet); without de-duplication each
            // redundant `true` write re-ran `start()` — which used to stack a permanent extra
            // activation observer per lap (now also guarded in the service itself).
            .removeDuplicates()
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

    // MARK: - Post-Space-switch cleanup & focus

    /// A Next/Previous Space action only synthesizes the OS shortcut; once the switch lands the
    /// destination's front window is visually front but *not key* (same as the native shortcut), so the
    /// user would have to click before typing. Poll until the active Space actually flips, then focus
    /// the window the user last had front there.
    private func focusFrontWindowAfterSpaceSwitch() {
        let before = SpaceService.currentModel()?.currentSpaceIDs ?? []
        // A newer Space-switch action supersedes any poll still running for the previous one:
        // without the token, rapid consecutive switches stacked N concurrent 16 Hz CGS polls, and a
        // stale chain could focus the wrong Space's window after the user had already moved on.
        spaceSettleGeneration &+= 1
        afterSpaceSettles(before: before, attempt: 0, generation: spaceSettleGeneration)
    }
    private var spaceSettleGeneration = 0

    /// Poll until the active Space flips, then wait for the WindowServer transition (and the
    /// Stage-Manager front-steal ~300ms post-switch) to finish before focusing — acting on the flip
    /// instant gets steamrolled by the rest of the transition. `generation` retires the chain the
    /// moment a newer switch starts one.
    private func afterSpaceSettles(before: Set<CGSSpaceID>, attempt: Int, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.spaceSettleGeneration == generation else { return }
            let now = SpaceService.currentModel()?.currentSpaceIDs ?? []
            if !now.isEmpty, now != before {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self, self.spaceSettleGeneration == generation else { return }
                    self.focusFrontWindowOnCurrentSpace()
                }
                return
            }
            // A ⌃→ with no neighbour Space never flips — bail after ~1.9s rather than poll forever.
            if attempt < 30 { afterSpaceSettles(before: before, attempt: attempt + 1, generation: generation) }
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
        for _ in $(/usr/bin/seq 300); do /bin/kill -0 \(pid) 2>/dev/null || break; /bin/sleep 0.1; done
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
        refreshCommandTabGate()
    }

    /// Install the ⌘-Tab keyboard tap only while the switcher is enabled AND the opt-in is on; otherwise
    /// remove it (native ⌘-Tab restored immediately, no re-login) and tear down any open session. Folded
    /// into `refreshRowSwitchingGate` so every lifecycle point (launch, enable, setting changes, wake)
    /// keeps it in sync; `observeCommandTabToggle` also calls it when only the opt-in flips.
    private func refreshCommandTabGate() {
        if isEnabled && settings.commandTabSwitcher {
            _ = keyboardSwitcherTap.start()
        } else {
            keyboardSwitcherTap.stop()
            keyboardSwitcher.forceCancel()
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

    /// React to the ⌘-Tab opt-in toggle: install/remove the keyboard tap live (no re-login). The
    /// persisted initial value is skipped (`dropFirst`); launch-apply runs via `refreshRowSwitchingGate`
    /// in `start()`.
    private func observeCommandTabToggle() {
        settings.$commandTabSwitcher
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshCommandTabGate() }
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
            lines.append("• App data & settings — preferences, bands, keyboard-language memory, clipboard history, project outputs, first-run state.")
            if anyGestureBackupExists {
                lines.append("  Gesture relocations will be restored FIRST so their backups aren't lost.")
            }
        }
        if selection.contains(.caches) { lines.append("• Caches.") }
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
            // Closing the window mid-flow is "later": progress is already persisted, so tear the
            // wizard down COMPLETELY — window, model, and hosting tree. suspend() alone left the
            // retained NSHostingView's TimelineView breathers (PulseHalo / BreathingGlowBackdrop,
            // 15–20 Hz, ungated) ticking in the ordered-out window for the rest of the process —
            // the docs/postmortem-idle-cpu-spin.md main-thread spin, reachable from the red button.
            // Resume/Replay rebuilds the wizard from scratch (state is persisted in `firstRun`).
            wizardCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    let window = self?.releaseWizardReferences()
                    // Releasing the hosting tree is what actually stops its animation clocks; the
                    // window is already closing, so no close() here (it would re-enter willClose).
                    window?.contentViewController = nil
                }
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

    /// Shared teardown of the wizard's model / observer / window references. Does NOT close or
    /// blank the window — callers own that: from willClose the window is already closing; from
    /// `closeWizard` the exhale animation still needs the content on screen. Removing the
    /// willClose observer here also means a subsequent `close()` cannot re-enter the teardown.
    private func releaseWizardReferences() -> NSWindow? {
        wizardModel?.suspend()
        onWizardTouchFrame = nil
        if let wizardCloseObserver {
            NotificationCenter.default.removeObserver(wizardCloseObserver)
            self.wizardCloseObserver = nil
        }
        let window = wizardWindow
        wizardWindow = nil
        wizardModel = nil
        return window
    }

    private func closeWizard() {
        guard let window = releaseWizardReferences() else { return }
        // Both exits release the SwiftUI tree with the window (`contentViewController = nil`) —
        // the hosting view's TimelineView clocks only stop when the tree is destroyed (see
        // docs/postmortem-idle-cpu-spin.md).
        guard window.isVisible else {
            window.orderOut(nil)
            window.contentViewController = nil
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
            window.contentViewController = nil
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
            self.wizardSeedRetries.forEach { $0.cancel() }
            self.wizardSeedRetries = [0.7, 2.0].map { delay in
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let demo = self.wizardModel?.demo else { return }
                        let missing = windows.filter { demo.thumbnails[$0.id] == nil }
                        guard !missing.isEmpty else { return }
                        self.thumbnails.seed(into: demo, ids: missing.map(\.id))
                        self.thumbnails.prefetch(missing)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return work
            }
        }
        ctx.trackpadClaimed = { [weak self] in self?.trackpadConfig.isClaimed ?? false }
        ctx.spacesAutoRearrangeOn = { [weak self] in self?.spacesRearrange.isAutoRearrangeOn ?? false }
        ctx.applyLanes = { [weak self] choices in self?.applyLanesFromWizard(choices) ?? LanesApplyOutcome() }
        ctx.relocationsPending = { [weak self] in self?.relocationsStillPending ?? false }
        ctx.logOutNow = { [weak self] in self?.sendLogOutKeystroke() }
        // The tour's fixed composition (WizardTourBands): the flame band of every app across the
        // user's bands, the display band of the twelve window actions, plus the Clipboard band when
        // history is on (sample entries while the store is empty).
        ctx.launcherBands = { [weak self] clipboardOn in
            guard let self else { return [] }
            let clipboard: ContextBand? = clipboardOn ? {
                let entries = self.clipboardStore.bandWindow(limit: self.settings.clipboardRecentWindow)
                return ClipboardBandBuilder.build(
                    from: entries.isEmpty ? WizardSampleContent.clipboardEntries() : entries)
            }() : nil
            return WizardTourBands.compose(userBands: self.favoritesStore.favorites.bands,
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
            // `TimelineView` clocks keep ticking on the main run loop after the Hub is closed, pinning the
            // main thread (see `docs/postmortem-idle-cpu-spin.md`). Flipping the shared `previewActivity`
            // flag stops every clock. Registered once (the window is reused), scoped to THIS window.
            let nc = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                hubWindowObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pauseHubPreviews() }
                })
            }
            hubWindowObservers.append(nc.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeHubPreviews() }
            })
            hubWindow = window
        }
        present(hubWindow)
        // Re-arm the previews in case the Hub was previously closed/minimized (the window — and so its
        // paused SwiftUI tree — are reused). Idempotent.
        resumeHubPreviews()
        // Remember which Space the Hub now lives on so the synthetic switcher entry lands in that
        // Space's row. `present` activates + makes the Hub key on the current Space, so the current
        // Space is where it is now visible (the Hub does not join all Spaces).
        hubSpaceID = SpaceService.currentModel()?.currentSpaceIDs.first
    }

    /// Pause the Hub's self-playing gesture previews — called when the Hub leaves the screen (close /
    /// miniaturize). Flips the shared visibility flag false so every `HubGesturePreview` refuses to run its
    /// `TimelineView`, so none keeps ticking on the main run loop after the Hub is gone (SwiftUI's
    /// `.onDisappear` does not fire on an NSWindow close while the window is reused). See
    /// `docs/postmortem-idle-cpu-spin.md`.
    private func pauseHubPreviews() {
        hubContext.previewActivity.isActive = false
    }

    /// Resume the previews when the Hub returns to the screen (reopen / deminiaturize). Idempotent.
    private func resumeHubPreviews() {
        hubContext.previewActivity.isActive = true
    }

    /// Wire the Hub's references and callbacks once. Closures are weak-self so the context never
    /// retains the coordinator beyond its lifetime. Live state is provided as closures so each render
    /// reads the current value (backup existence, re-login warnings, opt-in state).
    private func makeHubContext() -> HubContext {
        let ctx = HubContext(settings: settings,
                             favorites: favoritesStore,
                             clipboard: clipboardStore,
                             permissions: permissions)
        // §11.2 Real demo content for the gesture previews — the SAME providers `makeWizardContext`
        // wires, so the Hub renders the real switcher/launcher seeded with the user's content. No new
        // permission (these read already-available state / reuse granted Screen Recording).
        ctx.realWindowRows = { [weak self] in
            guard let self else { return [] }
            // The user's actual windows across ALL Spaces, grouped into Space-rows in Mission Control order
            // (the same grouping the real switcher uses), so the mini switcher shows true multi-row content.
            // The snapshot already excludes our own PID, so the Hub never appears as a card.
            return SpaceGrouping.group(self.windowService.snapshot()).rows
        }
        // Window Inspector (Switcher page): the on-demand candidate/verdict snapshot. Pull-only —
        // the page refreshes on explicit action, never on a timer (the idle-CPU landmine).
        ctx.inspectWindows = { [weak self] in
            self?.windowService.inspectorSnapshot() ?? []
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
            // Every Hub page re-navigation re-seeds; cancel the previous retries so rapid page
            // switching can't stack a growing backlog of delayed sweeps.
            self.hubSeedRetries.forEach { $0.cancel() }
            self.hubSeedRetries = [0.7, 2.0].map { delay in
                let work = DispatchWorkItem { [weak self, weak model] in
                    MainActor.assumeIsolated {
                        guard let self, let model else { return }
                        let missing = windows.filter { model.thumbnails[$0.id] == nil }
                        guard !missing.isEmpty else { return }
                        self.thumbnails.seed(into: model, ids: missing.map(\.id))
                        self.thumbnails.prefetch(missing)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return work
            }
        }
        ctx.launcherBands = { [weak self] clipboardOn in
            guard let self else { return [] }
            let clipboard: ContextBand? = clipboardOn ? {
                let entries = self.clipboardStore.bandWindow(limit: self.settings.clipboardRecentWindow)
                return ClipboardBandBuilder.build(
                    from: entries.isEmpty ? WizardSampleContent.clipboardEntries() : entries)
            }() : nil
            return WizardTourBands.compose(userBands: self.favoritesStore.favorites.bands,
                                           clipboardBand: clipboard)
        }
        // Clipboard.
        ctx.onClearClipboard = { [weak self] includingPinned in self?.clipboardStore.clear(includingPinned: includingPinned) }
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
        keyboardSwitcher.forceCancel()   // never leave a ⌘-Tab session open behind the hidden overlay
        overlay.hide()
        stopPreviewRefresh()
        switcherOwner = .none
        missionControlOpen = false
    }

    /// Land any coalesced persistence before the process exits (favorites edits are debounced; the
    /// clipboard index is written on a serial queue). Bounded — quit is never held behind a slow write.
    func flushStores() {
        favoritesStore.flushPendingSave()
        clipboardStore.flush(timeout: 1.0)
    }
}
