import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItem: StatusItemController?
    /// Process-lifetime App Nap opt-out (see `applicationDidFinishLaunching`). Held, never ended.
    private var appNapActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar agent: no Dock icon, no main window
        installMainMenu()

        // Bound every Accessibility round-trip this process makes. AX calls are serviced by the
        // TARGET app's main thread with a 6-SECOND default timeout — and the switcher's snapshot
        // makes several per window, synchronously, inline in the gesture. One busy/hung peer app
        // otherwise stalls the gesture for seconds ("the trigger needs to wake up"). Setting the
        // timeout on the system-wide element makes it the process-global default: a peer that
        // can't answer in 0.5 s is dropped from that snapshot and picked up on the next one.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        // Opt out of App Nap for the process's lifetime. An LSUIElement accessory that is never
        // frontmost is the textbook nap target: macOS demotes its threads and coalesces its timers
        // exactly when other apps are busy — which starved the touch-frame consumer and both event
        // taps ("slow after a break", "can't compete when the Mac is loaded"). The variant that
        // still allows idle SYSTEM sleep is used, so the Mac's own sleep is unaffected.
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Realtime trackpad gesture recognition"
        )

        let coordinator = AppCoordinator()
        self.coordinator = coordinator

        if CommandLine.arguments.contains("--diag") {
            // Give the window server a moment, dump the enumeration funnel, and exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                coordinator.runDiagnostics()
                exit(0)
            }
            return
        }

        self.statusItem = StatusItemController(coordinator: coordinator)
        coordinator.start()
    }

    /// Install a minimal application main menu (App / Edit / Window).
    ///
    /// An `.accessory` agent installs no menu by default, so the standard editing
    /// key equivalents — ⌘X/⌘C/⌘V/⌘A and ⌘Z/⇧⌘Z — are never dispatched to the first
    /// responder. The visible symptom: in every Hub text field (script body, Name,
    /// URL, AI prompt, …) paste silently no-ops while typing and right-click → Paste
    /// still work (the context menu is built by the text view, not the main menu).
    /// The menu need not be *displayed* — an accessory app shows no menu bar — but
    /// `NSApp.mainMenu` still services key equivalents, which is all we need here.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (first submenu is treated as the application menu): Quit routes
        // through `applicationShouldTerminate` so the on-quit restore logic still runs.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit ThreeFingerSwitcher",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — the reason this whole menu exists (see method doc). Items target
        // `nil` so each selector walks the responder chain to the focused text view.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu (Minimize / Close) for the Hub window's standard shortcuts.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillResignActive(_ notification: Notification) {
        // Never leave the overlay ordered-in when we lose active status.
        coordinator?.hideOverlay()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Force-stop Keep Awake FIRST (synchronous) so a dimmed-to-black screen is restored and the
        // sleep/lock assertion released before the process exits. Idempotent — a no-op when inactive.
        coordinator?.stopKeepAwake()
        coordinator?.flushStores()
        coordinator?.restoreSpacesRearrangeOnQuit()
        // NOTE: the vertical-gesture relocation is deliberately NOT restored on quit. It needs a
        // re-login to take effect, and logout quits the app — restoring here would undo the change
        // on the very logout that applies it, so the feature could never engage. The relocation
        // persists while the opt-in is on and is reverted only when the user disables the opt-in
        // or picks Restore from the menu (the same model as the horizontal gesture).
        coordinator?.offerRestoreOnQuit()
        return .terminateNow
    }
}
