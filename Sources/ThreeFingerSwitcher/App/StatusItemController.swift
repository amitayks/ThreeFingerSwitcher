import AppKit

/// The menu-bar status item and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Switcher")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        coordinator.onStateChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if !coordinator.isTrackpadAvailable {
            menu.addItem(disabledItem("No trackpad detected — switcher unavailable"))
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: coordinator.isEnabled ? "Switcher Enabled" : "Switcher Disabled",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = coordinator.isEnabled ? .on : .off
        if !coordinator.isTrackpadAvailable { toggle.isEnabled = false }
        menu.addItem(toggle)

        menu.addItem(.separator())

        if coordinator.trackpadConfig.isClaimed {
            menu.addItem(item("⚠ Free three-finger horizontal swipe…", #selector(setupNativeGesture)))
        } else if coordinator.trackpadConfig.hasBackup {
            menu.addItem(item("Restore native gesture setting…", #selector(restoreNativeGesture)))
        }

        if coordinator.verticalGesture.hasBackup {
            menu.addItem(item("Restore three-finger up/down (Mission Control)…", #selector(restoreVerticalGesture)))
        }

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = coordinator.isOpenAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(item("Setup & Permissions…", #selector(showOnboarding)))
        menu.addItem(item("Write Diagnostics → /tmp", #selector(writeDiagnostics)))
        menu.addItem(item("Copy Focus Log", #selector(copyFocusLog)))

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() { coordinator.toggleEnabled() }
    @objc private func setupNativeGesture() { coordinator.promptNativeGestureSetup() }
    @objc private func restoreNativeGesture() { coordinator.restoreNativeGestureSetting() }
    @objc private func restoreVerticalGesture() { coordinator.restoreVerticalGestureSetting() }
    @objc private func toggleOpenAtLogin() { coordinator.toggleOpenAtLogin() }
    @objc private func showSettings() { coordinator.showSettings() }
    @objc private func showOnboarding() { coordinator.showOnboarding() }
    @objc private func writeDiagnostics() { coordinator.writeDiagnostics() }
    @objc private func copyFocusLog() { coordinator.copyFocusLog() }
    @objc private func quit() { NSApp.terminate(nil) }
}
