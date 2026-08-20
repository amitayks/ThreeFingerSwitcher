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
    private let focus: WindowFocusTracker
    private let settings: AppSettings

    /// Monotonic token bumped on every `raise()` commit. The watchdog closure captures the value
    /// at schedule time and bails if it has advanced — so a later commit cancels an earlier
    /// check and rapid switching never stacks recoveries.
    private var commitSeq: UInt64 = 0

    /// Watchdog tuning. 180ms is the midpoint of the 150–250ms window: past the WindowServer's
    /// own activation/Space-switch arbitration settle, yet still feels instant.
    private let watchdogDelay: TimeInterval = 0.180
    private let maxRecoveries = 2

    /// The un-minimize genie animation runs ~250–400ms. When committing a MINIMIZED window we defer the
    /// raise (and therefore its +180ms watchdog) past this delay so the front+focus lands on the settled
    /// window, not mid-animation — a raise during the genie makes macOS re-composite the window (a visible
    /// flash) and the watchdog would otherwise fire mid-genie and re-raise it. 0.4s clears the genie.
    private let deminimizeSettleDelay: TimeInterval = 0.4

    /// Persistent AX-element cache keyed by CGWindowID (Bug A raise — the AltTab/HyperSwitch strategy).
    /// A fresh `_AXUIElementCreateWithRemoteToken` brute force can't reach an off-Space Chromium window,
    /// but an element captured while the window WAS reachable stays valid across Spaces — so we can
    /// `kAXRaise` it (which switches Space) later. Populated from `snapshot()` and on app activation;
    /// pruned to live windows each snapshot.
    private var elementCache: [CGWindowID: AXUIElement] = [:]

    private var activationObserver: NSObjectProtocol?

    init(mru: MRUTracker, focus: WindowFocusTracker, settings: AppSettings) {
        self.mru = mru
        self.focus = focus
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
        let isOnscreen: Bool
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
        // Every listed window now has an Accessibility element (subrole shown). After the AX-required
        // gate, snapshot() can no longer surface a metadata-only no-element row, so there is no ghost
        // block here — the per-candidate dump below is where dropped no-element ghosts are observable.
        for w in final {
            let subrole = w.axElement.flatMap { axString($0, kAXSubroleAttribute as String) } ?? "no-element"
            // cg = CGWindowList displayed bounds (a Stage-Manager strip thumbnail reports the small
            // scaled rect); ax = the Accessibility (real) size. cg << ax ⇒ strip proxy → skip capture.
            out.append("  • wid \(w.id) pid \(w.pid) space \(w.spaceID.map(String.init) ?? "-") cur=\(w.isOnCurrentSpace) "
                + "cg=\(Int(w.frame.width))x\(Int(w.frame.height)) ax=\(Int(w.realFrame.width))x\(Int(w.realFrame.height)) "
                + "subrole=\(subrole) '\(w.displayTitle)'")
        }

        // Full candidate dump: EVERY layer-0 window owned by a regular app, with the metadata and
        // the element-resolution that drives listing — including windows that were DROPPED. This is
        // what reveals why a ghost with no AX element on any Space (e.g. ASUS GlideX) slips through
        // the off-Space metadata gate, by showing its CGS profile next to genuine windows.
        out.append("\n=== layer-0 candidate dump (regular apps; includes dropped) ===")
        out.append("legend: live=brute/current AX element resolved · cached=elementCache hit · "
            + "onscr=kCGWindowIsOnscreen · decision=what snapshot() does (AX-path requires live||cached)")
        var bruteByPid: [pid_t: Set<CGWindowID>] = [:]
        var currentByPid: [pid_t: Set<CGWindowID>] = [:]
        let sortedCandidates = spaceForWindow.sorted {
            $0.value.space != $1.value.space ? $0.value.space < $1.value.space : $0.key < $1.key
        }
        for (wid, placement) in sortedCandidates {
            guard let m = meta[wid], appsByPid.contains(m.pid), m.layer == 0 else { continue }
            let onCurrent = model.currentSpaceIDs.contains(placement.space)
            if onCurrent, currentByPid[m.pid] == nil {
                currentByPid[m.pid] = Set(currentSpaceElements(pid: m.pid).keys)
            }
            if !onCurrent, bruteByPid[m.pid] == nil {
                bruteByPid[m.pid] = Set(bruteForceWindows(pid: m.pid, includeNonStandard: bruteIncludesNonStandard(pid: m.pid)).map(\.0))
            }
            let live = onCurrent ? (currentByPid[m.pid]?.contains(wid) ?? false)
                                 : (bruteByPid[m.pid]?.contains(wid) ?? false)
            let cached = (elementCache[wid]).map { axCopy($0, kAXRoleAttribute as String) != nil } ?? false
            let b = m.bounds
            // AX-presence is the ghost discriminator: a window with neither a live nor a cached element
            // on any Space is a ghost and is dropped off-Space — every genuine window resolves one.
            let decision: String
            if live || cached { decision = "AX-path" }
            else if !onCurrent { decision = "drop(off-space,no-element)" }
            else { decision = "drop(current,no-element)" }
            let appName = NSRunningApplication(processIdentifier: m.pid)?.localizedName ?? "?"
            out.append("  wid \(wid) pid \(m.pid) sp \(placement.space) cur=\(onCurrent ? 1 : 0) "
                + "live=\(live ? 1 : 0) cached=\(cached ? 1 : 0) "
                + "alpha=\(m.alpha) onscr=\(m.isOnscreen ? 1 : 0) "
                + "\(Int(b.width))x\(Int(b.height))@\(Int(b.origin.x)),\(Int(b.origin.y)) "
                + "→ \(decision)  [\(appName)] '\(m.name ?? "")'")
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
        // One deadline for ALL per-app brute-force sweeps in this snapshot (see the off-Space
        // branch below) — bounds the gesture-open worst case regardless of how many apps hold
        // off-Space windows.
        let bruteForceDeadline = DispatchTime.now() + .milliseconds(250)

        // Backstop: re-assert the current frontmost app's focused window as most-recent before
        // ordering, so the current window is index 0 even if an earlier focus event did not resolve a
        // window id (e.g. some Electron/Chromium builds), and to self-heal any missed event.
        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let wid = focus.focusedWindowID(pid: frontPID) {
            focus.promote(wid)
        }

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

        // Prune the focus history to currently-enumerated window ids so closed windows don't linger
        // (ids are unique per window lifetime, so a stale id can never mis-rank a new window).
        focus.evict(keepingLive: Set(spaceForWindow.keys))
        mru.evict(keepingLive: Set(appsByPid.keys))

        let meta = metadata(for: Array(spaceForWindow.keys))

        // Per-snapshot AX element caches.
        var axCurrentByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]
        var axBruteByPid: [pid_t: [CGWindowID: AXUIElement]] = [:]

        var rows: [(window: WindowInfo, winRank: Int, appRank: Int, onCurrent: Bool, spaceIdx: Int, z: Int)] = []

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
                    // Aggregate brute-force budget across the WHOLE snapshot: each per-app sweep is
                    // budgeted (~100 ms of synchronous AX IPC worst case), but the number of apps
                    // holding off-Space windows grows over a long session, and N × 100 ms sits
                    // inline in the gesture-open path. Past the aggregate cap, remaining apps skip
                    // the sweep and resolve via `elementCache` (windows seen reachable before) —
                    // the next snapshot retries, so coverage self-heals across opens.
                    if DispatchTime.now() < bruteForceDeadline {
                        axBruteByPid[m.pid] = Dictionary(bruteForceWindows(pid: m.pid, includeNonStandard: bruteIncludesNonStandard(pid: m.pid)), uniquingKeysWith: { a, _ in a })
                    } else {
                        axBruteByPid[m.pid] = [:]
                    }
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

            // List a window only when an Accessibility element resolved — current-Space via
            // kAXWindowsAttribute, off-Space via remote-token brute force, or from the persistent
            // `elementCache` populated while the window was reachable. Requiring an element is
            // AltTab's 100%-Accessibility model: it drops off-Space "ghosts" (closed-but-process-
            // alive windows, dialog/sheets, background-agent surfaces) that expose no AX window on
            // any Space and that the former CoreGraphicsServices-metadata fallback could not tell
            // apart from a real window. Genuine off-Space windows — including Chromium reachable only
            // via a cached element (Bug A) — keep listing via `elementCache`. `isSwitchable` still
            // excludes minimized windows and non-standard subroles (dialogs/sheets).
            guard let element, isSwitchable(element) else { continue }

            let title = axString(element, kAXTitleAttribute as String)
                ?? m.name
                ?? (app.localizedName ?? "")

            let info = WindowInfo(
                id: wid,
                pid: m.pid,
                appName: app.localizedName ?? "",
                title: title,
                appIcon: app.icon,
                frame: m.bounds,
                realFrame: axFrame(element),
                axElement: element,
                isOnCurrentSpace: onCurrent,
                spaceID: placement.space,
                spaceIndex: model.indexBySpace[placement.space] ?? Int.max,
                // Only minimized windows that passed the relaxed gate reach here, so the flag is false unless
                // the opt-in is on; gating the AX read keeps the default (setting-off) hot path unchanged.
                isMinimized: settings.includeMinimizedWindows ? axBool(element, kAXMinimizedAttribute as String) : false
            )
            rows.append((info, focus.rank(wid), mru.rank(m.pid), onCurrent, model.indexBySpace[placement.space] ?? Int.max, placement.z))
        }

        // Evict cached elements for windows that no longer exist (keep only currently-enumerated ids).
        // `elementCache` is now the sole Bug-A guard, so this prune must stay correct.
        elementCache = elementCache.filter { spaceForWindow[$0.key] != nil }

        // Phantom-duplicate suppression (WindowFilter.dedupe, design D3): exact same-app clones —
        // identical title, integral real frame, and minimized state (the AirDrop send popup exposes
        // several per actual window) — collapse to the front-most (lowest z). `include`-rule apps
        // are exempt.
        rows = WindowFilter.dedupe(
            rows, exemptPids: includeRulePids(appsByPid.keys),
            key: { WindowFilter.DedupeKey(pid: $0.window.pid, title: $0.window.title,
                                          frame: $0.window.realFrame, isMinimized: $0.window.isMinimized) },
            rank: { $0.z })

        // Order by per-window focus recency (primary), falling back to current-Space → Space index →
        // z-order for never-focused windows. Routed through the pure `WindowOrdering` helper so the
        // sort key is unit-testable without AppKit/AX.
        WindowOrdering.sort(&rows) { r in
            WindowOrdering.Key(winRank: r.winRank, onCurrent: r.onCurrent, spaceIdx: r.spaceIdx, z: r.z, appRank: r.appRank, isMinimized: r.window.isMinimized)
        }
        var ordered = rows.map(\.window)

        // Include-minimized-windows opt-in: the CGS per-Space candidate set may omit minimized windows (they
        // are not composited), so relaxing `isSwitchable` alone can't surface them. Supplement with the
        // Dock-preview mechanism — read each app's `kAXWindowsAttribute` (which lists current-Space PLUS
        // minimized windows) and append any minimized window the snapshot missed, placed on the current
        // Space and after the live windows. This is the robust path for the core loop (a down-swipe
        // minimizes current-Space windows → they reappear here). Off-Space minimized windows appear only if
        // they already came through the CGS candidate set above (spike-dependent — acceptable v1).
        if settings.includeMinimizedWindows {
            let present = Set(ordered.map(\.id))
            let curSpace = model.currentSpaceIDs.first
            let curIndex = curSpace.flatMap { model.indexBySpace[$0] } ?? Int.max
            var extras: [(wid: CGWindowID, el: AXUIElement, app: NSRunningApplication)] = []
            for app in appsByPid.values {
                for (wid, el) in currentSpaceElements(pid: app.processIdentifier) {
                    guard !present.contains(wid),
                          axBool(el, kAXMinimizedAttribute as String),
                          isSwitchable(el) else { continue }
                    extras.append((wid, el, app))
                }
            }
            extras.sort { $0.wid < $1.wid }   // stable id order so re-lists don't restrobe (mirrors dockPreviewOrder)
            // Phantom clones can appear among the supplementary minimized windows too — collapse them
            // by the same identity key (stable id rank, since these have no z).
            extras = WindowFilter.dedupe(
                extras, exemptPids: includeRulePids(appsByPid.keys),
                key: { WindowFilter.DedupeKey(pid: $0.app.processIdentifier,
                                              title: axString($0.el, kAXTitleAttribute as String),
                                              frame: axFrame($0.el), isMinimized: true) },
                rank: { Int($0.wid) })
            if !extras.isEmpty {
                let extraMeta = metadata(for: extras.map(\.wid))
                for e in extras {
                    elementCache[e.wid] = e.el   // keep it resolvable at commit even if the app moves off-Space
                    let title = axString(e.el, kAXTitleAttribute as String) ?? extraMeta[e.wid]?.name ?? (e.app.localizedName ?? "")
                    ordered.append(WindowInfo(
                        id: e.wid, pid: e.app.processIdentifier, appName: e.app.localizedName ?? "",
                        title: title, appIcon: e.app.icon, frame: extraMeta[e.wid]?.bounds ?? .zero,
                        realFrame: axFrame(e.el), axElement: e.el, isOnCurrentSpace: true,
                        spaceID: curSpace, spaceIndex: curIndex, isMinimized: true
                    ))
                }
            }
        }
        return ordered
    }

    /// Legacy current-Space-only enumeration (today's behavior). Used when off-Space support is
    /// unavailable, so we never regress or crash.
    private func legacySnapshot() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let selfPid = getpid()
        var result: [(window: WindowInfo, winRank: Int, appRank: Int, z: Int)] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated
        }
        // A single running index across the whole enumeration so `z` is globally unique (like
        // snapshot()'s global z), keeping the appRank tiebreak unreachable on this path too.
        var z = 0
        for app in apps {
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            guard let axWindows = axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let appRank = mru.rank(pid)
            for axWin in axWindows {
                guard isSwitchable(axWin), let wid = axWindowID(axWin) else { continue }
                let info = WindowInfo(
                    id: wid, pid: pid, appName: app.localizedName ?? "",
                    title: axString(axWin, kAXTitleAttribute as String) ?? "",
                    appIcon: app.icon, frame: axFrame(axWin),
                    axElement: axWin, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0
                )
                result.append((info, focus.rank(wid), appRank, z))
                z += 1
            }
        }
        // Prune the focus history to the enumerated ids (parity with snapshot()), so closed windows
        // don't linger on the legacy fallback path.
        focus.evict(keepingLive: Set(result.map(\.window.id)))
        // Phantom-duplicate suppression, parity with snapshot() (frame here is the AX frame).
        result = WindowFilter.dedupe(
            result, exemptPids: includeRulePids(apps.map(\.processIdentifier)),
            key: { WindowFilter.DedupeKey(pid: $0.window.pid, title: $0.window.title,
                                          frame: $0.window.frame, isMinimized: $0.window.isMinimized) },
            rank: { $0.z })
        // Same window-rank-first key as snapshot(); here every window is current-Space at spaceIndex 0
        // and `z` is a global running index, so once recency is exhausted the order is the stable
        // enumeration order and the appRank tiebreak is unreachable.
        WindowOrdering.sort(&result) { r in
            WindowOrdering.Key(winRank: r.winRank, onCurrent: true, spaceIdx: 0, z: r.z, appRank: r.appRank)
        }
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

        // Switcher commit is the most authoritative focus source: promote immediately so this window
        // is index 0 on the next snapshot (covers same-app/current-Space raises that emit no
        // app-activation notification).
        focus.promote(window.id)

        focusSequence(window, offSpaceHandshake: !window.isOnCurrentSpace)

        // Instrument: record the commit and (cheaply) the focus state right after committing.
        let state = FocusLog.probe(targetPID: window.pid)
        logEntry(.commit, window: window, passed: nil, state: state, note: "")

        scheduleWatchdog(window, token: token, attempt: 0)
        // EVERY off-Space raise needs the polling hold-guard, not just under Stage Manager: a plain Space
        // switch also restores the destination's last-focused window ~300–500ms later and steals frontmost
        // (the "selected then deselected" race), and the single +180ms watchdog retires on its first
        // passing probe — BEFORE that steal — so nothing else recovers it. Stage Manager's WindowManager
        // re-steals repeatedly (full ~2.4s window); a plain switch steals once (shorter ~1.2s window, so we
        // don't fight a deliberate user switch-away for as long).
        if !window.isOnCurrentSpace {
            let maxTicks = StageManager.isEnabled ? offSpaceHoldTicks : offSpaceHoldShortTicks
            scheduleNextHoldTick(window, token: token, tick: 0, refronts: 0, maxTicks: maxTicks)
        }
    }

    // MARK: - Dock-preview variant (app-scoped, current-Space, minimized-inclusive)

    /// App-scoped, current-Space enumeration that — unlike `snapshot()` — **includes minimized windows**,
    /// each flagged via `WindowInfo.isMinimized`. Built for the Dock-hover preview popup; it does NOT
    /// touch the switcher's all-Spaces snapshot or its `isSwitchable` exclusion. Windows are ordered with
    /// non-minimized first (then by id) so the live ones lead the row. Returns `[]` when Accessibility is
    /// unavailable or the app has no current-Space windows (the popup then shows nothing).
    func currentSpaceWindows(forApp pid: pid_t) -> [WindowInfo] {
        guard AXIsProcessTrusted(), pid != getpid() else { return [] }
        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? ""
        let icon = app?.icon
        // kAXWindowsAttribute lists the app's current-Space windows INCLUDING minimized ones.
        let elements = currentSpaceElements(pid: pid)
        guard !elements.isEmpty else { return [] }
        let meta = metadata(for: Array(elements.keys))

        var result: [WindowInfo] = []
        for (wid, el) in elements {
            guard isPreviewable(el) else { continue }     // standard windows/dialogs, minimized INCLUDED
            let minimized = axBool(el, kAXMinimizedAttribute as String)
            let m = meta[wid]
            let title = axString(el, kAXTitleAttribute as String) ?? m?.name ?? appName
            // Cache the element so a later commit can resolve it even if the app moves off-Space.
            elementCache[wid] = el
            result.append(WindowInfo(
                id: wid, pid: pid, appName: appName, title: title, appIcon: icon,
                frame: m?.bounds ?? .zero, realFrame: axFrame(el), axElement: el,
                isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0, isMinimized: minimized
            ))
        }
        // Phantom-duplicate suppression, parity with the switcher snapshot (stable id rank — the
        // clones are visually indistinguishable, so any survivor is the right card).
        result = WindowFilter.dedupe(
            result, exemptPids: includeRulePids([pid]),
            key: { WindowFilter.DedupeKey(pid: $0.pid, title: $0.title,
                                          frame: $0.realFrame, isMinimized: $0.isMinimized) },
            rank: { Int($0.id) })
        return Self.dockPreviewOrder(result)
    }

    /// Order Dock-preview windows: non-minimized first (live windows lead the row), then a stable id
    /// order so re-lists don't restrobe. Pure + static so the ordering is unit-testable without AX/CGS.
    static func dockPreviewOrder(_ windows: [WindowInfo]) -> [WindowInfo] {
        windows.sorted { a, b in
            if a.isMinimized != b.isMinimized { return !a.isMinimized }
            return a.id < b.id
        }
    }

    /// Like `isSwitchable` but does NOT exclude minimized windows — the Dock preview wants them. Routes
    /// through the same `WindowFilter` (with minimized forced included), so the relaxed toggle and the
    /// per-app rules apply to the Dock popup exactly as they do to the switcher.
    private func isPreviewable(_ axWin: AXUIElement) -> Bool {
        var pol = axPid(axWin).map(policy(forPid:))
            ?? WindowFilterPolicy(relaxed: settings.includeNonStandardWindows, includeMinimized: true)
        pol.includeMinimized = true
        return WindowFilter.verdict(candidate(for: axWin), policy: pol) == .listed
    }

    /// Dock-preview commit: bring `window` to the front, **un-minimizing it first** if needed, then run
    /// the standard raise sequence (inheriting the watchdog / Stage-Manager hold-guard hardening of
    /// `raise`). Returns `false` when no AX element resolves (the window is gone) so the caller can
    /// surface `DockPreviewError.windowUnavailable` instead of a silent no-op.
    @discardableResult
    func raiseDeminimizing(_ window: WindowInfo) -> Bool {
        guard let el = resolveElement(window) else { return false }
        let wasMinimized = window.isMinimized || axBool(el, kAXMinimizedAttribute as String)
        guard wasMinimized else {
            raise(window)   // not minimized: raise immediately, exactly as before
            return true
        }
        // Clearing kAXMinimized deminiaturizes the window — a ~300ms genie that on its own fronts the
        // window. Raising / asserting focus WHILE it plays makes macOS re-composite the window (a visible
        // flash), and the +180ms watchdog would fire mid-genie and re-raise it (the "comes to front, then
        // flashes" symptom). So clear minimized now and defer the single hardened raise until the animation
        // settles: one clean front+focus, no mid-flight re-raise.
        AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        DispatchQueue.main.asyncAfter(deadline: .now() + deminimizeSettleDelay) { [weak self] in
            MainActor.assumeIsolated { self?.raise(window) }
        }
        return true
    }

    /// The current-Space, non-minimized, switchable windows (all regular apps) as `WindowInfo`, each with a
    /// resolvable `CGWindowID`. Used by the three-finger-down flow to CAPTURE these windows' live frames
    /// BEFORE `minimizeAllWindows()` runs, so the switcher can show each minimized window's real last-good
    /// frame instead of a bare app icon. (Windows without a `CGWindowID` are omitted from capture but are
    /// still minimized by `minimizeAllWindows()`, which is id-agnostic.) A tabbed window is one merged window
    /// here, so only that one live frame is captured — background tabs, which have no pixels of their own,
    /// keep the icon after they split on minimize (an accepted limitation of native window tabbing).
    func currentSpaceMinimizableWindows() -> [WindowInfo] {
        guard AXIsProcessTrusted() else { return [] }
        let selfPid = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated
        }
        var result: [WindowInfo] = []
        for app in apps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            guard let wins = axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            for el in wins {
                if axBool(el, kAXMinimizedAttribute as String) { continue }   // only currently-live windows can be captured
                guard isSwitchable(el), let wid = axWindowID(el) else { continue }
                let frame = axFrame(el)
                elementCache[wid] = el
                result.append(WindowInfo(
                    id: wid, pid: app.processIdentifier, appName: app.localizedName ?? "",
                    title: axString(el, kAXTitleAttribute as String) ?? (app.localizedName ?? ""),
                    appIcon: app.icon, frame: frame, realFrame: frame,
                    axElement: el, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0
                ))
            }
        }
        return result
    }

    /// Minimize every switchable window on the CURRENT Space — a real `kAXMinimized` write per window (into
    /// the Dock), revealing the desktop. This is a genuine minimize (Windows Win+D), NOT the native
    /// slide-aside "Show Desktop" (`com.apple.showdesktop.awake`): the windows go to the Dock and are
    /// recoverable via the switcher / ⌘-Tab (with the include-minimized-windows opt-in) or the Dock preview.
    /// It reuses the switcher's `isSwitchable` gate — excluding our own app, floating/non-standard surfaces,
    /// and windows already minimized (so it is idempotent) — and operates on the current Space only
    /// (`kAXWindowsAttribute` lists current-Space + minimized windows; the minimized ones are skipped, and
    /// off-Space windows are not returned). A single window's failed write does not block the rest. Returns
    /// `(minimized, failed)` counts so a caller has observable state rather than a silent success; nothing is
    /// surfaced as an app-modal alert.
    @discardableResult
    func minimizeAllWindows() -> (minimized: Int, failed: Int) {
        guard AXIsProcessTrusted() else { return (0, 0) }
        let selfPid = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated
        }
        var minimized = 0, failed = 0
        for app in apps {
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            guard let wins = axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            for el in wins {
                if axBool(el, kAXMinimizedAttribute as String) { continue }   // already minimized: idempotent skip
                guard isSwitchable(el) else { continue }                       // standard window gate; floating panels excluded by subrole
                let err = AXUIElementSetAttributeValue(el, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                if err == .success { minimized += 1 } else { failed += 1 }
            }
        }
        return (minimized, failed)
    }

    /// **Transient, reversible** front-raise for the Dock-preview peek: bring `window` to the front so
    /// macOS renders it **live** (an occluded/non-focused window yields no fresh pixels — Apple won't
    /// keep drawing what isn't the active surface). Crucially it makes THIS window the app's
    /// **focused/main** window, not merely raised: the Dock preview shows several windows of one app, and
    /// `kAXRaise` + `activate()` alone leaves the app still drawing its previously-focused window — so a
    /// capture of the merely-raised window stays stale (the bug: live preview only worked after a click,
    /// which set these singletons). Skipped under Stage Manager, where asserting the per-app focus
    /// singletons makes WindowManager's stage arbiter oscillate (the documented switcher landmine) — a
    /// peek there falls back to raise + activate. No focus-history promotion / watchdog / hold-guard
    /// (those fight a quick put-back); pair with `frontmostWindow()` to restore the prior window on leave.
    @discardableResult
    func peekRaise(_ window: WindowInfo) -> Bool {
        guard let el = resolveElement(window) else { return false }
        let stageManager = StageManager.isEnabled
        // RELIABLE cross-app front: the SkyLight `setFront` handshake fronts the process + this specific
        // window in one shot, so a BACKGROUND app actually becomes active and renders the window live.
        // `kAXRaise` + `activate()` alone often leaves a background app un-activated (that is why the
        // commit path needs a watchdog to retry until it sticks) — so its window stays throttled and the
        // capture comes back stale (the bug: a peek's live preview only worked for the app already in
        // front). We front it directly instead, no watchdog needed. Skipped under Stage Manager, where the
        // byte-protocol + focus singletons make WindowManager's stage arbiter oscillate (the documented
        // landmine); there a peek falls back to raise + activate.
        if !stageManager, cgs.offSpaceRaiseSupported,
           let getPSN = cgs.getProcessForPID, let setFront = cgs.setFrontProcessWithOptions {
            var psn = ProcessSerialNumber()
            if getPSN(window.pid, &psn) == 0, !(psn.highLongOfPSN == 0 && psn.lowLongOfPSN == 0) {
                _ = setFront(&psn, window.id, 0x200) // 0x200 = userGenerated
                _ = makeKeyWindow(psn, window.id)
            }
        }
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        if !stageManager {
            // Make THIS window the app's focused/main window (not merely raised) so the app draws it live —
            // an app with several windows otherwise keeps rendering its previously-focused window.
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
            let appEl = AXUIElementCreateApplication(window.pid)
            AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, el)
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        return true
    }

    /// Group commit (window-groups): raise a whole snapped-together group with the SELECTED member
    /// focused. Every mate is fronted first via the light front-without-commit mechanics of
    /// `peekRaise` — SkyLight handshake + AX raise + the focus singletons, NO focus-history promotion,
    /// NO watchdog (a second hardened raise would fight the selected member's), with the documented
    /// Stage-Manager fallback inside `peekRaise` — then the selected member goes through the ONE
    /// hardened `raise`, LAST, so topmost z-order, focus promotion, and the watchdog all land on it.
    /// Group members are same-Space by construction (edge adjacency implies one Space; a Space move
    /// dissolves membership), so no cross-Space machinery is engaged for the mates.
    func raiseGroup(mates: [WindowInfo], selected: WindowInfo) {
        for mate in mates {
            peekRaise(mate)
        }
        raise(selected)
    }

    /// The current frontmost window as a `WindowInfo`, captured BEFORE a peek begins so it can be
    /// re-fronted (restored) when the cursor leaves without committing. Resolves the frontmost app's
    /// focused window via Accessibility; nil when none resolves. Our overlay is non-activating, so the
    /// frontmost app here is the user's real app, not the popup.
    func frontmostWindow() -> WindowInfo? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedRef = axCopy(appEl, kAXFocusedWindowAttribute as String) else { return nil }
        let el = focusedRef as! AXUIElement
        guard let wid = axWindowID(el) else { return nil }
        return WindowInfo(
            id: wid, pid: app.processIdentifier, appName: app.localizedName ?? "",
            title: axString(el, kAXTitleAttribute as String) ?? "", appIcon: app.icon,
            frame: .zero, realFrame: axFrame(el), axElement: el,
            isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0
        )
    }

    /// Off-Space focus-hold guard tuning. After ANY off-Space raise the destination Space restores its
    /// own last-focused window ~300–500ms later and steals frontmost from the just-raised target (the
    /// "selected then deselected" race) — a key-less vacuum the +180ms watchdog is too early to see and
    /// never rechecks once a probe passes. So this polling guard is the real defense: rather than
    /// re-front at a fixed delay (a visible ~200ms flash), poll frequently and re-front the INSTANT the
    /// steal is detected (≈ one poll of flash). Under Stage Manager, WindowManager re-steals REPEATEDLY,
    /// so keep watching the full window; a plain Space switch steals ONCE, so a shorter window defeats it
    /// without fighting a deliberate user switch-away for as long. Bounded so a daemon that fights back
    /// can't make us thrash or loop.
    private let offSpaceHoldInterval: TimeInterval = 0.06   // detect the steal within ~one frame
    private let offSpaceHoldTicks = 40                      // Stage Manager: ~2.4s (repeated re-steals)
    private let offSpaceHoldShortTicks = 20                 // plain Space switch: ~1.2s (one-time steal)
    private let offSpaceHoldMaxRefronts = 6

    private func scheduleNextHoldTick(_ window: WindowInfo, token: UInt64, tick: Int, refronts: Int, maxTicks: Int) {
        guard tick < maxTicks else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + offSpaceHoldInterval) { [weak self] in
            MainActor.assumeIsolated {
                self?.offSpaceHoldTick(window, token: token, tick: tick, refronts: refronts, maxTicks: maxTicks)
            }
        }
    }

    private func offSpaceHoldTick(_ window: WindowInfo, token: UInt64, tick: Int, refronts: Int, maxTicks: Int) {
        guard token == commitSeq else { return }            // superseded by a newer commit
        let state = FocusLog.probe(targetPID: window.pid)
        if state.frontmostMatchesTarget && state.frontmostHasKeyWindow {
            scheduleNextHoldTick(window, token: token, tick: tick + 1, refronts: refronts, maxTicks: maxTicks)
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
        scheduleNextHoldTick(window, token: token, tick: tick + 1, refronts: refronts + 1, maxTicks: maxTicks)
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
            if let el = bruteForceWindows(pid: window.pid, includeNonStandard: bruteIncludesNonStandard(pid: window.pid)).first(where: { $0.0 == window.id })?.1 { return el }
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
            let isOnscreen = (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? NSDictionary {
                bounds = CGRect(dictionaryRepresentation: b as CFDictionary) ?? .zero
            }
            map[wid] = CGMeta(pid: pid, layer: layer, alpha: alpha, bounds: bounds, name: name, isOnscreen: isOnscreen)
        }
        return map
    }

    // MARK: - Switchability (the pure filter's AX boundary)

    /// Gather the observable AX facts for one window element — the boundary read for the pure
    /// `WindowFilter` (design D1). Size is the AX (real) size, so a Stage-Manager strip proxy —
    /// small in CGWindowList bounds but really large — is measured by its true size and not
    /// mistaken for a helper window.
    private func candidate(for axWin: AXUIElement) -> WindowCandidate {
        WindowCandidate(
            role: axString(axWin, kAXRoleAttribute as String),
            subrole: axString(axWin, kAXSubroleAttribute as String),
            title: axString(axWin, kAXTitleAttribute as String),
            size: axFrame(axWin).size,
            hasCloseButton: axCopy(axWin, kAXCloseButtonAttribute as String) != nil,
            isMinimized: axBool(axWin, kAXMinimizedAttribute as String)
        )
    }

    /// The per-app rule key: bundle ID, falling back to executable name (Qt/CLI-hosted apps like the
    /// Android emulator can lack a bundle ID). Cached per pid — bounded by the process count over the
    /// app's lifetime, and pid reuse across launches is rare enough that a stale hit is harmless (the
    /// key is only a dictionary lookup into the user's rules).
    private var bundleKeyByPid: [pid_t: String] = [:]
    func bundleKey(for pid: pid_t) -> String {
        if let cached = bundleKeyByPid[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let key = app?.bundleIdentifier ?? app?.executableURL?.lastPathComponent ?? "pid-\(pid)"
        bundleKeyByPid[pid] = key
        return key
    }

    /// The filter policy for an app: the two global toggles plus the user's per-app rule (if any).
    private func policy(forPid pid: pid_t) -> WindowFilterPolicy {
        WindowFilterPolicy(relaxed: settings.includeNonStandardWindows,
                           includeMinimized: settings.includeMinimizedWindows,
                           appRule: settings.windowAppRules[bundleKey(for: pid)])
    }

    /// The pids whose `include` rule exempts them from phantom-duplicate suppression (design D3).
    private func includeRulePids<S: Sequence>(_ pids: S) -> Set<pid_t> where S.Element == pid_t {
        guard !settings.windowAppRules.isEmpty else { return [] }
        return Set(pids.filter { settings.windowAppRules[bundleKey(for: $0)] == .include })
    }

    private func axPid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// Whether the acquisition pre-filter in `bruteForceWindows` should accept any window-role
    /// element for this pid: the global relaxed toggle, or the app's `include` rule (else an
    /// off-Space window of an `include` app could never be acquired under a strict global).
    private func bruteIncludesNonStandard(pid: pid_t) -> Bool {
        settings.includeNonStandardWindows || policy(forPid: pid).appRule == .include
    }

    /// The switchability gate — routed through the pure `WindowFilter` (see its doc for the tiers).
    /// `minimizeAllWindows()` skips already-minimized windows BEFORE this gate, so admitting
    /// minimized windows here never re-minimizes one.
    private func isSwitchable(_ axWin: AXUIElement) -> Bool {
        let pol = axPid(axWin).map(policy(forPid:))
            ?? WindowFilterPolicy(relaxed: settings.includeNonStandardWindows,
                                  includeMinimized: settings.includeMinimizedWindows)
        return WindowFilter.verdict(candidate(for: axWin), policy: pol) == .listed
    }

    // MARK: - Window Inspector

    /// The Hub Window Inspector's data (design D5): every regular app's current-Space window
    /// candidates with the verdict the switcher's own filter produced, plus dedup marking — the same
    /// `WindowFilter` drives both, so the inspector and the switcher can never disagree. Current-
    /// Space-only on purpose: the inspector answers questions about windows the user is looking at
    /// ("why isn't this listed?", "why four cards?"); off-Space ghost forensics stays with
    /// `diagnosticReport()`. On-demand only — the Hub refreshes on explicit action, never a timer.
    func inspectorSnapshot() -> [WindowInspectorEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let selfPid = getpid()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPid && !$0.isTerminated }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        var entries: [WindowInspectorEntry] = []
        var frames: [CGWindowID: CGRect] = [:]
        for app in apps {
            let pid = app.processIdentifier
            let pol = policy(forPid: pid)
            for (wid, el) in currentSpaceElements(pid: pid).sorted(by: { $0.key < $1.key }) {
                let c = candidate(for: el)
                frames[wid] = axFrame(el)
                entries.append(WindowInspectorEntry(
                    id: wid, pid: pid, appKey: bundleKey(for: pid), appName: app.localizedName ?? "",
                    appIcon: app.icon, title: c.title ?? "", subrole: c.subrole, size: c.size,
                    isMinimized: c.isMinimized, verdict: WindowFilter.verdict(c, policy: pol)))
            }
        }
        // Mark the dedup losers among the listed entries — the same suppression the snapshot applies.
        let listed = entries.filter { $0.verdict == .listed }
        let survivors = Set(WindowFilter.dedupe(
            listed, exemptPids: includeRulePids(apps.map(\.processIdentifier)),
            key: { WindowFilter.DedupeKey(pid: $0.pid, title: $0.title,
                                          frame: frames[$0.id] ?? .zero, isMinimized: $0.isMinimized) },
            rank: { Int($0.id) }).map(\.id))
        return entries.map { entry in
            var entry = entry
            entry.dedupedOut = entry.verdict == .listed && !survivors.contains(entry.id)
            return entry
        }
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

/// One row of the Hub Window Inspector (design D5): a current-Space window candidate with the
/// verdict the switcher's own filter produced for it, and whether phantom-duplicate suppression
/// would drop it. Built by `WindowService.inspectorSnapshot()`.
struct WindowInspectorEntry: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    /// The per-app rule key (bundle ID or executable name) — what a rule edit writes under.
    let appKey: String
    let appName: String
    let appIcon: NSImage?
    let title: String
    let subrole: String?
    let size: CGSize
    let isMinimized: Bool
    let verdict: WindowFilterVerdict
    /// Listed by the filter but suppressed as an exact clone of another listed window.
    var dedupedOut: Bool = false
}
