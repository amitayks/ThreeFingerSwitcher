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
/// value, so we synchronize before each read so a mid-session Stage Manager toggle is reflected —
/// but at most once per `ttl`: the synchronize is a round-trip to `cfprefsd` that deliberately drops
/// the cached domain (so the read is a second trip), and it was being paid twice per commit, once per
/// Dock-preview hover, and up to six more times per off-Space hold-guard tick.
@MainActor
enum StageManager {
    private static let appID = "com.apple.WindowManager" as CFString
    private static var cached: (at: TimeInterval, value: Bool)?
    /// Long enough to collapse a commit's burst of reads into one; short enough that a mid-session
    /// toggle is still picked up within a couple of seconds.
    private static let ttl: TimeInterval = 2.0

    /// True when Stage Manager is currently enabled (`GloballyEnabled == 1`).
    static var isEnabled: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < ttl { return cached.value }
        CFPreferencesAppSynchronize(appID)
        let value = (CFPreferencesCopyAppValue("GloballyEnabled" as CFString, appID) as? NSNumber)?.boolValue ?? false
        cached = (now, value)
        return value
    }
}
