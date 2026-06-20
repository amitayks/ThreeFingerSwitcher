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

    /// Per-gesture "live session" cache: while a switcher gesture is held, the visible row's window can
    /// be re-captured every frame via `liveCapture` WITHOUT re-enumerating SCShareableContent each time
    /// (the enumeration in `capture` is the expensive part). `prepareLiveSession` snapshots the windows
    /// and display union once at gesture start; `refreshLiveSession` re-snapshots when the visible row
    /// changes; `endLiveSession` drops it. `.null` union makes the degraded checks no-op, as elsewhere.
    private var liveWindows: [CGWindowID: SCWindow] = [:]
    private var liveDisplayUnion: CGRect = .null

    /// How many consecutive ticks (at the live-preview cadence) a window's frame must be UNCHANGED before
    /// a fresh live capture is allowed. The bounds settle a beat BEFORE the pixels finish the Stage-Manager
    /// perspective/aspect morph, so a 1-tick "held still" check can still grab that tilted tail; requiring
    /// a few stable ticks (~0.3 s at the 0.1 s cadence) lets the morph fully land first. The seeded
    /// last-good frame shows meanwhile, so the card is never blank. Tunable from `TFS_THUMB_LOG` data.
    static let liveSettleTicks = 3

    /// Per-session record of each window's last-observed live frame AND how many consecutive ticks it has
    /// been unchanged, for the motion gate: the highlighted window is live-captured only once its frame has
    /// held still for `liveSettleTicks` ticks — so neither an in-flight Stage-Manager / Dock morph NOR its
    /// just-settled-but-still-tilted tail frame is captured. Cleared in `endLiveSession`.
    private var liveBoundsSeen: [CGWindowID: (frame: CGRect, stableTicks: Int)] = [:]

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

    /// One-shot (re)capture of the given windows when the overlay is shown, CACHE-FIRST: a window that
    /// ALREADY has a cached frame is NOT re-captured — its good frame is kept (never clobbered by a
    /// possibly mid-animation open-time capture), and a window that is not cleanly presented right now is
    /// likewise skipped, so its cached/icon (applied via `seed`) shows instead of a degraded image. Only
    /// a never-seen, cleanly-presented window is captured here; continuous refresh of the highlighted
    /// window is the live path's job. The `inFlight` guard prevents duplicate concurrent captures.
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
            // Skip a window that already has a good cached frame (never clobber it with a possibly
            // mid-animation open-time capture — the bystander "sideways" case: a window like Terminal
            // captured while Stage Manager is still settling after an app switch), and skip a window
            // whose capture would be a degraded proxy ((a) parked off every display, or (b) a
            // Stage-Manager strip thumbnail). `seed` already shows the cached/icon for all of these;
            // only a never-seen, cleanly-presented window is captured. Continuous refresh of the
            // highlighted window stays on the live path.
            guard Self.shouldPrefetchCapture(hasCachedFrame: cache[w.id] != nil,
                                             displayedFrame: w.frame, realFrame: w.realFrame,
                                             displayUnion: displayUnion) else { continue }
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

    /// Pure: whether the one-shot open prefetch should capture this window. Skip when it ALREADY has a
    /// cached frame (don't clobber a good frame with a possibly mid-animation open-time capture — the
    /// bystander "sideways" case), or when its presentation is degraded (parked off all displays, or a
    /// Stage-Manager strip proxy). Only a never-seen, cleanly-presented window is captured. Pure, for
    /// unit testing.
    static func shouldPrefetchCapture(hasCachedFrame: Bool, displayedFrame: CGRect,
                                      realFrame: CGRect, displayUnion: CGRect) -> Bool {
        if hasCachedFrame { return false }
        if isOffAllDisplays(displayedFrame, displayUnion: displayUnion) { return false }
        if isStripProxy(displayedFrame: displayedFrame, realFrame: realFrame) { return false }
        return true
    }

    /// The window's CURRENT bounds via a cheap single-id `CGWindowList` query — used to gate live capture
    /// on LIVE geometry (not the per-gesture `prepareLiveSession` snapshot) and to detect motion. Returns
    /// nil when the window is gone or the query yields no bounds (the caller falls back to the snapshot).
    static func liveBounds(of id: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return rect
    }

    /// Pure motion gate: given the previously-recorded `(frame, stableTicks)` and the window's current
    /// live frame, returns the updated consecutive-stable-tick count and whether a capture is allowed now.
    /// A capture is allowed only once the frame has been UNCHANGED for `settleTicks` consecutive ticks
    /// (waiting past both the bounds animation and the pixel-morph tail); any change — or a first
    /// observation — resets the count to 0. Pure, for unit testing.
    static func liveSettleStep(previous: (frame: CGRect, stableTicks: Int)?, current: CGRect,
                               settleTicks: Int) -> (stableTicks: Int, settled: Bool) {
        let count: Int
        if let previous, previous.frame == current {
            count = previous.stableTicks + 1
        } else {
            count = 0
        }
        return (count, count >= settleTicks)
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
        liveBoundsSeen = [:]
    }

    /// Fast per-frame capture of a single highlighted window during a held gesture, reusing the
    /// `prepareLiveSession` snapshot instead of re-enumerating SCShareableContent. `inFlight` provides
    /// back-pressure (self-pacing): a frame requested while one is still in flight is dropped, never
    /// queued. If the id is missing from the snapshot we fall back to the enumeration path so coverage
    /// is never lost.
    ///
    /// Two gates run on the window's CURRENT bounds (a cheap single-id `CGWindowList` read), not the
    /// possibly-stale snapshot: the **motion gate** withholds capture until the frame has held still for
    /// `liveSettleTicks` consecutive ticks (past the in-flight Stage-Manager / Dock morph AND its
    /// just-settled-but-still-tilted tail), keeping the last good frame meanwhile — so a transitional
    /// "sideways" frame is never captured nor frozen by scrubbing away; the **degraded gate** then runs
    /// against that same fresh frame. Both fall back to the snapshot only when the live read is unavailable.
    func liveCapture(_ id: CGWindowID, logicalFrame: CGRect) async {
        if inFlight.contains(id) { return }

        let liveFrame = Self.liveBounds(of: id)
        if let liveFrame {
            // Motion gate: capture only once the frame has held still for `liveSettleTicks` consecutive
            // ticks (past the bounds animation AND the pixel-morph tail). While it moves — or in the brief
            // settle tail — keep the last good frame; a changed frame resets the count.
            let step = Self.liveSettleStep(previous: liveBoundsSeen[id], current: liveFrame, settleTicks: Self.liveSettleTicks)
            liveBoundsSeen[id] = (liveFrame, step.stableTicks)
            guard step.settled else { return }
        }

        guard let scWindow = liveWindows[id] else {
            await capture(id, logicalFrame: logicalFrame, displayUnion: Self.displayUnion())
            return
        }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        // Gate on the FRESH live frame when available; fall back to the snapshot frame otherwise.
        let gateFrame = liveFrame ?? scWindow.frame
        if frameLoggingEnabled {
            NSLog("[TFS-thumb] liveCapture id=\(id) gate=\(gateFrame) live=\(liveFrame.map { "\($0)" } ?? "nil") snap=\(scWindow.frame) onScreen=\(scWindow.isOnScreen) logical=\(logicalFrame)")
        }
        // Don't overwrite a good cached thumbnail with a degraded capture — keep the last good frame.
        if Self.isDegradedCapture(scFrame: gateFrame, logicalFrame: logicalFrame, displayUnion: liveDisplayUnion) {
            return
        }

        do {
            let config = streamConfiguration(for: scWindow)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if frameLoggingEnabled {
                NSLog("[TFS-thumb] liveCapture id=\(id) STORED image=\(cgImage.width)x\(cgImage.height) (config=\(config.width)x\(config.height))")
            }
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
                NSLog("[TFS-thumb] capture id=\(id) sc=\(scWindow.frame) onScreen=\(scWindow.isOnScreen) logical=\(logicalFrame)")
            }
            // Don't overwrite a good cached thumbnail with a degraded capture — a Stage-Manager
            // set-aside strip proxy or an off-screen frame. Keep the cached image or icon instead.
            if Self.isDegradedCapture(scFrame: scWindow.frame, logicalFrame: logicalFrame, displayUnion: displayUnion) {
                return
            }

            let config = streamConfiguration(for: scWindow)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if frameLoggingEnabled {
                NSLog("[TFS-thumb] capture id=\(id) STORED image=\(cgImage.width)x\(cgImage.height) (config=\(config.width)x\(config.height))")
            }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
            store(id, image)
            onThumbnail?(id, image)
        } catch {
            // Permission denied, window gone, or capture failed: leave the placeholder in place.
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

    /// Shared single-window screenshot configuration used by both `capture` and `liveCapture`: capture
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
