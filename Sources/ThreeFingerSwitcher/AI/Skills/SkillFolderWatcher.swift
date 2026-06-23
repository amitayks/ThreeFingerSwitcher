import Foundation

/// A pure coalescing gate for rapid folder-change events (testable with a manual `now:` clock — the
/// live `DispatchSource` firing is user-run-verify, this decides WHEN a burst collapses into one
/// reload). Each raw event arms a window; a reload is due only once the window has settled (no newer
/// event within `interval`). This collapses a save-storm (an editor writing a temp file, renaming,
/// touching mtimes) into a single off-main `loadAll()`.
struct ReloadCoalescer: Sendable {
    /// The quiet window a burst must settle for before a reload fires.
    let interval: TimeInterval

    init(interval: TimeInterval = 0.25) { self.interval = interval }

    /// Given the timestamp of the latest raw event and the moment we are evaluating, is the burst
    /// settled (i.e. should a reload fire now)? Deterministic — the watcher schedules a check at
    /// `lastEvent + interval` and asks this; a newer event pushes `lastEvent` forward so the earlier
    /// check declines and the burst keeps collapsing.
    func isSettled(lastEvent: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastEvent) >= interval - 1e-9
    }
}

/// A live user-folder watcher for the Skills directory (task 4.4). Wraps a
/// `DispatchSource.makeFileSystemObjectSource` on the folder's file descriptor; rapid changes are
/// COALESCED (via `ReloadCoalescer`) and a single re-`loadAll()` runs off-main, republishing the
/// fresh `SkillLoadResult` on the main actor. Built-in skills are projected in-memory (loaded once),
/// so only the user folder needs watching. `loadAll()` is idempotent, so a re-call simply picks up
/// the new/edited/removed files.
///
/// The live FS-event firing is user-run-verify in a stable-signed build; the coalesced-reload path is
/// exercised by `triggerReloadForTesting()` (a manual trigger that runs the exact republish closure).
final class SkillFolderWatcher: @unchecked Sendable {
    private let store: SkillStore
    private let folder: URL
    private let coalescer: ReloadCoalescer
    private let onReload: @Sendable (SkillLoadResult) -> Void
    private let queue = DispatchQueue(label: "com.threefingerswitcher.skill-watcher")

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var lastEvent: Date = .distantPast
    private var pending = false

    /// - Parameters:
    ///   - store: the store re-`loadAll()`ed on a settled burst.
    ///   - coalescer: the quiet-window gate (defaults to 0.25s).
    ///   - onReload: republish sink, always invoked on the main actor with the fresh result.
    init(store: SkillStore,
         coalescer: ReloadCoalescer = ReloadCoalescer(),
         onReload: @escaping @Sendable (SkillLoadResult) -> Void) {
        self.store = store
        self.folder = store.userFolder
        self.coalescer = coalescer
        self.onReload = onReload
    }

    deinit { stop() }

    /// Begin watching. Creates the user folder if absent (so the fd open succeeds), then arms a
    /// vnode source on it. A write/delete/rename/extend/attribute change re-arms the coalescer.
    func start() {
        queue.sync {
            guard self.source == nil else { return }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let fd = open(self.folder.path, O_EVTONLY)
            guard fd >= 0 else { return }   // can't open → no watch (idle, not a crash)
            self.fileDescriptor = fd
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: self.queue)
            src.setEventHandler { [weak self] in self?.handleRawEvent() }
            src.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.fileDescriptor >= 0 { close(self.fileDescriptor); self.fileDescriptor = -1 }
            }
            self.source = src
            src.resume()
        }
    }

    /// Stop watching and release the fd. Idempotent.
    func stop() {
        queue.sync {
            self.source?.cancel()
            self.source = nil
        }
    }

    // MARK: - Coalesced reload

    /// A raw FS event: stamp it and schedule a settle check one window out. (Runs on `queue`.)
    private func handleRawEvent() {
        let now = Date()
        lastEvent = now
        pending = true
        queue.asyncAfter(deadline: .now() + coalescer.interval) { [weak self] in
            self?.checkSettled(scheduledFor: now)
        }
    }

    /// One window after a raw event: if no newer event arrived (the burst settled), reload. (On `queue`.)
    private func checkSettled(scheduledFor eventTime: Date) {
        guard pending, coalescer.isSettled(lastEvent: lastEvent, now: Date()) else { return }
        pending = false
        runReload()
    }

    /// Re-`loadAll()` off-main and republish on the main actor. Shared by the live path and the test
    /// trigger so the coalesced-reload path is exercised without a live FS event.
    private func runReload() {
        let store = self.store
        let onReload = self.onReload
        Task.detached {
            let result = await store.loadAll()
            await MainActor.run { onReload(result) }
        }
    }

    /// Manually drive the coalesced-reload path (the live FS-event firing is user-run-verify). Runs the
    /// exact off-main reload + main-actor republish the watcher would run for a settled burst.
    func triggerReloadForTesting() {
        queue.sync { self.pending = false }
        runReload()
    }
}
