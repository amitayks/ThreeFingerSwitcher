import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar agent: no Dock icon, no main window

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

    func applicationWillResignActive(_ notification: Notification) {
        // Never leave the overlay ordered-in when we lose active status.
        coordinator?.hideOverlay()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.restoreSpacesRearrangeOnQuit()
        coordinator?.offerRestoreOnQuit()
        return .terminateNow
    }
}
