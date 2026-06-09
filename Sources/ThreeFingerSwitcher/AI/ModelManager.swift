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
    /// A terminal failure for this attempt (corrupt download, unavailable hardware, …). Carries a
    /// reason string the UI can surface, with a retry affordance.
    case failed(reason: String)
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

    private let storageRoot: URL

    /// The resident runtime once loaded; nil means not loaded (notDownloaded/ready/evicted).
    private var residentRuntime: LLMRuntime?
    /// The descriptor whose weights are verified on disk and (when loaded) resident.
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
                runtimeFactory: @escaping @Sendable (ModelDescriptor) throws -> LLMRuntime = { descriptor in
                    StubLLMRuntime(capabilities: descriptor.capabilities)
                }) {
        self.registry = registry
        self.downloader = downloader
        self.optedIn = optedIn
        self.storageRoot = storageRoot ?? Self.defaultStorageRoot()
        self.hardwareSupports = hardwareSupports
        self.provisioner = provisioner
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
            state = .downloading(progress: 0)
            // Keep the system awake for the duration of the multi-gigabyte download. Idle system sleep
            // mid-download would both interrupt the long fetch AND (on wake) tear down the trackpad
            // listener and crash. The display may still sleep — we only block *system* sleep.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled], reason: "Downloading on-device AI model")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                let runtime = try await provisioner(descriptor) { [weak self] p in
                    Task { @MainActor in self?.state = .downloading(progress: min(max(p, 0), 1)) }
                }
                residentRuntime = runtime
                activeDescriptor = descriptor
                verifiedBytes = nil // the pipeline owns the on-disk weights; no in-memory copy here
                state = .loaded
            } catch is CancellationError {
                state = .notDownloaded
                throw RuntimeError.cancelled
            } catch {
                state = .failed(reason: "Failed to provision \(descriptor.displayName): \(error)")
                throw error
            }
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
            state = .loaded
            return runtime
        } catch {
            state = .failed(reason: "Failed to load \(descriptor.displayName): \(error)")
            throw error
        }
    }

    /// Resolve a runtime for a command's required capabilities: select a satisfying descriptor, ensure
    /// it is downloaded+verified+loaded, and return the resident runtime. The single entry point the
    /// executor uses; feature code never sees a concrete model.
    ///
    /// This does NOT auto-download (download is an explicit, opt-in, user-visible action). If the
    /// selected model is not the verified one, it reports `modelMissing` so the UI can prompt a
    /// download rather than silently fetching gigabytes.
    public func runtime(requiring required: Set<Modality>) async throws -> LLMRuntime {
        guard optedIn else {
            throw RuntimeError.unavailable(reason: "AI commands opt-in is off")
        }
        let descriptor = try registry.selectModel(requiring: required)
        // On the provisioner (real-runtime) path the weights live with the pipeline, not as
        // `verifiedBytes`; residency is proven by a resident runtime for the selected descriptor.
        if provisioner != nil {
            guard let active = activeDescriptor, active.id == descriptor.id, residentRuntime != nil else {
                throw RuntimeError.modelMissing
            }
            return try await loadIfNeeded()
        }
        guard let active = activeDescriptor, active.id == descriptor.id, verifiedBytes != nil else {
            throw RuntimeError.modelMissing
        }
        return try await loadIfNeeded()
    }

    /// The currently resident runtime, if loaded (nil otherwise). Exposed for tests / introspection.
    public var currentRuntime: LLMRuntime? { residentRuntime }

    /// Evict the resident runtime (memory pressure, or opt-in off). The verified weights stay on disk
    /// (state falls back to `.ready` if they were verified), so a re-load is warm, not a re-download.
    public func evict() {
        residentRuntime = nil
        if verifiedBytes != nil, activeDescriptor != nil {
            // Weights remain verified on disk; just no longer resident.
            if case .loaded = state { state = .ready }
        }
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
