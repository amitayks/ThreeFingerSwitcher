import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Captures per-window thumbnails via ScreenCaptureKit with an LRU-ish cache. Per design
/// D7 we never block gesture start: callers render an icon placeholder immediately and call
/// `prefetch` to fill thumbnails asynchronously. Degrades silently (returns nothing) when
/// Screen Recording permission is missing.
@MainActor
final class ThumbnailService {
    /// Called on the main actor when a thumbnail for a window id becomes available.
    var onThumbnail: ((CGWindowID, NSImage) -> Void)?

    private var cache: [CGWindowID: NSImage] = [:]
    private var cacheOrder: [CGWindowID] = []
    private let cacheLimit = 64
    private let thumbnailMaxSize = CGSize(width: 320, height: 200)

    private var inFlight: Set<CGWindowID> = []

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Apply any cached thumbnails to the model immediately, so repeat showings render the
    /// preview instantly (instead of icon-only) while a fresh capture is in flight.
    func seed(into model: SwitcherModel, ids: [CGWindowID]) {
        for id in ids {
            if let image = cache[id] { model.setThumbnail(image, for: id) }
        }
    }

    /// (Re)capture thumbnails for the given window ids to keep them live. Cached ids are
    /// refreshed too (not skipped) — the cached image, seeded via `seed`, bridges the async
    /// capture. The `inFlight` guard prevents duplicate concurrent captures for the same id.
    ///
    /// Off-Space windows are expected here: SCShareableContent uses onScreenWindowsOnly:false and
    /// matches by windowID, so they capture fine; a window never composited on a visited Space may
    /// briefly fall back to the icon placeholder, which is acceptable.
    func prefetch(_ ids: [CGWindowID]) {
        guard CGPreflightScreenCaptureAccess() else { return }
        for id in ids where !inFlight.contains(id) {
            inFlight.insert(id)
            Task { await self.capture(id) }
        }
    }

    func clear() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private func capture(_ id: CGWindowID) async {
        defer { inFlight.remove(id) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { return }

            let config = SCStreamConfiguration()
            let scale = min(
                thumbnailMaxSize.width / max(scWindow.frame.width, 1),
                thumbnailMaxSize.height / max(scWindow.frame.height, 1),
                1
            )
            config.width = max(Int(scWindow.frame.width * scale), 1)
            config.height = max(Int(scWindow.frame.height * scale), 1)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
            store(id, image)
            onThumbnail?(id, image)
        } catch {
            // Permission denied, window gone, or capture failed: leave the placeholder in place.
        }
    }

    private func store(_ id: CGWindowID, _ image: NSImage) {
        if cache[id] == nil { cacheOrder.append(id) }
        cache[id] = image
        while cacheOrder.count > cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
