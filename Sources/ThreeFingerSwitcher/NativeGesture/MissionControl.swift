import Foundation
import CoreGraphics

/// Triggers Mission Control / App Exposé programmatically via the private `CoreDockSendNotification`.
///
/// Needed when the app owns the three-finger vertical gesture: to free that gesture we disable the
/// OS assignment (it becomes a plain scroll), which would otherwise kill the native idle
/// three-finger-up → Mission Control. So we synthesize it ourselves on a fresh vertical swipe.
///
/// Crash-safe: the symbol lives behind Carbon, and `import Carbon` does NOT force-load its dylib,
/// so `RTLD_DEFAULT` can't see it. We `dlopen` Carbon explicitly and resolve the symbol into an
/// optional function pointer (mirroring `CGSPrivate`). If it can't be resolved, triggers are
/// no-ops — never a crash. Validated live: opens Mission Control then App Exposé.
@MainActor
enum MissionControl {
    private typealias FnCoreDockSendNotification = @convention(c) (CFString, Int32) -> Void

    private static let send: FnCoreDockSendNotification? = {
        let candidates = [
            "/System/Library/Frameworks/Carbon.framework/Carbon",
            "/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/HIToolbox",
        ]
        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW) else { continue }
            if let sym = dlsym(handle, "CoreDockSendNotification") {
                return unsafeBitCast(sym, to: FnCoreDockSendNotification.self)
            }
        }
        // Fallback: already-loaded image (RTLD_DEFAULT).
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") {
            return unsafeBitCast(sym, to: FnCoreDockSendNotification.self)
        }
        return nil
    }()

    /// Whether the private trigger resolved (else triggers are no-ops).
    static var isAvailable: Bool { send != nil }

    /// Open Mission Control (the all-windows / all-Spaces overview) — native three-finger-up action.
    static func showMissionControl() { send?("com.apple.expose.awake" as CFString, 0) }

    /// Open App Exposé (the frontmost app's windows) — native three-finger-down action.
    static func showAppExpose() { send?("com.apple.expose.front.awake" as CFString, 0) }

    /// Reveal the desktop (move all windows aside).
    static func showDesktop() { send?("com.apple.showdesktop.awake" as CFString, 0) }

    /// Convenience for the recognizer's idle-vertical intent: up → Mission Control, down → App Exposé.
    static func trigger(up: Bool) { up ? showMissionControl() : showAppExpose() }

    /// Close Mission Control by synthesizing Escape. Unlike re-sending the `…expose.awake` toggle,
    /// Escape can only *close* the overview — if it's already closed (stale caller state) this is a
    /// harmless stray Escape, never a spurious re-open.
    static func dismiss() {
        let src = CGEventSource(stateID: .hidSystemState)
        let escape: CGKeyCode = 0x35
        CGEvent(keyboardEventSource: src, virtualKey: escape, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: escape, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
