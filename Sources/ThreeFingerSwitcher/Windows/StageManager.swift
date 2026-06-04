import Foundation

/// Detects whether macOS Stage Manager is enabled for the current user.
///
/// Stage Manager (the `WindowManager` daemon) places multiple windows of one app on the center
/// stage together. While in that mode, asserting the per-application AX focus singletons
/// (`kAXMainAttribute` on a window, plus the app's `kAXFocusedWindowAttribute`) toward one of the
/// co-staged windows makes WindowManager's stage-front arbiter oscillate between them — a
/// self-sustaining loop that even survives our own process quitting (verified by log capture: the
/// WindowServer kept reordering at ~12/sec for >10s with no ThreeFingerSwitcher process alive).
/// `WindowService` consults this to switch to a gentler, window-specific raise (a lone
/// `kAXRaiseAction` + `activate()`, with NO per-app singleton writes) when Stage Manager is on.
///
/// There is no public API for this; reading the `com.apple.WindowManager` preference domain is the
/// community-standard method (used by Keyboard Maestro, Alfred, MDM scripts). `cfprefsd` caches the
/// value, so we synchronize before each read so a mid-session Stage Manager toggle is reflected.
enum StageManager {
    private static let appID = "com.apple.WindowManager" as CFString

    /// True when Stage Manager is currently enabled (`GloballyEnabled == 1`).
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(appID)
        guard let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, appID) else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
