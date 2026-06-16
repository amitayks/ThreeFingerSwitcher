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
    /// Pixel budget for a captured thumbnail. Captures run at the window's NATIVE (Retina) resolution
    /// capped to this, so a thumbnail downscaled into a large grid card stays sharp like Mission Control
    /// rather than upscaling a small bitmap. (Was 320×200 — too soft for the window grid's larger cards.)
    private let thumbnailMaxSize = CGSize(width: 1100, height: 700)

    private var inFlight: Set<CGWindowID> = []

    /// Per-gesture "live session" cache: while a switcher gesture is held, the visible row's window can
    /// be re-captured every frame via `liveCapture` WITHOUT re-enumerating SCShareableContent each time
    /// (the enumeration in `capture` is the expensive part). `prepareLiveSession` snapshots the windows
    /// and display union once at gesture start; `refreshLiveSession` re-snapshots when the visible row
    /// changes; `endLiveSession` drops it. `.null` union makes the degraded checks no-op, as elsewhere.
    private var liveWindows: [CGWindowID: SCWindow] = [:]
    private var liveDisplayUnion: CGRect = .null

    /// When set (env var `TFS_THUMB_LOG`), each capture logs its ScreenCaptureKit frame next to the
    /// window's logical frame so the set-aside/off-screen "degraded" signal can be confirmed and the
    /// thresholds in `isDegradedCapture` tuned against real data (see the change's task 1.2 / 1.3).
    private let frameLoggingEnabled = ProcessInfo.processInfo.environment["TFS_THUMB_LOG"] != nil

    func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Pay ScreenCaptureKit's one-time cold-start cost — framework init + XPC handshake + the first
    /// `SCShareableContent` enumeration + the first `SCScreenshotManager` capture — in the BACKGROUND at
    /// launch, so the FIRST switcher session doesn't stall mid-reel-slide on it (the first-run-only
    /// stutter; SCK then stays warm for the whole process lifetime, which is why every later session is
    /// smooth). No-op without Screen Recording permission (the live path re-tries on real use). The one
    /// throwaway capture is tiny and discarded — it exists only to warm the screenshot pipeline, not the
    /// cache. Best-effort: every failure is swallowed.
    func warmUp() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let w = content.windows.first(where: { $0.windowLayer == 0 && $0.frame.width > 1 }) else { return }
            let config = SCStreamConfiguration()
            config.width = 32
            config.height = 32
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: w)
            _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            // Best-effort warmup; the real capture paths re-enumerate and re-try on use.
        }
    }

    /// Apply any cached thumbnails to the model immediately, so repeat showings render the
    /// preview instantly (instead of icon-only) while a fresh capture is in flight.
    func seed(into model: SwitcherModel, ids: [CGWindowID]) {
        for id in ids {
            // Seed via the immediate path: a cached frame must show the instant the Space slides in, even
            // while a prior switch's slide freeze still holds (fast consecutive switches) — only LIVE
            // captures landing mid-slide are the ones the freeze buffers.
            if let image = cache[id] { model.seedThumbnail(image, for: id) }
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

    /// Store an externally-captured **good** frame into this service's cache and notify its observer, so a
    /// frame another surface captured (e.g. the Dock preview capturing a window while it had fronted it)
    /// refreshes this cache — and therefore a later `seed` / `cached` read — plus any live model bound via
    /// `onThumbnail`. Intended for known-good frames only (no degraded gate here); pass the same
    /// `CGWindowID` both services key on, so the frame lands on the right window everywhere.
    func inject(_ image: NSImage, for id: CGWindowID) {
        store(id, image)
        onThumbnail?(id, image)
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

    /// Open a per-gesture live session: enumerate SCShareableContent ONCE and snapshot every window by
    /// id, so `liveCapture` can re-capture the highlighted window each frame without paying for the
    /// enumeration again. Degrades silently (clears state) when Screen Recording permission is missing.
    func prepareLiveSession() async {
        guard CGPreflightScreenCaptureAccess() else {
            endLiveSession()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            liveWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { _, new in new })
            liveDisplayUnion = Self.displayUnion()
        } catch {
            endLiveSession()
        }
    }

    /// Re-enumerate the live-session snapshot (same work as `prepareLiveSession`), for when the visible
    /// row changes and the highlighted window's SCWindow may not be in the existing snapshot.
    func refreshLiveSession() async {
        await prepareLiveSession()
    }

    /// Drop the live-session snapshot at gesture end.
    func endLiveSession() {
        liveWindows = [:]
        liveDisplayUnion = .null
    }

    /// Fast per-frame capture of a single highlighted window during a held gesture, reusing the
    /// `prepareLiveSession` snapshot instead of re-enumerating SCShareableContent. `inFlight` provides
    /// back-pressure (self-pacing): a frame requested while one is still in flight is dropped, never
    /// queued. If the id is missing from the snapshot we fall back to the enumeration path so coverage
    /// is never lost. Otherwise it runs the same degraded gate and capture config as `capture`.
    func liveCapture(_ id: CGWindowID, logicalFrame: CGRect) async {
        if inFlight.contains(id) { return }
        guard let scWindow = liveWindows[id] else {
            await capture(id, logicalFrame: logicalFrame, displayUnion: Self.displayUnion())
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        if frameLoggingEnabled {
            NSLog("[TFS-thumb] liveCapture id=\(id) sc=\(scWindow.frame) logical=\(logicalFrame)")
        }
        // Don't overwrite a good cached thumbnail with a degraded capture — keep the last good frame.
        if Self.isDegradedCapture(scFrame: scWindow.frame, logicalFrame: logicalFrame, displayUnion: liveDisplayUnion) {
            return
        }

        do {
            let config = streamConfiguration(for: scWindow)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
            store(id, image)
            onThumbnail?(id, image)
        } catch {
            // Window gone or capture failed: leave the cached frame untouched.
        }
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

            let config = streamConfiguration(for: scWindow)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let image = NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
            store(id, image)
            onThumbnail?(id, image)
        } catch {
            // Permission denied, window gone, or capture failed: leave the placeholder in place.
        }
    }

    /// Shared single-window screenshot configuration used by both `capture` and `liveCapture`: capture
    /// at the window's NATIVE (Retina) pixel resolution — `frame` (points) × the display's backing
    /// scale — capped to `thumbnailMaxSize`, no cursor, no surrounding shadow. Capturing at native
    /// pixels (not point size) keeps the thumbnail sharp when it is downscaled into a large grid card,
    /// like Mission Control's live thumbnails. Behavior-identical across both paths so the fast live
    /// capture matches the enumeration capture pixel-for-pixel.
    private func streamConfiguration(for scWindow: SCWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let nativeW = max(scWindow.frame.width * backing, 1)
        let nativeH = max(scWindow.frame.height * backing, 1)
        let fit = min(thumbnailMaxSize.width / nativeW, thumbnailMaxSize.height / nativeH, 1)
        config.width = max(Int(nativeW * fit), 1)
        config.height = max(Int(nativeH * fit), 1)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return config
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
