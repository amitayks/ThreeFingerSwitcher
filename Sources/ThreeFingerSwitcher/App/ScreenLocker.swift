import CoreGraphics
import Foundation

/// Lock the screen immediately — Keep Awake's guard exit action. Primary path is the private
/// `login.framework` `SACLockScreenImmediate` (resolved crash-safely via dlsym, the
/// `DisplayBrightness` pattern); if it can't be resolved, fall back to posting the public ⌃⌘Q
/// lock-screen keystroke as a CGEvent, which rides the already-granted Accessibility permission.
/// Either way: no new permission, never a crash.
enum ScreenLocker {
    private typealias LockFn = @convention(c) () -> Int32

    private static let lockFn: LockFn? =
        dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
            .flatMap { dlsym($0, "SACLockScreenImmediate") }
            .map { unsafeBitCast($0, to: LockFn.self) }

    static func lock() {
        if let lockFn {
            _ = lockFn()
            return
        }
        // Fallback: synthesize ⌃⌘Q (the system Lock Screen shortcut). Keycode 12 = ANSI 'Q'.
        let flags: CGEventFlags = [.maskControl, .maskCommand]
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: keyDown)
            else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}
