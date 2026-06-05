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
    private var cancellables: Set<AnyCancellable> = []

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private(set) var isEnabled = false
    var isTrackpadAvailable: Bool { touchEngine.isAvailable }

    var onStateChange: (() -> Void)?

    init() {
        recognizer.delegate = self
        touchEngine.onFrame = { [weak self] frame in self?.recognizer.feed(frame) }
        thumbnails.onThumbnail = { [weak self] id, image in self?.overlay.model.setThumbnail(image, for: id) }
        observeSleepWake()
        observeSpacesRearrangeToggle()
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
        if settings.enabled { enable() }
        maybePromptNativeGestureSetup()
        applySpacesRearrangeOnLaunchIfManaged()
        maybePromptSpacesRearrange()
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
        onStateChange?()
    }

    func disable() {
        guard isEnabled else { return }
        recognizer.reset()
        touchEngine.stop()
        mru.stop()
        overlay.hide()
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
        overlay.show(rows: grid.rows, labels: grid.labels, startRow: grid.startRow, column: 0)
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
        windowService.raise(window)
    }

    func gestureDidCancel() {
        overlay.hide()
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

    // MARK: - Windows

    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(settings: settings))
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
                onSetupNativeGesture: { [weak self] in self?.promptNativeGestureSetup() },
                onKeepSpacesFixed: { [weak self] in self?.promptSpacesRearrangeSetup() },
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
        window.center()
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
