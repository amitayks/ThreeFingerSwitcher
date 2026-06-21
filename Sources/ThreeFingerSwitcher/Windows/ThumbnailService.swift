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
    /// Pixel budget for a captured thumbnail — bounded to roughly the on-screen card size × a Retina
    /// headroom, NOT the window's full native resolution. Cards solve to ~180–260 pt, so captures sized
    /// to the display target keep capture/composite cost (and a bad frame's time on screen) from scaling
    /// with the source window's resolution. (Was 1100×700 native-Retina — ~8× more pixels than any card
    /// shows, pure cost resampled every frame.)
    private let thumbnailMaxSize = CGSize(width: 600, height: 400)

    private var inFlight: Set<CGWindowID> = []

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

    /// Refresh previews for the given windows — re-capture every cleanly-presented window from a SINGLE
    /// `SCShareableContent` enumeration. Run both on overlay open (immediate first frame for the whole
    /// visible row) and repeatedly from the periodic preview-refresh timer. Unlike the old cache-first
    /// prefetch, a window that ALREADY has a cached frame IS re-captured (the cached frame shows meanwhile
    /// via `seed`) — this is what keeps the row fresh and lets a slipped-through frame self-heal on the next
    /// sweep. A window that is not cleanly presented — parked off every display (Stage-Manager set-aside) or
    /// a Stage-Manager strip proxy — is skipped and served from cache/icon instead. The `inFlight` guard
    /// gives per-window back-pressure so an in-flight capture is never duplicated. Off-Space-but-on-screen
    /// windows still capture; minimized windows never reach here (`snapshot()`'s `isSwitchable` excludes them).
    func prefetch(_ windows: [WindowInfo]) {
        guard CGPreflightScreenCaptureAccess() else { return }
        let targets = windows.filter { !inFlight.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task { await self.refreshBatch(targets) }
    }

    /// Capture every cleanly-presented window in `windows` from ONE shared `SCShareableContent` enumeration
    /// (the enumeration is the expensive part — paying it once per sweep instead of once per window is the
    /// batch win). Each window is degraded-gated against its fresh enumerated frame and captured as a
    /// concurrent child task, self-paced by `inFlight`.
    private func refreshBatch(_ windows: [WindowInfo]) async {
        let displayUnion = Self.displayUnion()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return  // Enumeration failed (permission, transient): leave cached frames in place.
        }
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { _, new in new })
        for w in windows {
            guard !inFlight.contains(w.id) else { continue }
            // Skip a not-cleanly-presented window (parked off every display, or a Stage-Manager strip
            // proxy); `seed` already shows its cached/icon. Pass the real (AX) frame as the logical frame
            // so the degraded check compares the SCK frame against the TRUE size.
            guard Self.shouldPrefetchCapture(displayedFrame: w.frame, realFrame: w.realFrame,
                                             displayUnion: displayUnion),
                  let scWindow = byID[w.id] else { continue }
            let logical = w.realFrame.width > 1 ? w.realFrame : w.frame
            // Capture sequentially (each window awaited before the next): the visible row is bounded and a
            // single screenshot is cheap, so the whole sweep lands well within the refresh interval, while
            // `inFlight` still guards an overlapping sweep from re-capturing the same window.
            inFlight.insert(w.id)
            await captureWindow(scWindow, id: w.id, logicalFrame: logical, displayUnion: displayUnion)
            inFlight.remove(w.id)
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

    /// A window whose displayed (CGWindowList / ScreenCaptureKit) frame is below this fraction of its
    /// real (Accessibility) frame in EITHER dimension is NOT cleanly presented: a Stage-Manager strip
    /// proxy (set-aside, ~13% of real) OR a window mid-animation between the strip and the full stage
    /// (it scales through everything from ~15% up to nearly full, AND morphs aspect — strip ≈1.15 →
    /// stage ≈1.59 — which is why EITHER dimension being short is the signal). Capturing such a frame
    /// yields the tilted "sideways" bitmap. A cleanly-presented window reports displayed == real
    /// (ratio 1.0), far clear of this. Raised from 0.5 (which only caught the fully set-aside endpoint
    /// and let the whole TRANSITION through — confirmed by the cross-space diagnostic).
    static let cleanScaleThreshold: CGFloat = 0.85

    /// Authoritative degraded-capture test run after ScreenCaptureKit reports the window's actual
    /// frame: degraded when the window is parked off every display (set aside) OR its captured frame is
    /// below `cleanScaleThreshold` of the logical frame in EITHER dimension (a Stage-Manager strip proxy
    /// or a strip⇄stage transition frame). Pure, for testing.
    static func isDegradedCapture(scFrame: CGRect, logicalFrame: CGRect, displayUnion: CGRect) -> Bool {
        if isOffAllDisplays(scFrame, displayUnion: displayUnion) { return true }
        if logicalFrame.width > 1, logicalFrame.height > 1,
           scFrame.width / logicalFrame.width < cleanScaleThreshold
            || scFrame.height / logicalFrame.height < cleanScaleThreshold {
            return true
        }
        return false
    }

    /// True when the window's displayed (CGWindowList) frame is a scaled proxy of its real
    /// (Accessibility) frame — a Stage-Manager strip thumbnail (set-aside) OR a window mid-animation
    /// between the strip and the stage, reported far smaller than the real window in EITHER dimension
    /// (CGWindowList gives the scaled rect while AX gives the true size), often on-screen at positive
    /// coordinates so the off-screen test does not catch it. Such a window only captures as the small
    /// tilted bitmap, so we skip it and serve the cached image / icon. A `.zero`/degenerate realFrame
    /// returns false (no real-size info → don't suppress). Pure, for unit testing.
    static func isStripProxy(displayedFrame: CGRect, realFrame: CGRect) -> Bool {
        guard realFrame.width > 1, realFrame.height > 1 else { return false }
        return displayedFrame.width / realFrame.width < cleanScaleThreshold
            || displayedFrame.height / realFrame.height < cleanScaleThreshold
    }

    /// Pure: whether a refresh sweep should capture this window. Capture every cleanly-presented window —
    /// a cached frame is NOT a reason to skip (re-capturing is what keeps the row fresh and self-healing);
    /// skip only a not-cleanly-presented window (parked off all displays, or a Stage-Manager strip proxy),
    /// which would capture as the tilted strip and is served from cache/icon instead. Pure, for unit testing.
    static func shouldPrefetchCapture(displayedFrame: CGRect, realFrame: CGRect, displayUnion: CGRect) -> Bool {
        if isOffAllDisplays(displayedFrame, displayUnion: displayUnion) { return false }
        if isStripProxy(displayedFrame: displayedFrame, realFrame: realFrame) { return false }
        return true
    }

    /// The window's CURRENT bounds via a cheap single-id `CGWindowList` query — a LIVE read (not the
    /// sweep's `SCShareableContent` snapshot), so it tracks an in-flight Stage-Manager / Dock animation
    /// frame by frame. Used as the motion gate's before/after-capture probe and to gate the degraded check
    /// on the freshest geometry. Returns nil when the window is gone or yields no bounds (callers fall back
    /// to the snapshot frame).
    static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return rect
    }

    /// Pure motion gate: a capture is "sideways" (mid-animation → discard) when the window's frame changed
    /// across the capture. The Stage-Manager perspective tilt and the Dock genie ONLY happen while the
    /// window's frame is animating, so a frame that is identical immediately before and after the capture is
    /// settled (and never tilted); any change — even 1px — means the pixels were grabbed mid-motion. Exact
    /// `CGRect` inequality, so it adds no latency for a still window. Pure, for unit testing.
    static func frameMovedDuringCapture(before: CGRect, after: CGRect) -> Bool {
        before != after
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

    /// One-shot capture of a single window by id: enumerate, find the window, then capture it through the
    /// shared `captureWindow` (degraded + motion gated). Used by the Dock preview after it fronts and settles
    /// a window — the shared motion gate also protects it, dropping a frame grabbed while the window is still
    /// animating forward (the last good frame holds until it settles). `inFlight` self-paces (a call for an
    /// id already in flight is dropped). Degrades silently without Screen Recording permission.
    func captureOne(_ id: CGWindowID, logicalFrame: CGRect) async {
        guard CGPreflightScreenCaptureAccess(), !inFlight.contains(id) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let displayUnion = Self.displayUnion()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { return }
            await captureWindow(scWindow, id: id, logicalFrame: logicalFrame, displayUnion: displayUnion)
        } catch {
            // Enumeration failed (permission, transient): leave the cached frame untouched.
        }
    }

    /// Capture a single already-enumerated `SCWindow` and store + notify on success — but only when the frame
    /// is both cleanly presented AND still. Two complementary gates keep a bad ("sideways") frame from ever
    /// replacing the last good one, so nothing degraded is rendered even for one tick:
    ///   • degraded gate (`isDegradedCapture`) on the window's FRESH live frame — rejects a static-degraded
    ///     window (Stage-Manager set-aside strip, or parked off every display);
    ///   • motion gate — the live frame is read just before AND just after the capture, and if it moved
    ///     across the capture the window was mid-animation (Stage-Manager morph / Dock genie / app-switch
    ///     settle), so the grabbed pixels are the tilted frame and are DISCARDED.
    /// On either rejection nothing is stored, so the cached/last-good frame stays until a later sweep lands a
    /// clean one. A still, cleanly-presented window passes both immediately (no added latency). Non-throwing;
    /// the caller owns `inFlight` bookkeeping.
    private func captureWindow(_ scWindow: SCWindow, id: CGWindowID, logicalFrame: CGRect, displayUnion: CGRect) async {
        let frameBefore = Self.liveBounds(of: id) ?? scWindow.frame
        if frameLoggingEnabled {
            NSLog("[TFS-thumb] capture id=\(id) before=\(frameBefore) sc=\(scWindow.frame) onScreen=\(scWindow.isOnScreen) logical=\(logicalFrame)")
        }
        if Self.isDegradedCapture(scFrame: frameBefore, logicalFrame: logicalFrame, displayUnion: displayUnion) {
            return
        }
        do {
            let config = streamConfiguration(for: scWindow)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            // Motion gate: a frame change across the capture means the window was animating — the grabbed
            // pixels are the tilted "sideways" frame. Discard so the last good frame is kept; a later sweep
            // re-captures it once settled.
            let frameAfter = Self.liveBounds(of: id) ?? frameBefore
            if Self.frameMovedDuringCapture(before: frameBefore, after: frameAfter) {
                if frameLoggingEnabled {
                    NSLog("[TFS-thumb] capture id=\(id) DISCARDED in-motion (\(frameBefore) → \(frameAfter))")
                }
                return
            }
            if frameLoggingEnabled {
                NSLog("[TFS-thumb] capture id=\(id) STORED image=\(cgImage.width)x\(cgImage.height) (config=\(config.width)x\(config.height))")
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
            store(id, image)
            onThumbnail?(id, image)
        } catch {
            // Window gone or capture failed: leave the cached frame untouched.
        }
    }

    /// Pure: the capture pixel dimensions for a window — its native size (point size × backing scale)
    /// scaled to fit within `cap`, never upscaled (`fit ≤ 1`) and never below 1px. Bounding to the
    /// display-target `cap` rather than full native Retina keeps capture/composite cost proportional to
    /// what a card shows. Extracted for unit testing.
    static func captureDimensions(windowSize: CGSize, backingScale: CGFloat, cap: CGSize) -> (width: Int, height: Int) {
        let nativeW = max(windowSize.width * backingScale, 1)
        let nativeH = max(windowSize.height * backingScale, 1)
        let fit = min(cap.width / nativeW, cap.height / nativeH, 1)
        return (max(Int(nativeW * fit), 1), max(Int(nativeH * fit), 1))
    }

    /// Shared single-window screenshot configuration used by `captureWindow`: capture
    /// sized by `captureDimensions` (native pixels bounded to `thumbnailMaxSize`, the display target),
    /// no cursor, no surrounding shadow. Behavior-identical across both paths so the fast live capture
    /// matches the enumeration capture pixel-for-pixel.
    private func streamConfiguration(for scWindow: SCWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        let dims = Self.captureDimensions(windowSize: scWindow.frame.size, backingScale: backing, cap: thumbnailMaxSize)
        config.width = dims.width
        config.height = dims.height
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
