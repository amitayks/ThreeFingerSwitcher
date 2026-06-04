import AppKit

/// Best-effort most-recently-used ordering of applications by observing activations.
/// Window-level MRU is approximated as app-MRU + per-app AX z-order (see WindowService).
@MainActor
final class MRUTracker {
    /// pids in most-recently-used order (front of array = most recent).
    private(set) var order: [pid_t] = []

    private var observer: NSObjectProtocol?

    func start() {
        // Seed with the current frontmost app.
        if let front = NSWorkspace.shared.frontmostApplication {
            promote(front.processIdentifier)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.promote(app.processIdentifier) }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }

    func promote(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    /// Rank for a pid; lower is more recent. Unknown pids sort after all known ones.
    func rank(_ pid: pid_t) -> Int {
        order.firstIndex(of: pid) ?? Int.max
    }
}
