import AppKit

/// Entry point for the ThreeFingerSwitcher menu-bar agent.
///
/// LSUIElement menu-bar agent bootstrap. The Info.plist (LSUIElement=true) and
/// setActivationPolicy(.accessory) keep this out of the Dock with no main window.
/// Top-level executable code runs on the main thread, so asserting MainActor isolation
/// is valid and lets us construct the @MainActor delegate.
///
/// This is the single public symbol of the ThreeFingerSwitcherCore library; the thin
/// `ThreeFingerSwitcher` executable target calls it from its own `main.swift`.
public func runThreeFingerSwitcher() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
