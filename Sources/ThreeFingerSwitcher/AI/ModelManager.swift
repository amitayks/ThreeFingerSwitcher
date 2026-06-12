import Foundation
import Combine
import CryptoKit

/// Observable lifecycle of a model's weights (spec: "Model lifecycle management"). The UI binds to
/// this so loading is a visible state, never a silent block (design D4): a preview surface shows
/// `.downloading` / `.verifying` / `.loading` rather than freezing.
public enum ModelLifecycleState: Equatable, Sendable {
    /// Weights are not on disk yet (and no download in flight).
    case notDownloaded
    /// Download in flight; `progress` is 0...1.
    case downloading(progress: Double)
    /// Download complete; integrity (SHA) check in progress.
    case verifying
    /// Verified and on disk, not yet loaded into the runtime.
    case ready
    /// Lazy-loading the verified weights into the runtime.
    case loading
    /// Resident in the runtime, ready to serve calls (kept resident between calls).
    case loaded
    /// A terminal failure for this attempt (corrupt download, unavailable hardware, …). `reason` is the
    /// clean, user-facing headline the UI surfaces (with a retry affordance); `details` is optional raw
    /// technical text for an opt-in "Show details / Copy" disclosure — never shown inline (design D4).
    /// Both are produced by the central `AIError` translator at the failure site; `reason` must never
    /// be a raw error dump (spec: "No raw error text in user-facing strings").
    case failed(reason: String, details: String? = nil)
}

/// Injectable download seam so tests use a fake — NO real network ever enters `swift test` (the
/// design's hard rule). A real conformer (deferred) streams bytes from `descriptor.downloadURL` to
/// `destination`, resumably; the fake fabricates bytes deterministically.
public protocol ModelDownloading: Sendable {
    /// Download `descriptor`'s weights to `destination`, reporting fractional progress (0...1).
    /// Returns the raw bytes written (so the manager can verify integrity without re-reading disk in
    /// tests). Must honor Task cancellation.
    func download(
        _ descriptor: ModelDescriptor,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Data
}

/// Owns a model's lifecycle end-to-end: gates download on the opt-in, verifies integrity before any
/// load, lazy-loads on first use, keeps the runtime resident between calls, and evicts on demand /
/// when the opt-in is turned off. Resolves an `LLMRuntime` (the stub for now; the real conformer is
/// swapped in via `runtimeFactory` without changing callers).
///
/// `@MainActor` to match the project's observable-state convention (`AppSettings`, `ClipboardStore`).
@MainActor
public final class ModelManager: ObservableObject {

    /// A real-runtime provisioner: it owns BOTH the download (via the model pipeline / HF Hub) and the
    /// load, returning a ready-to-serve `LLMRuntime`. When injected, it reconciles the manager's
    /// lifecycle with a pipeline that does its own HF-Hub download+load: `downloadAndVerify` drives
    /// `.downloading(progress:)` from the provisioner's progress callback, then stores the returned
    /// runtime and settles `.loaded` — BYPASSING the bytes + SHA + `runtimeFactory` path entirely
    /// (the Hub/pipeline verifies integrity). `progress` reports a 0…1 fraction on an arbitrary thread.
    public typealias ModelProvisioner = @MainActor (
        _ descriptor: ModelDescriptor,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LLMRuntime

    /// Observable lifecycle for the UI.
    @Published public private(set) var state: ModelLifecycleState = .notDownloaded

    /// Whether the AI-commands feature is opted in. While OFF: no download may start, and any
    /// resident model is evicted (spec: "No download until opt-in"; design D7 rollback).
    @Published public private(set) var optedIn: Bool {
        didSet {
            guard optedIn != oldValue else { return }
            if !optedIn {
                // Turning the opt-in off evicts immediately and forgets any download progress.
                evict()
                state = .notDownloaded
            }
        }
    }

    public let registry: ModelRegistry
    private let downloader: ModelDownloading
    /// Builds the `LLMRuntime` for a verified descriptor. Injectable so tests resolve a `StubLLMRuntime`
    /// and the real slice swaps in `GemmaMLXRuntime` without touching this type.
    private let runtimeFactory: @Sendable (ModelDescriptor) throws -> LLMRuntime
    /// Whether this machine can serve the model at all. Injectable so the strong-hardware-only guard is
    /// testable; the real conformer probes Metal/RAM. Default: capable.
    private let hardwareSupports: @Sendable (ModelDescriptor) -> Bool
    /// When set, the real-runtime path: download+load are delegated to this (see `ModelProvisioner`),
    /// and the byte-SHA + `runtimeFactory` path is bypassed. nil → the existing dev-stub path.
    private let provisioner: ModelProvisioner?
    /// Whether a descriptor's weights are ALREADY present on disk for the provisioner (real-runtime)
    /// path — a pure, network-free filesystem probe. Injected by the backend (e.g. `GemmaRuntime`
    /// checks `Gemma4ModelCache`), since Core doesn't know a backend's on-disk cache layout. Lets the
    /// manager rediscover a previously-downloaded model on launch (`reconcileWithDisk`) and lazy-LOAD
    /// it on first use WITHOUT a re-download. Default: `false` (the dev-stub/byte path proves presence
    /// via `verifiedBytes`, not this probe).
    private let provisionedOnDisk: @Sendable (ModelDescriptor) -> Bool
    /// Delete a descriptor's on-disk weights on the provisioner (real-runtime) path — the HF-cache dir
    /// the runtime actually loads from. Injected by the backend (Core doesn't know the cache layout),
    /// mirroring `provisionedOnDisk`. Without it a delete would remove the wrong (app-support) dir and
    /// the model would re-discover as "Downloaded". Default: no-op (the dev/byte path removes its own
    /// `storageRoot` weights, which need no backend knowledge).
    private let provisionedDelete: @Sendable (ModelDescriptor) -> Void

    private let storageRoot: URL

    /// The resident runtime once loaded; nil means not loaded (notDownloaded/ready/evicted).
    private var residentRuntime: LLMRuntime?
    /// The descriptor actually resident in `residentRuntime`. Decoupled from `activeDescriptor` because
    /// the latter follows the user's *displayed* selection (via `showStatus`) and may point at a
    /// different model than the one loaded in memory — eviction/delete must act on the resident one.
    private var residentDescriptor: ModelDescriptor?
    /// The descriptor the displayed `state` currently describes (the on-screen / selected model).
    private var activeDescriptor: ModelDescriptor?
    /// Verified-on-disk weight bytes, kept so a subsequent load doesn't re-download (residency test).
    /// Unused on the provisioner path (the pipeline owns the weights on disk).
    private var verifiedBytes: Data?

    public init(registry: ModelRegistry = .standard,
                downloader: ModelDownloading,
                optedIn: Bool = false,
                storageRoot: URL? = nil,
                hardwareSupports: @escaping @Sendable (ModelDescriptor) -> Bool = { _ in true },
                provisioner: ModelProvisioner? = nil,
                provisionedOnDisk: @escaping @Sendable (ModelDescriptor) -> Bool = { _ in false },
                provisionedDelete: @escaping @Sendable (ModelDescriptor) -> Void = { _ in },
                runtimeFactory: @escaping @Sendable (ModelDescriptor) throws -> LLMRuntime = { descriptor in
                    StubLLMRuntime(capabilities: descriptor.capabilities)
                }) {
        self.registry = registry
        self.downloader = downloader
        self.optedIn = optedIn
        self.storageRoot = storageRoot ?? Self.defaultStorageRoot()
        self.hardwareSupports = hardwareSupports
        self.provisioner = provisioner
        self.provisionedOnDisk = provisionedOnDisk
        self.provisionedDelete = provisionedDelete
        self.runtimeFactory = runtimeFactory
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/models`.
    public static func defaultStorageRoot() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/models", isDirectory: true)
    }

    // MARK: - Opt-in

    /// Set the opt-in. Turning it OFF evicts and resets state (privacy + frees weights from residency).
    public func setOptedIn(_ value: Bool) {
        optedIn = value
    }

    // MARK: - On-disk rediscovery

    /// Rediscover a model whose weights are already present on disk (provisioner/real-runtime path) and
    /// settle to `.ready` — "downloaded, not yet loaded" — so a relaunch (or re-enabling the opt-in)
    /// does NOT ask the user to "Download" again. The heavy MLX load still happens lazily on first use
    /// (`runtime(requiring:)`/`loadIfNeeded`), so this never fetches bytes or loads weights — it is a
    /// pure disk probe + a state settle, safe to call at launch.
    ///
    /// No-op when: not opted in, no provisioner (dev/byte path), a runtime is already resident, a
    /// download/verify/load is in flight, or nothing matching is on disk.
    public func reconcileWithDisk() {
        guard optedIn, provisioner != nil, residentRuntime == nil else { return }
        switch state {
        // Don't disturb an in-flight or already-resolved lifecycle.
        case .downloading, .verifying, .loading, .loaded: return
        case .notDownloaded, .ready, .failed: break
        }
        // Settle the DEFAULT descriptor for the UI's single status row. If a later command needs a
        // different-capability model, `runtime(requiring:)` re-probes the selected descriptor and
        // adopts it (loading it if it too is on disk), so this default is only the resting display.
        guard let descriptor = registry.defaultDescriptor ?? registry.models.first,
              provisionedOnDisk(descriptor) else { return }
        activeDescriptor = descriptor
        verifiedBytes = nil   // the pipeline owns the on-disk weights on this path
        state = .ready
    }

    // MARK: - Per-model display status

    /// Re-settle the DISPLAYED lifecycle (`state`) to reflect `descriptor` — the user's current model
    /// selection — so the status row tracks the picker instead of whichever model was last active (the
    /// single `state` is otherwise shared, so switching the picker would keep showing the old model's
    /// status). Shows `.loaded` when `descriptor` is the resident model, `.ready` when its weights are on
    /// disk, else `.notDownloaded`. Never disturbs an in-flight download/verify/load (its progress must
    /// keep showing) and only acts while opted in. A pure disk probe — safe to call on selection change /
    /// when the AI page appears.
    public func showStatus(for descriptor: ModelDescriptor) {
        guard optedIn else { return }
        switch state {
        case .downloading, .verifying, .loading: return
        case .notDownloaded, .ready, .loaded, .failed: break
        }
        if residentRuntime != nil, residentDescriptor?.id == descriptor.id {
            activeDescriptor = descriptor
            state = .loaded
            return
        }
        let onDisk = isOnDisk(descriptor)   // probe BEFORE repointing (the byte path keys off activeDescriptor)
        activeDescriptor = descriptor
        state = onDisk ? .ready : .notDownloaded
    }

    /// Whether `descriptor`'s weights are present on disk: the per-descriptor probe on the provisioner
    /// (real-runtime) path; on the dev/byte path, the held `verifiedBytes` for the active descriptor.
    private func isOnDisk(_ descriptor: ModelDescriptor) -> Bool {
        if provisioner != nil { return provisionedOnDisk(descriptor) }
        return verifiedBytes != nil && activeDescriptor?.id == descriptor.id
    }

    // MARK: - Delete (remove weights from disk)

    /// Delete `descriptor`'s weights from disk and evict it if it is the resident model, so it reads as
    /// `.notDownloaded` again (a re-acquire is a fresh download). Removes BOTH the dev/byte weights
    /// (`storageRoot/<id>`) and — via the injected `provisionedDelete` — the provisioner's on-disk copy
    /// (the HF-cache dir the real runtime loads from). The displayed `state` resets only when the deleted
    /// model is the one currently on screen.
    public func deleteFromDisk(_ descriptor: ModelDescriptor) {
        if residentDescriptor?.id == descriptor.id {
            residentRuntime = nil
            residentDescriptor = nil
        }
        try? FileManager.default.removeItem(
            at: storageRoot.appendingPathComponent(descriptor.id, isDirectory: true))
        provisionedDelete(descriptor)
        if activeDescriptor?.id == descriptor.id {
            verifiedBytes = nil
            state = .notDownloaded
        }
    }

    /// Delete every known model's weights from disk and drop residency — the Danger zone's "AI models"
    /// wipe. Removes both on-disk paths for each registry model; afterwards the manager is
    /// `.notDownloaded` with nothing resident.
    public func deleteAllFromDisk() {
        residentRuntime = nil
        residentDescriptor = nil
        verifiedBytes = nil
        for descriptor in registry.models {
            try? FileManager.default.removeItem(
                at: storageRoot.appendingPathComponent(descriptor.id, isDirectory: true))
            provisionedDelete(descriptor)
        }
        activeDescriptor = nil
        state = .notDownloaded
    }

    // MARK: - Download + verify

    /// Download and integrity-verify a descriptor's weights. Refuses while the opt-in is off (no
    /// weights are fetched). On a SHA mismatch the model is rejected as `.failed` and never loaded; the
    /// caller is expected to surface a retry.
    public func downloadAndVerify(_ descriptor: ModelDescriptor) async throws {
        guard optedIn else {
            // Hard rule: no download until opt-in. State is unchanged; this is not a failure of the
            // model, just a gated action.
            throw RuntimeError.unavailable(reason: "AI commands opt-in is off; no model download permitted")
        }
        guard hardwareSupports(descriptor) else {
            state = .failed(reason: "This Mac cannot run \(descriptor.displayName)")
            throw RuntimeError.unavailable(reason: "Unsupported hardware for \(descriptor.id)")
        }

        // Real-runtime path: the provisioner owns download (via the model pipeline / HF Hub) AND
        // load. We drive `.downloading(progress:)` from its callback, then store the ready runtime and
        // settle `.loaded` — the bytes + SHA + `runtimeFactory` path is bypassed (the Hub verifies).
        if let provisioner {
            try await runProvisioner(descriptor, provisioner: provisioner, mode: .download)
            return
        }

        let destination = weightsURL(for: descriptor)
        state = .downloading(progress: 0)
        let bytes: Data
        do {
            bytes = try await downloader.download(descriptor, to: destination) { [weak self] p in
                Task { @MainActor in self?.state = .downloading(progress: min(max(p, 0), 1)) }
            }
        } catch is CancellationError {
            state = .notDownloaded
            throw RuntimeError.cancelled
        } catch {
            // Without this generic catch a non-cancel download error would leave the state stuck at
            // `.downloading` forever (spec: "Failure is an observable state that never stalls"). Settle
            // `.failed` with a clean headline, symmetric with the provisioner path above.
            let presented = AIError.message(for: error)
            state = .failed(reason: presented.headline, details: presented.details)
            throw error
        }

        // Integrity check BEFORE the weights are eligible for load.
        state = .verifying
        guard Self.sha256Hex(bytes) == descriptor.integritySHA else {
            // Corrupt → failed, never loaded. Drop the bad bytes; the user must retry.
            verifiedBytes = nil
            activeDescriptor = nil
            state = .failed(reason: "Integrity check failed for \(descriptor.displayName); re-download required")
            throw RuntimeError.integrityFailed
        }

        verifiedBytes = bytes
        activeDescriptor = descriptor
        state = .ready
    }

    /// Whether the provisioner is being used to DOWNLOAD-then-load (first acquisition) or to LOAD an
    /// already-on-disk model (rediscovery). The difference is purely how state is surfaced: a download
    /// drives `.downloading(progress:)`; a load shows `.loading` and ignores the (no-op) download
    /// progress, because the resumable downloader skips the complete files — no bytes are fetched.
    private enum ProvisionMode { case download, load }

    /// Run the real-runtime provisioner (download+load, or load-only when already on disk), storing the
    /// returned runtime resident and settling `.loaded`. Shared by `downloadAndVerify` (download mode)
    /// and the lazy-rediscovery path in `loadIfNeeded` (load mode). Cancellation rewinds to the right
    /// resting state; any other failure routes through the central translator into `.failed`.
    private func runProvisioner(_ descriptor: ModelDescriptor,
                                provisioner: ModelProvisioner,
                                mode: ProvisionMode) async throws {
        state = (mode == .download) ? .downloading(progress: 0) : .loading
        // Keep the system awake for the duration. Idle system sleep mid-download would both interrupt
        // the long fetch AND (on wake) tear down the trackpad listener and crash; a multi-gigabyte
        // load is also worth protecting. The display may still sleep — we only block *system* sleep.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: mode == .download ? "Downloading on-device AI model" : "Loading on-device AI model")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            let runtime = try await provisioner(descriptor) { [weak self] p in
                // In load mode the weights are already present (the downloader skips them), so the
                // callback would only flash a misleading "Downloading…" bar over the heavy load — keep
                // `.loading` instead.
                guard mode == .download else { return }
                Task { @MainActor in self?.state = .downloading(progress: min(max(p, 0), 1)) }
            }
            residentRuntime = runtime
            activeDescriptor = descriptor
            residentDescriptor = descriptor
            verifiedBytes = nil // the pipeline owns the on-disk weights; no in-memory copy here
            state = .loaded
        } catch is CancellationError {
            // A cancelled LOAD keeps the on-disk weights (rewind to .ready); a cancelled DOWNLOAD has
            // nothing usable yet (rewind to .notDownloaded).
            state = (mode == .load) ? .ready : .notDownloaded
            throw RuntimeError.cancelled
        } catch {
            // De-leak: route the (already-boundary-mapped `RuntimeError`, or any error) through the
            // single translator — a clean headline into `.failed`, raw text only as opt-in details.
            let presented = AIError.message(for: error)
            state = .failed(reason: presented.headline, details: presented.details)
            throw error
        }
    }

    // MARK: - Load / residency / evict

    /// Lazy-load the verified weights into a resident runtime. Idempotent: if already loaded for the
    /// same descriptor, returns the resident runtime WITHOUT re-loading (residency between calls). The
    /// weights must be verified first (`.ready`/`.loaded`), else this reports `modelMissing`.
    @discardableResult
    public func loadIfNeeded() async throws -> LLMRuntime {
        guard optedIn else {
            throw RuntimeError.unavailable(reason: "AI commands opt-in is off")
        }
        // Already resident → no cold-load cost paid again. (On the provisioner path the runtime is
        // already resident after `downloadAndVerify`, so this is the warm hit.)
        if let runtime = residentRuntime {
            state = .loaded
            return runtime
        }

        // Provisioner (real-runtime) path: weights live with the pipeline on disk, not as
        // `verifiedBytes`. If they're present on disk (e.g. rediscovered after a relaunch), LOAD them
        // resident now — the resumable downloader skips the complete files, so this re-loads without
        // re-downloading. Otherwise the model is genuinely missing.
        if let provisioner {
            guard let descriptor = activeDescriptor ?? (registry.defaultDescriptor ?? registry.models.first),
                  provisionedOnDisk(descriptor) else {
                throw RuntimeError.modelMissing
            }
            guard hardwareSupports(descriptor) else {
                state = .failed(reason: "This Mac cannot run \(descriptor.displayName)")
                throw RuntimeError.unavailable(reason: "Unsupported hardware for \(descriptor.id)")
            }
            try await runProvisioner(descriptor, provisioner: provisioner, mode: .load)
            guard let runtime = residentRuntime else { throw RuntimeError.modelMissing }
            return runtime
        }

        guard let descriptor = activeDescriptor, verifiedBytes != nil else {
            throw RuntimeError.modelMissing
        }
        guard hardwareSupports(descriptor) else {
            state = .failed(reason: "This Mac cannot run \(descriptor.displayName)")
            throw RuntimeError.unavailable(reason: "Unsupported hardware for \(descriptor.id)")
        }

        state = .loading
        do {
            let runtime = try runtimeFactory(descriptor)
            residentRuntime = runtime
            residentDescriptor = descriptor
            state = .loaded
            return runtime
        } catch {
            // De-leak the load failure through the central translator (clean headline + opt-in details).
            let presented = AIError.message(for: error)
            state = .failed(reason: presented.headline, details: presented.details)
            throw error
        }
    }

    /// Resolve a runtime for a command's required capabilities: select a satisfying descriptor, ensure
    /// it is downloaded+verified+loaded, and return the resident runtime. The single entry point the
    /// executor uses; feature code never sees a concrete model.
    ///
    /// This does NOT auto-download (download is an explicit, opt-in, user-visible action). It WILL,
    /// however, lazy-LOAD a model whose weights are already on disk (e.g. rediscovered after a relaunch)
    /// — loading present weights is not a download. If nothing usable is present it reports
    /// `modelMissing` so the UI can prompt a download rather than silently fetching gigabytes.
    public func runtime(requiring required: Set<Modality>) async throws -> LLMRuntime {
        guard optedIn else {
            throw RuntimeError.unavailable(reason: "AI commands opt-in is off")
        }
        let descriptor = try registry.selectModel(requiring: required)
        // On the provisioner (real-runtime) path the weights live with the pipeline, not as
        // `verifiedBytes`. Resolve from a resident runtime (warm) OR from weights already on disk
        // (cold rediscovery → lazy load via `loadIfNeeded`, no re-download).
        if provisioner != nil {
            if let active = activeDescriptor, active.id == descriptor.id, residentRuntime != nil {
                return try await loadIfNeeded()   // warm hit
            }
            guard provisionedOnDisk(descriptor) else {
                throw RuntimeError.modelMissing   // nothing on disk → genuinely needs a download
            }
            activeDescriptor = descriptor          // adopt the selected descriptor and load it resident
            return try await loadIfNeeded()
        }
        guard let active = activeDescriptor, active.id == descriptor.id, verifiedBytes != nil else {
            throw RuntimeError.modelMissing
        }
        return try await loadIfNeeded()
    }

    /// The currently resident runtime, if loaded (nil otherwise). Exposed for tests / introspection.
    public var currentRuntime: LLMRuntime? { residentRuntime }

    /// Evict the resident runtime (memory pressure, or opt-in off). The weights stay on disk, so the
    /// state falls back to `.ready` (a warm re-load, never a re-download) whenever they're still
    /// present — on the byte path via `verifiedBytes`, and on the provisioner path via the on-disk
    /// probe (where `verifiedBytes` is always nil because the pipeline owns the weights). Without the
    /// provisioner branch, "Evict from memory" would leave the row stuck showing "Loaded" while nothing
    /// is resident.
    public func evict() {
        let descriptor = residentDescriptor
        residentRuntime = nil
        residentDescriptor = nil
        guard case .loaded = state, let descriptor else { return }
        // On the byte path, `verifiedBytes` proves on-disk presence; on the provisioner path it is
        // always nil (the pipeline owns the weights), so the disk probe is what proves presence. If the
        // weights are still there, fall back to `.ready` (warm reload); if they vanished underneath us,
        // be honest and reset to `.notDownloaded` rather than leaving a stale `.loaded`.
        let stillOnDisk = verifiedBytes != nil || (provisioner != nil && provisionedOnDisk(descriptor))
        state = stillOnDisk ? .ready : .notDownloaded
    }

    /// Whether a model is currently resident in memory.
    public var isResident: Bool { residentRuntime != nil }

    // MARK: - Paths + hashing

    private func weightsURL(for descriptor: ModelDescriptor) -> URL {
        storageRoot.appendingPathComponent(descriptor.id, isDirectory: true)
            .appendingPathComponent("weights.bin")
    }

    /// SHA-256 of the bytes as a lowercase hex string (matches `integritySHA` format).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
