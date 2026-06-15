import AppKit
import CoreGraphics

/// One window in the Dock-preview row. Value type keyed by `CGWindowID` so SwiftUI's `ForEach` keeps a
/// **stable identity across re-lists** (re-reading the app's windows doesn't restrobe the row). Images
/// live in the model's side dictionaries (an `NSImage` is a reference type and doesn't belong in an
/// `Equatable` value).
struct DockPreviewWindow: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let isMinimized: Bool
    /// The window's width/height ratio, so each tab is sized to its OWN proportions (a portrait window
    /// gets a narrow tab, a wide one a wide tab) rather than being letterboxed/cropped into a fixed box.
    let aspect: CGFloat
}

/// The observable state behind the Dock-preview popup: the app's current-Space windows, which card is
/// being peeked, per-window icon/thumbnail images, and a bounded error. Pure state — no capture, no AX;
/// the controller fills it. `@MainActor` because it drives SwiftUI.
@MainActor
final class DockPreviewModel: ObservableObject {
    /// The app's current-Space windows (normal + minimized), in enumeration order.
    @Published private(set) var windows: [DockPreviewWindow] = []
    /// The owning app's display name (popup header / accessibility).
    @Published private(set) var appName: String = ""
    /// The card currently under the cursor (peeked), or nil when none is hovered.
    @Published var highlightedID: CGWindowID?
    /// App icons keyed by window id (placeholder while a thumbnail is in flight).
    @Published private(set) var icons: [CGWindowID: NSImage] = [:]
    /// Live/cached thumbnails keyed by window id.
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    /// A bounded, non-blocking commit error (clean headline + opt-in details), or nil.
    @Published var error: DockPreviewError?

    /// True when there is at least one window to show — the popup is suppressed entirely otherwise
    /// (spec: "Apps with no current-Space windows show nothing").
    var hasContent: Bool { !windows.isEmpty }

    /// Replace the row for a (possibly new) app. Preserves the peeked card if that window still exists,
    /// and drops icons/thumbnails for windows that are gone so the maps stay bounded to the live row.
    func setWindows(_ windows: [DockPreviewWindow], appName: String, icons: [CGWindowID: NSImage]) {
        self.windows = windows
        self.appName = appName
        self.icons = icons
        let live = Set(windows.map(\.id))
        thumbnails = thumbnails.filter { live.contains($0.key) }
        if let h = highlightedID, !live.contains(h) { highlightedID = nil }
        error = nil
    }

    /// Apply a captured thumbnail for a window (no-op if the window left the row).
    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        guard windows.contains(where: { $0.id == id }) else { return }
        thumbnails[id] = image
    }

    /// Clear everything (popup dismissed).
    func clear() {
        windows = []
        appName = ""
        highlightedID = nil
        icons = [:]
        thumbnails = [:]
        error = nil
    }

    func setError(_ error: DockPreviewError) { self.error = error }
    func dismissError() { error = nil }
}
