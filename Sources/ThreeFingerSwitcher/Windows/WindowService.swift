import AppKit
import ApplicationServices
import CoreGraphics

/// Enumerates normal windows across all Spaces and raises/focuses a chosen one.
///
/// Enumeration is a hybrid: the all-Spaces candidate set comes from private CGS per-Space
/// enumeration (`CGSCopyWindowsWithOptionsAndTags`); current-Space AX elements come from
/// `kAXWindowsAttribute`; off-Space AX elements are acquired on demand via remote-token brute
/// force (`_AXUIElementCreateWithRemoteToken`). Raising an off-Space window uses the SkyLight
/// front/key sequence so exactly one Space switch happens at commit; current-Space windows use
/// the battle-tested AX-only path (no byte-protocol second arbiter on the high-traffic path). A
/// post-commit watchdog self-heals the residual focus-vacuum race. If the private symbols are
/// unavailable (`!cgs.offSpaceSupported`), everything falls back to the legacy current-Space
/// path — never crashing, never regressing. Technique adapted from AltTab (GPL-3).
@MainActor
final class WindowService {
    private let mru: MRUTracker
    private let settings: AppSettings

    /// Monotonic token bumped on every `raise()` commit. The watchdog closure captures the value
    /// at schedule time and bails if it has advanced — so a later commit cancels an earlier
    /// check and rapid switching never stacks recoveries.
    private var commitSeq: UInt64 = 0

    /// Watchdog tuning. 180ms is the midpoint of the 150–250ms window: past the WindowServer's
    /// own activation/Space-switch arbitration settle, yet still feels instant.
    private let watchdogDelay: TimeInterval = 0.180
    private let maxRecoveries = 2

    /// Minimum width AND height (px) for an off-Space window with no resolvable AX element to be
    /// listed from CGS metadata alone (Bug A). Clears real browser/app windows and Stage Manager
    /// strip thumbnails (min dim ≥ ~150 in captures) while dropping sliver dividers and full-width
    /// toolbars (min dim ≤ 106). Empirically chosen with margin from two cross-space diags.
    private let minOffSpaceDimension: CGFloat = 130

    /// Persistent AX-element cache keyed by CGWindowID (Bug A raise — the AltTab/HyperSwitch strategy).
    /// A fresh `_AXUIElementCreateWithRemoteToken` brute force can't reach an off-Space Chromium window,
    /// but an element captured while the window WAS reachable stays valid across Spaces — so we can
    /// `kAXRaise` it (which switches Space) later. Populated from `snapshot()` and on app activation;
    /// pruned to live windows each snapshot.
    private var elementCache: [CGWindowID: AXUIElement] = [:]
    private var activationObserver: NSObjectProtocol?

    init(mru: MRUTracker, settings: AppSettings) {
        self.mru = mru
        self.settings = settings
        // Seed the element cache when an app activates: its windows are then on the current Space and
        // resolvable via kAXWindowsAttribute. Capturing the element now lets us raise the window later,
        // after it has moved off-Space, even for apps a brute force can't reach (e.g. Chrome).
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.seedElementCache(pid: app.processIdentifier) }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Cache `pid`'s current-Space window elements (called on activation). Cheap — one app's windows.
    private func seedElementCache(pid: pid_t) {
        guard pid != getpid(), AXIsProcessTrusted() else { return }
        for (wid, el) in currentSpaceElements(pid: pid) { elementCache[wid] = el }
    }

    private struct CGMeta {
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
        let name: String?
    }

    // MARK: - Diagnostics

    /// Funnel report for `--diag`: shows where windows are kept/dropped during all-Spaces snapshot.
    func diagnosticReport() -> String {
        var out = ["=== cross-space diagnostics ==="]
        out.append("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        out.append("cgs.offSpaceSupported: \(cgs.offSpaceSupported)  raise: \(cgs.offSpaceRaiseSupported)")
        guard let model = SpaceService.currentModel() else {
            out.append("SpaceService.currentModel() = nil → would use legacySnapshot (\(legacySnapshot().count) windows)")
            return out.joined(separator: "\n")
        }
        out.append("spaces: \(model.orderedSpaceIDs.count)  currentSpaceIDs: \(model.currentSpaceIDs.count) \(Array(model.currentSpaceIDs))")
        var spaceForWindow: [CGWindowID: (space: CGSSpaceID, z: Int)] = [:]
        for spaceID in model.orderedSpaceIDs {
            let wins = SpaceService.windowsInSpace(spaceID)
            out.append("  space \(spaceID): \(wins.count) windows")
            for wid in wins where spaceForWindow[wid] == nil { spaceForWindow[wid] = (spaceID, 0) }
        }
        out.append("unique candidate windows: \(spaceForWindow.count)")
        let allWids = Array(spaceForWindow.keys)
        let meta = metadata(for: allWids)
        out.append("with CGWindowList metadata: \(meta.count)")
        let selfPid = getpid()
        let appsByPid = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated }
            .map { $0.processIdentifier })
        var withApp = 0, layer0 = 0, sample: [String] = []
        for (wid, _) in spaceForWindow {
            guard let m = meta[wid] else { continue }
            if appsByPid.contains(m.pid) { withApp += 1 } else { continue }
            if m.layer == 0 { layer0 += 1 } else { continue }
            if sample.count < 8 { sample.append("wid \(wid) pid \(m.pid) layer \(m.layer) '\(m.name ?? "")'") }
        }
        out.append("owned by a regular app: \(withApp)")
        out.append("layer==0 (normal windows): \(layer0)")
        out.append("sample: \n   " + sample.joined(separator: "\n   "))

        let final = snapshot()
        out.append("final snapshot().count: \(final.count)")
        for w in final {
            let subrole = w.axElement.flatMap { axString($0, kAXSubroleAttribute as String) } ?? "no-element"
            out.append("  • wid \(w.id) pid \(w.pid) space \(w.spaceID.map(String.init) ?? "-") cur=\(w.isOnCurrentSpace) subrole=\(subrole) '\(w.displayTitle)'")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Snapshot

    /// Snapshot of switchable windows in MRU order. Excludes minimized and our own app.
    func snapshot() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        guard cgs.offSpaceSupported, let model = SpaceService.currentModel() else {
            return legacySnapshot()
        }
        let selfPid = getpid()

        let appsByPid: [pid_t: NSRunningApplication] = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated }
                .map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        // Assign each window a Space + global z-order from the per-Space enumeration.
        var spaceForWindow: [CGWindowID: (space: CGSSpaceID, z: Int)] = [:]
        var z = 0
        for spaceID in model.orderedSpaceIDs {
            for wid in SpaceService.windowsInSpace(spaceID) {
                if spaceForWindow[wid] == nil { spaceForWindow[wid] = (spaceID, z) }
                z += 1
            }
        }
        guard !spaceForWindow.isEmpty else { return legacySnapshot() }

        let meta = metadata(for: Array(spaceForWindow.keys))

        // Per-snapshot AX element caches.
        var axCurrentByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var axBruteByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]

        var rows: [(window: WindowInfo, appRank: Int, onCurrent: Int, spaceIdx: Int, z: Int)] = []

        for (wid, placement) in spaceForWindow {
            guard let m = meta[wid] else { continue }
            guard let app = appsByPid[m.pid] else { continue }      // regular app, not self
            guard m.layer == 0 else { continue }                    // normal window layer

            let onCurrent = model.currentSpaceIDs.contains(placement.space)

            // Acquire an AX element: current-Space via kAXWindowsAttribute, off-Space via brute force.
            var element: AXUIElement?
            if onCurrent {
                if axCurrentByPid[m.pid] == nil {
                    axCurrentByPid[m.pid] = currentSpaceElements(pid: m.pid)
                }
                element = axCurrentByPid[m.pid]?[wid]
            } else {
                if axBruteByPid[m.pid] == nil {
                    axBruteByPid[m.pid] = Dictionary(bruteForceWindows(pid: m.pid), uniquingKeysWith: { a, _ in a })
                }
                element = axBruteByPid[m.pid]?[wid]
            }
            // Refresh the persistent cache while the window is reachable; otherwise fall back to a
            // previously-cached element (still valid off-Space) so a Chromium window a brute force
            // can't find is still raisable (Bug A raise).
            if let el = element {
                elementCache[wid] = el
            } else if let cached = elementCache[wid], axCopy(cached, kAXRoleAttribute as String) != nil {
                element = cached
            }

            // Decide switchability. When an AX element resolved (current-Space via kAXWindowsAttribute,
            // or off-Space via remote-token brute force), require a standard window subrole — AltTab's
            // rule that filters the invisible/companion windows options=7 surfaces. When NO element
            // resolves for an off-Space window (Chromium browsers expose none reachable by remote
            // token, so they used to vanish — Bug A), fall back to CoreGraphicsServices metadata:
            // layer 0 (already enforced) + non-zero alpha + a real minimum dimension. That lists real
            // browser/app windows while still rejecting sliver dividers, full-width toolbars, and
            // zero-alpha shadow companions. Confirmed against two cross-space diags.
            let listable: Bool
            if let el = element {
                listable = isSwitchable(el)
            } else if !onCurrent {
                listable = m.alpha > 0 && min(m.bounds.width, m.bounds.height) >= minOffSpaceDimension
            } else {
                listable = false
            }
            guard listable else { continue }

            let title = (element.flatMap { axString($0, kAXTitleAttribute as String) })
                ?? m.name
                ?? (app.localizedName ?? "")

            let info = WindowInfo(
                id: wid,
                pid: m.pid,
                appName: app.localizedName ?? "",
                title: title,
                appIcon: app.icon,
                frame: m.bounds,
                axElement: element,
                isOnCurrentSpace: onCurrent,
                spaceID: placement.space
            )
            rows.append((info, mru.rank(m.pid), onCurrent ? 0 : 1, model.indexBySpace[placement.space] ?? Int.max, placement.z))
        }

        // Evict cached elements for windows that no longer exist (keep only currently-enumerated ids).
        elementCache = elementCache.filter { spaceForWindow[$0.key] != nil }

        rows.sort { a, b in
            if a.appRank != b.appRank { return a.appRank < b.appRank }   // MRU app first
            if a.onCurrent != b.onCurrent { return a.onCurrent < b.onCurrent } // current Space first
            if a.spaceIdx != b.spaceIdx { return a.spaceIdx < b.spaceIdx }
            return a.z < b.z                                              // z-order within Space
        }
        return rows.map(\.window)
    }

    /// Legacy current-Space-only enumeration (today's behavior). Used when off-Space support is
    /// unavailable, so we never regress or crash.
    private func legacySnapshot() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let selfPid = getpid()
        var result: [(window: WindowInfo, appRank: Int, zIndex: Int)] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated
        }
        for app in apps {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            guard let axWindows = axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let appRank = mru.rank(pid)
            for (zIndex, axWin) in axWindows.enumerated() {
                guard isSwitchable(axWin), let wid = axWindowID(axWin) else { continue }
                let info = WindowInfo(
                    id: wid, pid: pid, appName: app.localizedName ?? "",
                    title: axString(axWin, kAXTitleAttribute as String) ?? "",
                    appIcon: app.icon, frame: axFrame(axWin),
                    axElement: axWin, isOnCurrentSpace: true, spaceID: nil
                )
                result.append((info, appRank, zIndex))
            }
        }
        result.sort { a, b in a.appRank != b.appRank ? a.appRank < b.appRank : a.zIndex < b.zIndex }
        return result.map(\.window)
    }

    // MARK: - Raise

    /// Raise and focus a window without ever leaving a focus vacuum (a frontmost app with no key
    /// window, which makes the WindowServer drop all clicks/keys/scroll until Mission Control
    /// re-arbitrates).
    ///
    /// The path branches on `isOnCurrentSpace`:
    ///   • Current Space (the 95%+ common case): plain AX (raise + main + focused) then a single
    ///     deterministic `activate()`. NO SkyLight byte-protocol makeKeyWindow — that introduced a
    ///     second focus arbiter on the high-traffic path, multiplying the interleave surface.
    ///   • Off Space: keep the SkyLight setFront + makeKeyWindow handshake (the only thing that
    ///     crosses Spaces reliably in one shot), then AX + activate.
    ///
    /// A post-commit watchdog (see `scheduleWatchdog`) self-heals the residual vacuum race. For an
    /// off-Space raise under Stage Manager there is a second, later steal — WindowManager grabs
    /// frontmost ~300ms after the Space switch — handled by the polling hold-guard (`offSpaceHoldTick`).
    func raise(_ window: WindowInfo) {
        commitSeq &+= 1
        let token = commitSeq

        focusSequence(window, offSpaceHandshake: !window.isOnCurrentSpace)

        // Instrument: record the commit and (cheaply) the focus state right after committing.
        let state = FocusLog.probe(targetPID: window.pid)
        logEntry(.commit, window: window, passed: nil, state: state, note: "")

        scheduleWatchdog(window, token: token, attempt: 0)
        if !window.isOnCurrentSpace && StageManager.isEnabled {
            scheduleNextHoldTick(window, token: token, tick: 0, refronts: 0)
        }
    }

    /// Off-Space focus-hold guard tuning. Under Stage Manager, WindowManager grabs frontmost ~300–500ms
    /// after an off-Space raise — a key-less vacuum the +180ms watchdog is too early to see (verified by
    /// trace). Rather than re-front at a fixed delay (a visible ~200ms flash), poll frequently and
    /// re-front the INSTANT the steal is detected (≈ one poll of flash), then keep watching for the
    /// occasional late re-steal. Bounded so a daemon that fights back can't make us thrash or loop.
    private let offSpaceHoldInterval: TimeInterval = 0.06   // detect the steal within ~one frame
    private let offSpaceHoldTicks = 40                      // ~2.4s guard window (covers late re-steals)
    private let offSpaceHoldMaxRefronts = 6

    private func scheduleNextHoldTick(_ window: WindowInfo, token: UInt64, tick: Int, refronts: Int) {
        guard tick < offSpaceHoldTicks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + offSpaceHoldInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.offSpaceHoldTick(window, token: token, tick: tick, refronts: refronts)
            }
        }
    }

    private func offSpaceHoldTick(_ window: WindowInfo, token: UInt64, tick: Int, refronts: Int) {
        guard token == commitSeq else { return }            // superseded by a newer commit
        let state = FocusLog.probe(targetPID: window.pid)
        if state.frontmostMatchesTarget && state.frontmostHasKeyWindow {
            scheduleNextHoldTick(window, token: token, tick: tick + 1, refronts: refronts)
            return
        }
        // Secure input held by another app: re-fronting can't help and may thrash — log and stop.
        if state.secureInputEnabled {
            logEntry(.trace, window: window, passed: false, state: state, note: "hold-guard: secure-input held; not re-fronting")
            return
        }
        // WindowManager (or anyone) stole front — re-front immediately, bounded.
        if refronts >= offSpaceHoldMaxRefronts {
            logEntry(.gaveUp, window: window, passed: false, state: state, note: "hold-guard gave up after \(refronts) re-fronts")
            return
        }
        focusSequence(window, offSpaceHandshake: true)
        logEntry(.trace, window: window, passed: false, state: state, note: "hold-refront #\(refronts + 1) @tick\(tick)")
        scheduleNextHoldTick(window, token: token, tick: tick + 1, refronts: refronts + 1)
    }

    /// Run one focus sequence for `window`. With `offSpaceHandshake` the SkyLight setFront +
    /// makeKeyWindow byte protocol runs first to cross Spaces; otherwise it is skipped (current
    /// Space uses the battle-tested AX-only path). Always finishes by activating the owning app
    /// so an accessory agent still establishes key state.
    private func focusSequence(_ window: WindowInfo, offSpaceHandshake: Bool) {
        let element = resolveElement(window)

        // Stage Manager: asserting the PER-APP focus singletons (kAXMain on the window + the app's
        // kAXFocusedWindow) toward a window that shares the center stage with other windows of the same
        // app makes WindowManager's stage-front arbiter fight back — current-Space co-staged windows
        // oscillate ~12/sec (a self-sustaining WindowManager loop that survives this process quitting,
        // verified by log capture). So on the CURRENT-Space path under Stage Manager we skip those
        // singleton writes and rely on kAXRaise + activate(). The OFF-Space path keeps the singletons
        // (load-bearing to hold key across the Space switch); the separate steal WindowManager performs
        // ~300ms after every off-Space switch is handled by the polling hold-guard, not here.
        let stageManagerSafe = !offSpaceHandshake && StageManager.isEnabled

        // NOTE (Bug A, raise): an off-Space window with no LIVE AX element (e.g. Chromium, which a
        // remote-token brute force can't reach) is raised via a CACHED element (see `elementCache`):
        // kAXRaiseAction on it drives the Space switch like any other window. We do NOT attempt a direct
        // Space switch — CGSManagedDisplaySetCurrentSpace is gated by the WindowServer to Dock.app's
        // privileged connection only (dead for an unentitled, SIP-on process on Tahoe; that is why yabai
        // must disable SIP to inject into Dock). If no cached element exists yet, the window fronts its
        // app without switching Space until it has been focused once (the AltTab/HyperSwitch limit).

        // 1. SkyLight front + key handshake — only for off-Space windows.
        if offSpaceHandshake,
           cgs.offSpaceRaiseSupported,
           let getPSN = cgs.getProcessForPID,
           let setFront = cgs.setFrontProcessWithOptions {
            var psn = ProcessSerialNumber()
            if getPSN(window.pid, &psn) == 0, !(psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0) {
                _ = setFront(&psn, window.id, 0x200) // 0x200 = userGenerated
                _ = makeKeyWindow(psn, window.id)    // best-effort; activate() below is the safety net
            }
        }

        // 2. Accessibility focus: always raise the chosen window. Assert the per-app main/focused-window
        //    singletons only when NOT under Stage Manager (they are the oscillation trigger there).
        if let el = element {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            if !stageManagerSafe {
                AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
                let appEl = AXUIElementCreateApplication(window.pid)
                AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, el)
            }
        }

        // 3. Activate the owning app so a key window is established even if AX was stale.
        NSRunningApplication(processIdentifier: window.pid)?.activate()
    }

    // MARK: - Watchdog

    /// Schedule a single post-commit verify at +180ms. If the verify FAILs (and it isn't secure
    /// input), run a bounded recovery and re-schedule; give up after `maxRecoveries` attempts.
    /// Cancelled implicitly when a later commit advances `commitSeq`.
    private func scheduleWatchdog(_ window: WindowInfo, token: UInt64, attempt: Int) {
        guard settings.focusWatchdogEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.runWatchdog(window, token: token, attempt: attempt)
            }
        }
    }

    private func runWatchdog(_ window: WindowInfo, token: UInt64, attempt: Int) {
        // A newer commit superseded us — drop this stale check (prevents stacked recoveries).
        guard token == commitSeq else { return }

        let state = FocusLog.probe(targetPID: window.pid)
        let healthy = state.frontmostMatchesTarget && state.frontmostHasKeyWindow
        let phase: FocusLog.Phase = (attempt == 0) ? .verify : (attempt == 1 ? .recover1 : .recover2)

        if healthy {
            logEntry(phase, window: window, passed: true, state: state, note: "")
            return
        }

        // Secure Event Input held by ANOTHER app: not our vacuum. Recovery can't help and may
        // thrash, so just log it so instrumentation explains the freeze.
        if state.secureInputEnabled {
            logEntry(phase, window: window, passed: false, state: state, note: "secure-input (not our vacuum); no recovery")
            NSLog("[TFS-focus] FAIL secure-input held; not recovering pid=\(window.pid)")
            return
        }

        logEntry(phase, window: window, passed: false, state: state,
                 note: state.frontmostMatchesTarget ? "frontmost-but-no-key-window" : "activation-no-op")
        NSLog("[TFS-focus] FAIL pid=\(window.pid) frontPID=\(state.frontmostPID) match=\(state.frontmostMatchesTarget) key=\(state.frontmostHasKeyWindow) attempt=\(attempt)")

        if attempt >= maxRecoveries {
            logEntry(.gaveUp, window: window, passed: false, state: state, note: "gave up after \(maxRecoveries) attempts")
            NSLog("[TFS-focus] gave up after \(maxRecoveries) recoveries pid=\(window.pid)")
            return
        }

        recover(window, attempt: attempt)
        scheduleWatchdog(window, token: token, attempt: attempt + 1)
    }

    /// Bounded recovery. Attempt 1: re-run a minimal validated focus sequence on the same target.
    /// Attempt 2: the "benign nudge" — bounce activation through our own agent for one runloop
    /// tick, then re-activate the target, re-seating the WindowServer's key arbitration without
    /// the user touching Mission Control.
    private func recover(_ window: WindowInfo, attempt: Int) {
        if attempt == 0 {
            // Re-validate the wid against the re-resolved element so we don't poke a dead id.
            if let el = resolveElement(window), let liveWid = axWindowID(el), liveWid == window.id {
                focusSequence(window, offSpaceHandshake: !window.isOnCurrentSpace)
            } else {
                // Element/wid went stale; fall back to a plain app activation so we don't no-op.
                NSRunningApplication(processIdentifier: window.pid)?.activate()
            }
        } else {
            // Benign nudge: activate ourselves for one tick, then re-activate the target.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self] in
                self?.focusSequence(window, offSpaceHandshake: !window.isOnCurrentSpace)
            }
        }
    }

    /// Append a FocusLog entry from a captured focus state.
    private func logEntry(_ phase: FocusLog.Phase, window: WindowInfo, passed: Bool?,
                          state: FocusLog.FocusState, note: String) {
        FocusLog.shared.record(.init(
            timestamp: Date(),
            phase: phase,
            pid: window.pid,
            appName: window.appName,
            wid: window.id,
            isOnCurrentSpace: window.isOnCurrentSpace,
            passed: passed,
            frontmostPID: state.frontmostPID,
            frontmostMatchesTarget: state.frontmostMatchesTarget,
            frontmostHasKeyWindow: state.frontmostHasKeyWindow,
            secureInputEnabled: state.secureInputEnabled,
            note: note
        ))
    }

    /// Re-resolve the AX element at commit: probe the cached one, re-acquire if stale/missing.
    private func resolveElement(_ window: WindowInfo) -> AXUIElement? {
        if let el = window.axElement, axCopy(el, kAXRoleAttribute as String) != nil {
            return el
        }
        if window.isOnCurrentSpace {
            if let el = currentSpaceElements(pid: window.pid)[window.id] { return el }
        } else {
            if let el = bruteForceWindows(pid: window.pid).first(where: { $0.0 == window.id })?.1 { return el }
        }
        // Fall back to an element cached while the window was reachable (off-Space Chromium raise).
        if let cached = elementCache[window.id], axCopy(cached, kAXRoleAttribute as String) != nil {
            return cached
        }
        return nil
    }

    /// SkyLight key-window byte protocol (AltTab-exact): two event records make a specific
    /// (possibly off-Space) window key without a focus bounce-back. Returns true only if both
    /// posts succeed, so the caller can rely on the activate() fallback when it fails.
    @discardableResult
    private func makeKeyWindow(_ psn: ProcessSerialNumber, _ wid: CGWindowID) -> Bool {
        guard let post = cgs.postEventRecordTo else { return false }
        var mutablePSN = psn
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        var ok = true
        bytes.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            p[0x04] = 0xf8
            p[0x08] = 0x01
            p[0x3a] = 0x10
            memset(p + 0x20, 0xff, 0x10)
            withUnsafeBytes(of: wid) { w in memcpy(p + 0x3c, w.baseAddress!, 4) }
            ok = (post(&mutablePSN, p) == .success)
            p[0x08] = 0x02
            ok = (post(&mutablePSN, p) == .success) && ok
        }
        return ok
    }

    // MARK: - Helpers

    /// Window ids → AX elements for a process on the current Space.
    private func currentSpaceElements(pid: pid_t) -> [CGWindowID: AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        guard let wins = axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { return [:] }
        var map: [CGWindowID: AXUIElement] = [:]
        for el in wins {
            if let wid = axWindowID(el) { map[wid] = el }
        }
        return map
    }

    /// Batched CGWindowList metadata (owner pid, layer, alpha, bounds, title) for the given ids.
    /// Works for windows on any Space (it's a description lookup, not a Space-scoped list).
    /// Build the CFArray `CGWindowListCreateDescriptionFromArray` expects: each element is the
    /// window ID cast DIRECTLY to a pointer (not boxed as CFNumber), with no callbacks.
    private func windowIDArray(_ wids: [CGWindowID]) -> CFArray? {
        var pointers: [UnsafeRawPointer?] = wids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, nil)
    }

    private func metadata(for wids: [CGWindowID]) -> [CGWindowID: CGMeta] {
        guard !wids.isEmpty, let arr = windowIDArray(wids),
              let raw = CGWindowListCreateDescriptionFromArray(arr) else { return [:] }
        var map: [CGWindowID: CGMeta] = [:]
        for case let d as [String: Any] in (raw as NSArray) {
            guard let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let pid = pid_t((d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let name = d[kCGWindowName as String] as? String
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
            }
            map[wid] = CGMeta(pid: pid, layer: layer, alpha: alpha, bounds: bounds, name: name)
        }
        return map
    }

    private func isSwitchable(_ axWin: AXUIElement) -> Bool {
        if axBool(axWin, kAXMinimizedAttribute as String) { return false }
        let role = axString(axWin, kAXRoleAttribute as String)
        guard role == (kAXWindowRole as String) else { return false }
        if let subrole = axString(axWin, kAXSubroleAttribute as String) {
            return subrole == (kAXStandardWindowSubrole as String)
        }
        return true
    }

    private func axFrame(_ axWin: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let posValue = axCopy(axWin, kAXPositionAttribute as String) {
            AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        }
        if let sizeValue = axCopy(axWin, kAXSizeAttribute as String) {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}
