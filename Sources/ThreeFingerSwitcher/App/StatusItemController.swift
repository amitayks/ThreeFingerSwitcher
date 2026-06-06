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
            // Brand mark (template PNG set, @1x/@2x/@3x, loaded by name from the bundle).
            // Falls back to the stock symbol for dev builds assembled without the brand assets.
            let mark = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Window Switcher")
            mark?.isTemplate = true
            mark?.accessibilityDescription = "Window Switcher"
            button.image = mark
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

        // Built as groups; empty groups are dropped and the rest are joined by dividers so there
        // are never leading, trailing, or doubled separators regardless of which items are present.
        var groups: [[NSMenuItem]] = []

        if !coordinator.isTrackpadAvailable {
            groups.append([disabledItem("No trackpad detected — switcher unavailable")])
        }

        // ── State ── the switcher enable, the launcher enable/status, and Open at Login together.
        var state: [NSMenuItem] = []

        let toggle = NSMenuItem(title: coordinator.isEnabled ? "Switcher Enabled" : "Switcher Disabled",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = coordinator.isEnabled ? .on : .off
        if !coordinator.isTrackpadAvailable { toggle.isEnabled = false }
        state.append(toggle)

        if coordinator.settings.enableLauncher {
            // A non-clickable status line that mirrors the switcher's checkmark when effective;
            // enabling/disabling the launcher is a consent-gated flow handled below / in Settings.
            let effective = coordinator.isLauncherEffective
            let status = disabledItem(effective ? "Launcher Enabled" : "Launcher: log out & back in to finish")
            status.state = effective ? .on : .off
            state.append(status)
        } else {
            state.append(item("Enable Four-Finger Launcher…", #selector(setupLauncher)))
        }

        let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = coordinator.isOpenAtLogin ? .on : .off
        state.append(loginItem)

        groups.append(state)

        // ── Switcher setup ── one-time free / restore of the native horizontal gesture (usually
        // absent once set up).
        var switcherSetup: [NSMenuItem] = []
        if coordinator.trackpadConfig.isClaimed {
            switcherSetup.append(item("⚠ Free three-finger horizontal swipe…", #selector(setupNativeGesture)))
        } else if coordinator.trackpadConfig.hasBackup {
            switcherSetup.append(item("Restore native gesture setting…", #selector(restoreNativeGesture)))
        }
        groups.append(switcherSetup)

        // ── Launcher actions ── only meaningful while the launcher is on.
        var launcherActions: [NSMenuItem] = []
        if coordinator.settings.enableLauncher {
            launcherActions.append(item("Favorites…", #selector(showFavorites)))
            launcherActions.append(quickAddMenuItem())
            if coordinator.fourFingerGesture.hasBackup {
                launcherActions.append(item("Disable launcher & restore four-finger swipes…", #selector(restoreLauncher)))
            }
        }
        groups.append(launcherActions)

        // ── App ── Settings (which now hosts Setup & Permissions and the Mission Control restore)
        // plus the diagnostic tools, shown only when opted in via the Settings toggle.
        var app: [NSMenuItem] = [item("Settings…", #selector(showSettings))]
        if coordinator.settings.showDiagnostics {
            app.append(item("Write Diagnostics → /tmp", #selector(writeDiagnostics)))
            app.append(item("Copy Focus Log", #selector(copyFocusLog)))
        }
        groups.append(app)

        groups.append([item("Quit", #selector(quit))])

        for group in groups where !group.isEmpty {
            if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
            for menuItem in group { menu.addItem(menuItem) }
        }
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

    /// "Add Front App to Band ▸ <band>" — appends the frontmost app to the chosen band (10.2).
    private func quickAddMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Add Front App to Band", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let bands = coordinator.favoriteBands
        if bands.isEmpty {
            submenu.addItem(disabledItem("No bands — add some in Favorites…"))
        } else {
            for band in bands {
                let bandItem = NSMenuItem(title: band.name, action: #selector(addFrontApp(_:)), keyEquivalent: "")
                bandItem.target = self
                bandItem.representedObject = band.id
                submenu.addItem(bandItem)
            }
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func toggleEnabled() { coordinator.toggleEnabled() }
    @objc private func setupNativeGesture() { coordinator.promptNativeGestureSetup() }
    @objc private func restoreNativeGesture() { coordinator.restoreNativeGestureSetting() }
    @objc private func setupLauncher() { coordinator.promptLauncherSetup() }
    @objc private func restoreLauncher() { coordinator.restoreLauncherGestureSetting() }
    @objc private func showFavorites() { coordinator.showFavoritesEditor() }
    @objc private func addFrontApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.addFrontAppToBand(id)
    }
    @objc private func toggleOpenAtLogin() { coordinator.toggleOpenAtLogin() }
    @objc private func showSettings() { coordinator.showSettings() }
    @objc private func writeDiagnostics() { coordinator.writeDiagnostics() }
    @objc private func copyFocusLog() { coordinator.copyFocusLog() }
    @objc private func quit() { NSApp.terminate(nil) }
}
