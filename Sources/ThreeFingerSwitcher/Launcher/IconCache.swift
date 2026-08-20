import AppKit

/// Process-wide memo for `NSWorkspace.shared.icon(forFile:)`.
///
/// The launcher grid and the Hub's band editor render an app/file icon per cell — and SwiftUI
/// re-evaluates those bodies on every model change (every gesture step, every slider tick). Each
/// `icon(forFile:)` call is an IconServices round-trip that returns a FRESH `NSImage` instance, so
/// besides the IPC, SwiftUI could never identity-match the image against the previous frame and
/// re-rasterized every cell per step. One stable instance per path fixes both.
///
/// Bounded: the memo is cleared wholesale past `capacity` (favorites are a few dozen items; a full
/// clear is simpler and just as fast as LRU bookkeeping here). Stale-icon risk is accepted — an app
/// updating its icon mid-session shows the old one until relaunch, which is what the Dock does too.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]
    private static let capacity = 256

    static func icon(forFile path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        if icons.count >= capacity { icons.removeAll(keepingCapacity: true) }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}
