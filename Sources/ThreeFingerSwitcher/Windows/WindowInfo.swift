import AppKit
import ApplicationServices
import CoreGraphics

/// A switchable window, captured in a gesture-start snapshot.
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let appIcon: NSImage?
    let frame: CGRect
    /// AX element retained for raising. Optional: off-Space windows may not have one until it
    /// is re-acquired (via remote-token brute force) at commit. Not Sendable; main-actor only.
    let axElement: AXUIElement?
    /// Whether this window is on the currently active Space.
    let isOnCurrentSpace: Bool
    /// The Space this window was enumerated on (nil in the legacy current-Space path).
    let spaceID: CGSSpaceID?

    var displayTitle: String {
        title.isEmpty ? appName : title
    }
}
