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

    /// When set (env var `TFS_THUMB_LOG`), each capture logs its ScreenCaptureKit frame next to the
    /// window's logical frame so the set-aside/off-screen "degraded" signal can be confirmed and the
    /// thresholds in `isDegradedCapture` tuned against real data (see the change's task 1.2 / 1.3).
    private let frameLoggingEnabled = ProcessInfo.processInfo.environment["TFS_THUMB_LOG"] != nil

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Apply any cached thumbnails to the model immediately, so repeat showings render the
    /// preview instantly (instead of icon-only) while a fresh capture is in flight.
    func seed(into model: SwitcherModel, ids: [CGWindowID]) {
        for id in ids {
            if let image = cache[id] { model.setThumbnail(image, for: id) }
        }
    }

    /// (Re)capture thumbnails for the given windows to keep them live, CACHE-FIRST: a window that is
    /// not cleanly presented right now is NOT live-captured, so its good cached thumbnail (applied via
    /// `seed`) is preserved instead of being overwritten by a degraded image. The `inFlight` guard
    /// prevents duplicate concurrent captures for the same id.
    ///
    /// A window parked off every display (Stage Manager set-aside) would only capture as the tilted
    /// strip proxy, so it is skipped here and served from cache via `seed` (the caller applies `seed`
    /// before this, keeping the prior cached thumbnail visible). Off-Space-but-on-screen windows still
    /// capture, preserving live off-Space previews. Minimized windows never reach this point —
    /// `snapshot()`'s `isSwitchable` excludes them.
    func prefetch(_ windows: [WindowInfo]) {
        guard CGPreflightScreenCaptureAccess() else { return }
        let displayUnion = Self.displayUnion()
        for w in windows where !inFlight.contains(w.id) {
            // Skip windows whose live capture would be a degraded proxy, serving the cached/icon
            // instead: (a) parked off every display (set aside on a non-current Space → negative-x),
            // or (b) a Stage-Manager strip thumbnail on the current Space (CGWindowList reports the
            // small scaled strip rect while AX reports the real size). `seed` already covers them.
            if Self.isOffAllDisplays(w.frame, displayUnion: displayUnion) { continue }
            if Self.isStripProxy(displayedFrame: w.frame, realFrame: w.realFrame) { continue }
            inFlight.insert(w.id)
            // Pass the real (AX) frame as the logical frame so capture()'s degraded check compares the
            // SCK frame against the TRUE size (a backstop if a strip proxy slips past the checks above).
            let logical = w.realFrame.width > 1 ? w.realFrame : w.frame
            Task { await self.capture(w.id, logicalFrame: logical, displayUnion: displayUnion) }
        }
    }

    /// Union of all active displays in the global (top-left origin) coordinate space that both
    /// CGWindowList bounds and ScreenCaptureKit frames use. `.null` when unavailable, which makes the
    /// degraded-frame checks no-op (never suppress a capture without positive off-screen evidence).
    private static func displayUnion() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .null }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .null }
        return ids.reduce(.null) { $0.union(CGDisplayBounds($1)) }
    }

    /// True when `frame` sits entirely off the left or right of every display — the signal that a
    /// window is parked off-screen (Stage Manager set-aside / hidden) rather than cleanly visible.
    /// Tests the X axis only, so it is robust to top-left vs bottom-left coordinate flips. A `.null`
    /// or empty `displayUnion` returns false (no evidence → don't suppress). Pure, for unit testing.
    static func isOffAllDisplays(_ frame: CGRect, displayUnion: CGRect) -> Bool {
        guard !displayUnion.isNull, displayUnion.width > 0 else { return false }
        return frame.maxX <= displayUnion.minX + 1 || frame.minX >= displayUnion.maxX - 1
    }

    /// Authoritative degraded-capture test run after ScreenCaptureKit reports the window's actual
    /// frame: degraded when the window is parked off every display (set aside) OR the captured frame
    /// is a small fraction of the window's logical frame in BOTH dimensions (a scaled strip proxy).
    /// Thresholds are provisional pending the `TFS_THUMB_LOG` data (task 1.2/1.3). Pure, for testing.
    static func isDegradedCapture(scFrame: CGRect, logicalFrame: CGRect, displayUnion: CGRect) -> Bool {
        if isOffAllDisplays(scFrame, displayUnion: displayUnion) { return true }
        if logicalFrame.width > 1, logicalFrame.height > 1,
           scFrame.width / logicalFrame.width < 0.5,
           scFrame.height / logicalFrame.height < 0.5 {
            return true
        }
        return false
    }

    /// True when the window's displayed (CGWindowList) frame is a scaled proxy of its real
    /// (Accessibility) frame — a Stage-Manager strip thumbnail on the CURRENT Space reports a frame
    /// far smaller than the real window in BOTH dimensions (CGWindowList gives the scaled strip rect
    /// while AX gives the true size), positioned on-screen at positive coordinates so the off-screen
    /// test does not catch it. Such a window only captures as the small tilted bitmap, so we skip it
    /// and serve the cached image / icon. A `.zero`/degenerate realFrame returns false (no real-size
    /// info → don't suppress). Pure, for unit testing.
    static func isStripProxy(displayedFrame: CGRect, realFrame: CGRect) -> Bool {
        guard realFrame.width > 1, realFrame.height > 1 else { return false }
        return displayedFrame.width / realFrame.width < 0.5
            && displayedFrame.height / realFrame.height < 0.5
    }

    func clear() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    /// Diagnostic: dump every layer-0 window ScreenCaptureKit can see, with its frame and the
    /// `isOnScreen` flag, so a Stage-Manager *set-aside* window (the tilted strip proxy that captures
    /// badly) can be told apart from a cleanly-presented one. Appended to "Write Diagnostics" — no env
    /// var, no special launch — so the real P1 degraded-capture signal is observable from one click.
    func diagnosticFrames() async -> String {
        var out = ["=== ScreenCaptureKit window frames (layer-0, regular apps) ==="]
        guard CGPreflightScreenCaptureAccess() else {
            out.append("Screen Recording not granted — no SCK frames available")
            return out.joined(separator: "\n")
        }
        let union = Self.displayUnion()
        out.append("displayUnion = \(Int(union.minX)),\(Int(union.minY)) \(Int(union.width))x\(Int(union.height))")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            for w in content.windows.sorted(by: { $0.windowID < $1.windowID }) {
                guard w.windowLayer == 0, let app = w.owningApplication,
                      app.applicationName != "ThreeFingerSwitcher" else { continue }
                let f = w.frame
                let off = Self.isOffAllDisplays(f, displayUnion: union)
                out.append("  wid \(w.windowID) onScreen=\(w.isOnScreen ? 1 : 0) "
                    + "sc=\(Int(f.width))x\(Int(f.height))@\(Int(f.origin.x)),\(Int(f.origin.y)) "
                    + "offAllDisplays=\(off ? 1 : 0)  [\(app.applicationName)] '\(w.title ?? "")'")
            }
        } catch {
            out.append("SCShareableContent error: \(error)")
        }
        return out.joined(separator: "\n")
    }

    private func capture(_ id: CGWindowID, logicalFrame: CGRect, displayUnion: CGRect) async {
        defer { inFlight.remove(id) }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { return }

            if frameLoggingEnabled {
                NSLog("[TFS-thumb] capture id=\(id) sc=\(scWindow.frame) logical=\(logicalFrame)")
            }
            // Don't overwrite a good cached thumbnail with a degraded capture — a Stage-Manager
            // set-aside strip proxy or an off-screen frame. Keep the cached image or icon instead.
            if Self.isDegradedCapture(scFrame: scWindow.frame, logicalFrame: logicalFrame, displayUnion: displayUnion) {
                return
            }

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
