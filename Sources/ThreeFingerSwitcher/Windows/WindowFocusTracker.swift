import AppKit
import ApplicationServices

/// Per-window most-recently-focused ordering, keyed by `CGWindowID`. Replaces app-MRU as the
/// switcher's primary sort key: windows interleave across apps by true focus recency, so a short
/// flick lands on the previously focused window regardless of which app owns it.
///
/// Recency is fed from every focus source, not just the switcher's own commits, so the last- and
/// second-last-focused windows are always right:
///   (a) switcher commit  — `WindowService.raise` promotes the chosen window directly,
///   (b) app activation    — on `didActivateApplicationNotification`, resolve the new frontmost
///       app's focused window and promote it (Cmd-Tab, cross-app clicks),
///   (c) external within-app focus — a live `AXObserver` on the FRONTMOST APP ONLY listens for
///       focused/main-window changes (clicking another window, `Cmd-\``, Mission Control picks)
///       and promotes the new focused window. The observer follows the frontmost app (retargeted
///       on each activation), so there is one observer, not N across all apps.
///
/// Ephemeral (in-memory, resets on relaunch), matching app-MRU. With Accessibility absent, tracking
/// degrades to sources (a)+(b) with no error and no new permission prompt.
@MainActor
final class WindowFocusTracker {
    /// Window ids in most-recently-used order (front of array = most recent).
    private(set) var order: [CGWindowID] = []

    /// App-activation observer (always installed; activation is the cheap, AX-free source).
    private var activationObserver: NSObjectProtocol?

    /// Live AX focused-window observer on the current frontmost app, plus the pid it targets, so a
    /// retarget can tear down the old run-loop source before installing the new one.
    private var axObserver: AXObserver?
    private var axObservedPID: pid_t?

    func start() {
        // Idempotent: a second start() without an intervening stop() would leak the activation
        // observer — the no-trackpad toggle path can re-enter enable() without disable() tearing down.
        guard activationObserver == nil else { return }
        // Seed with the current frontmost app's focused window, then follow it with the AX observer.
        if let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            if let wid = focusedWindowID(pid: pid) { promote(wid) }
            retargetObserver(to: pid)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let pid = app.processIdentifier
                if let wid = self.focusedWindowID(pid: pid) { self.promote(wid) }
                self.retargetObserver(to: pid)
            }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        teardownObserver()
    }

    deinit {
        // `focus` lives for the whole process so this rarely runs, but the AX run-loop source is
        // installed with an unretained refcon (`passUnretained`) — drop it before the tracker dies so
        // a late focus-change callback can never dereference freed memory.
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
    }

    /// Move `wid` to the front (most recent). Idempotent — a re-promote of the already-front window
    /// leaves the list unchanged.
    func promote(_ wid: CGWindowID) {
        order.removeAll { $0 == wid }
        order.insert(wid, at: 0)
    }

    /// Rank for a window id; lower is more recent. Unknown ids sort after all known ones.
    func rank(_ wid: CGWindowID) -> Int {
        order.firstIndex(of: wid) ?? Int.max
    }

    /// Prune the history to the given set of live window ids, so closed windows don't linger (ids
    /// are unique per window lifetime, so a stale id can never mis-rank a new window).
    func evict(keepingLive live: Set<CGWindowID>) {
        order.removeAll { !live.contains($0) }
    }

    /// Resolve an application's focused window id via Accessibility:
    /// `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `axWindowID`. Returns
    /// `nil` when unresolvable (no AX trust, no focused window, or no resolvable id).
    func focusedWindowID(pid: pid_t) -> CGWindowID? {
        guard pid != getpid(), AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        guard let raw = axCopy(appEl, kAXFocusedWindowAttribute as String) else { return nil }
        let element = raw as! AXUIElement
        return axWindowID(element)
    }

    // MARK: - AX focused-window observer (frontmost app only)

    /// Point the live AX observer at `pid` (the new frontmost app), tearing down the previous one.
    /// No-op without AX trust (the degraded mode keeps commit + activation sources only). Guarded by
    /// the observed pid so a duplicate activation for the same app does not churn the observer.
    private func retargetObserver(to pid: pid_t) {
        guard AXIsProcessTrusted(), pid != getpid() else { teardownObserver(); return }
        guard pid != axObservedPID else { return }
        teardownObserver()

        var observer: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, focusObserverCallback, &observer) == .success,
              let observer else { return }
        let appEl = AXUIElementCreateApplication(pid)
        // Both notifications cover an external within-app focus change; either may fire depending on
        // the app. Promote is idempotent, so a double-fire is harmless.
        AXObserverAddNotification(observer, appEl, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, appEl, kAXMainWindowChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axObservedPID = pid
    }

    /// Remove the current observer's run-loop source and drop it.
    private func teardownObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        axObservedPID = nil
    }

    /// Called from the C callback (bounced to the main actor): re-resolve the frontmost app's
    /// focused window and promote it. Guarded by the observed pid so a stale event from a just-torn
    /// observer is ignored.
    fileprivate func handleFocusedWindowChanged(pid: pid_t) {
        guard pid == axObservedPID, let wid = focusedWindowID(pid: pid) else { return }
        promote(wid)
    }
}

/// C callback for `AXObserverCreate`. Bridge the tracker through the `refcon` context pointer and
/// hop to the main actor (the tracker is `@MainActor`); the run-loop source is on the main run loop.
private func focusObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowFocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    MainActor.assumeIsolated {
        tracker.handleFocusedWindowChanged(pid: pid)
    }
}
