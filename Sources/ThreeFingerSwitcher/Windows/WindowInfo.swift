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
    /// The window's displayed bounds from CGWindowList. NOTE: under Stage Manager a set-aside strip
    /// thumbnail reports the small SCALED strip rect here, not the real window size.
    let frame: CGRect
    /// The window's real (Accessibility) frame. AX reports the true window size even when the window
    /// is rendered as a scaled Stage-Manager strip thumbnail — so `frame` much smaller than
    /// `realFrame` marks a strip proxy whose live capture would be the tilted bitmap. `.zero` means
    /// "no real-size info" (legacy path / no element), which the thumbnail checks treat as a no-op.
    var realFrame: CGRect = .zero
    /// AX element retained for raising. Optional: off-Space windows may not have one until it
    /// is re-acquired (via remote-token brute force) at commit. Not Sendable; main-actor only.
    let axElement: AXUIElement?
    /// Whether this window is on the currently active Space.
    let isOnCurrentSpace: Bool
    /// The Space this window was enumerated on (nil in the legacy current-Space path).
    let spaceID: CGSSpaceID?
    /// The Space's order index in Mission Control (display order); lower = earlier/leftmost.
    /// 0 in the legacy current-Space path. Drives stable Space-row ordering in the overlay.
    let spaceIndex: Int

    var displayTitle: String {
        title.isEmpty ? appName : title
    }
}
