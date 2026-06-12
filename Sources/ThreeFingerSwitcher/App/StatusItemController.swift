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
        coordinator.onMenuBarPulse = { [weak self] in self?.pulseMark() }
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    /// The First Touch wizard's menu-bar moment: breathe the mark a few times so the eye finds
    /// where the app lives — fired on the wizard's overture and curtain. Best-effort and idempotent
    /// (alpha always lands back at 1).
    private func pulseMark(times: Int = 3) {
        guard let button = statusItem.button else { return }
        func breathe(_ remaining: Int) {
            guard remaining > 0 else {
                button.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.30
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = 0.25
            }, completionHandler: {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.36
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    button.animator().alphaValue = 1
                }, completionHandler: {
                    breathe(remaining - 1)
                })
            })
        }
        breathe(times)
    }

    /// The configuration Hub is the single home for every setting (configuration-hub), so the status
    /// menu is trimmed to a minimal set of quick actions: open the Hub, toggle the switcher, add the
    /// front app to a band, and quit. Everything else (tunables, Open at Login, launcher status, setup
    /// & permissions, gesture restores, diagnostics) lives in the Hub. Groups are joined by dividers,
    /// and empty groups are dropped so there are never doubled or dangling separators.
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        var groups: [[NSMenuItem]] = []

        if !coordinator.isTrackpadAvailable {
            groups.append([disabledItem("No trackpad detected — switcher unavailable")])
        }

        // Open the Hub — all configuration lives there.
        groups.append([item("Open Hub…", #selector(openHub))])

        // Quick switcher enable/disable + quick-add the front app to a band (without opening the Hub).
        let toggle = NSMenuItem(title: coordinator.isEnabled ? "Switcher Enabled" : "Switcher Disabled",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = coordinator.isEnabled ? .on : .off
        if !coordinator.isTrackpadAvailable { toggle.isEnabled = false }
        groups.append([toggle, quickAddMenuItem()])

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

    /// "Add Front App to Band ▸ <band>" — appends the frontmost app to the chosen band without opening
    /// the Hub. The band's contents are then editable on the Hub's Bands page.
    private func quickAddMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Add Front App to Band", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let bands = coordinator.favoriteBands
        if bands.isEmpty {
            submenu.addItem(disabledItem("No bands — add some in the Hub…"))
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

    @objc private func openHub() { coordinator.showHub() }
    @objc private func toggleEnabled() { coordinator.toggleEnabled() }
    @objc private func addFrontApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator.addFrontAppToBand(id)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
