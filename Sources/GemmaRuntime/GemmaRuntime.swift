// GemmaRuntime — the MLX-backed Gemma 4 runtime, isolated in its own SwiftPM target.
//
// WHY A SEPARATE TARGET: it links MLX (`Gemma4Swift` → mlx-swift), whose Metal shaders only
// compile under `xcodebuild`. Keeping it out of `ThreeFingerSwitcherCore` lets the Core library and
// the test target keep building/verifying under plain `swift build` / `swift test` (no Metal). Only
// this target and the app executable that depends on it require `xcodebuild`.
//
// It conforms to Core's public `LLMRuntime` seam and is injected at the model seam from the app
// target's entry point — Core never references a concrete model (design D1/D7).

import Foundation
import ThreeFingerSwitcherCore
import Gemma4Swift
import MLX

/// The composition root for the real, in-process Gemma 4 runtime.
public enum GemmaRuntime {

    /// Build a `ModelManager` wired to the real Gemma 4 (MLX) runtime.
    ///
    /// Uses `ModelCatalog.standard` (whose descriptors carry the mlx-community repo names/sizes) and a
    /// `ModelProvisioner` that, on `downloadAndVerify(descriptor)`, creates a `GemmaMLXRuntime` and
    /// `prepare`s it — the pipeline downloads the weights from the HuggingFace Hub (which verifies
    /// integrity) and loads them resident, reporting a 0…1 fraction back through the manager's
    /// `.downloading(progress:)` state. The manager then stores the returned runtime and settles
    /// `.loaded`, bypassing its byte-SHA + `runtimeFactory` path entirely.
    ///
    /// `optedIn` seeds the manager's opt-in from settings (no download happens until opt-in).
    ///
    /// FLEET + COMPUTE TIERS (wire-compute-fleet): this is the live composition root where the V2.5
    /// fleet and the CPU ternary lane are welded onto the running app.
    ///  - **Fleet:** `fleet: FleetRoster.standard` is passed into `ModelManager.init` so the manager's
    ///    `ensureResident(_:)` plan/evict path is REACHABLE (it was dead while `fleet` defaulted nil). The
    ///    free-memory probe keeps `FleetRoster`'s default 48 GB budget (the user's stable-signed build
    ///    verifies the real bytes); a fleet-of-one / single-model load still works because the standard
    ///    roster's plan for the chat target is `{admit:[chat], evict:[]}` — byte-for-byte today's behavior.
    ///  - **Compute tiers:** the `TernaryCPURuntime` is constructed ONLY when `cpuLaneUnlocked` (the
    ///    already-resolved `isUnlocked(.cpuLane)` = master ∧ sub-flag ∧ ai-commands, §D1 / §7.1). LOCKED
    ///    (the default) → no `TernaryCPURuntime` is constructed and the provisioner only ever returns the
    ///    GPU runtime, so the build behaves exactly as a single-GPU-lane one (no regression). UNLOCKED → a
    ///    `.cpuTernary`-lane fleet descriptor resolves, through the EXISTING provisioner seam keyed by
    ///    `descriptor.lane`, to the installed `TernaryCPURuntime` (a stub that yields cleanly until its real
    ///    bitnet.cpp-class backend — it never fakes tokens; the WIRING + lane selection is what this lands).
    ///
    ///  - **Batched runtime:** the GPU lane's resident runtime is the multi-stream
    ///    `BatchedGemmaMLXRuntime` ONLY when `batchedRuntimeUnlocked` (§D1 → `batchedRuntimeEnabled` under
    ///    the master). OFF (the default) → the proven single-session `GemmaMLXRuntime` is resident, so the
    ///    K-stream / growable-context surface is simply never constructed and the build behaves exactly as
    ///    today's single-session one (the calm panic-off — no error, just inert).
    ///
    /// `cpuLaneUnlocked` / `batchedRuntimeUnlocked` are ALREADY resolved by the caller through
    /// `FullPotentialGate.isUnlocked(_:)` (the single resolver — so a master-OFF or ai-commands-OFF locks
    /// both at once); they default to today's OFF behavior so existing call-sites / tests compile unchanged.
    @MainActor
    public static func makeModelManager(optedIn: Bool,
                                        cpuLaneUnlocked: Bool = false,
                                        batchedRuntimeUnlocked: Bool = false) -> ModelManager {
        configureModelStorage()   // relocate the model store off purgeable ~/Library/Caches (see below)
        configureGPUCacheLimit()  // bound the MLX Metal buffer cache (see below)
        // Install the CPU ternary lane ONLY when the gate is on (returns nil when OFF → GPU lane alone,
        // today's behavior). Weights live under the same model cache root the chat path loads from, keyed
        // off the ternary fleet descriptor's HF repo path (mirrors `makeImageRuntime`'s weights dir).
        // `cpuLaneUnlocked` is the already-resolved `isUnlocked(.cpuLane)` (master ∧ sub-flag ∧ ai-commands).
        let ternaryLane = cpuLaneUnlocked ? TernaryCPURuntime(weightsURL: ternaryWeightsURL()) : nil
        return ModelManager(
            registry: .standard,
            downloader: HubDownloader(),
            optedIn: optedIn,
            provisioner: { descriptor, progress in
                // §6.1 lane-keyed resolution (design D2): a `.cpuTernary`-lane fleet descriptor loads the
                // installed `TernaryCPURuntime` (when the gate is on) through this UNCHANGED provisioner
                // seam — feature code selects BY lane, never seeing the concrete type. When the lane is OFF
                // (`ternaryLane == nil`) we fall through to the GPU runtime (belt-and-braces: the role→lane
                // policy already coerces every role to `.gpu` when OFF, so a `.cpuTernary` descriptor is
                // never selected in the first place).
                if descriptor.lane == .cpuTernary, let ternary = ternaryLane {
                    try await ternary.prepare()   // maps load failure → RuntimeError at the boundary (D7)
                    return ternary
                }
                let model = pipelineModel(for: descriptor)
                // The GPU lane's resident runtime, GATED on `batchedRuntimeUnlocked` (the calm panic-off):
                //  - UNLOCKED → the multi-stream `BatchedGemmaMLXRuntime` (design D9): conforms to
                //    `LLMRuntime` AND `BatchedLLMRuntime`, subsuming the single-session paths and adding the
                //    K-stream / growable-context surface the scheduler-driven background advancer downcasts
                //    to via `BatchedLLMRuntime`.
                //  - LOCKED (default) → the proven single-session `GemmaMLXRuntime`. No multi-stream surface
                //    is constructed; the build behaves exactly as today's single-session one (inert, no error).
                // Either is stored by `ModelManager` as a plain `LLMRuntime` (no API change); a locked build
                // simply never offers the `BatchedLLMRuntime` downcast, so the advancer can't engage it.
                if batchedRuntimeUnlocked {
                    let runtime = BatchedGemmaMLXRuntime(weightBytes: descriptor.sizeBytes,
                                                         maxContextTokens: descriptor.maxContextTokens)
                    try await runtime.prepare(model: model, progress: progress)
                    return runtime
                }
                let runtime = GemmaMLXRuntime()
                try await runtime.prepare(model: model, progress: progress)
                return runtime
            },
            // Network-free disk probe so the manager rediscovers an already-downloaded model on launch
            // (→ `.ready`) and lazy-loads it on first use, instead of asking the user to "Download"
            // again. Deliberately stricter than `Gemma4ModelCache.isDownloaded` (see `isFullyDownloaded`).
            // A `.cpuTernary`-lane descriptor's weights aren't a Gemma pipeline model — probe its own
            // dir directly (the ternary GGUF-class file), so the chat pipeline isn't probed for it.
            provisionedOnDisk: { descriptor in
                if descriptor.lane == .cpuTernary {
                    return FileManager.default.fileExists(atPath: ternaryWeightsURL().path)
                }
                return isFullyDownloaded(pipelineModel(for: descriptor))
            },
            // Delete the weights from the EXACT dir the app loads from / `isFullyDownloaded` probes, so a
            // per-model Delete or the Danger zone genuinely frees them and the model reads as
            // not-downloaded afterwards (Core deletes only its own app-support dir, the wrong location).
            provisionedDelete: { descriptor in
                if descriptor.lane == .cpuTernary {
                    try? FileManager.default.removeItem(at: ternaryWeightsDirectory())
                    return
                }
                deleteFromCache(pipelineModel(for: descriptor))
            },
            // The FLEET — passing `FleetRoster.standard` makes `ModelManager.ensureResident(_:)`'s
            // plan/evict block REACHABLE (it was dead while `fleet` defaulted nil). The default 48 GB
            // budget + free-bytes probe keep a fleet-of-one / co-resident load identical to today; the
            // user's stable-signed build verifies the real residency/eviction with real weights.
            fleet: FleetRoster.standard
        )
    }

    /// On-disk location of the CPU ternary lane's weights — under the same model cache root the chat path
    /// loads from, keyed off the `ternary-cpu-chat` fleet descriptor's HF repo path (mirrors the image
    /// runtime's weights-dir derivation). Returns the directory; `ternaryWeightsURL()` appends the file.
    static func ternaryWeightsDirectory() -> URL {
        var dir = Gemma4ModelCache.modelsDirectory
        // The standard roster always carries the ternary member; fall back to the known repo path defensively.
        let repoPath = FleetRoster.standard.descriptor(id: "ternary-cpu-chat")?.downloadURL.path
            ?? "/mlx-community/ternary-cpu-chat"
        for part in repoPath.split(separator: "/") {
            dir.appendPathComponent(String(part))
        }
        return dir
    }

    /// The ternary weights FILE the `TernaryCPURuntime` loads from (a ternary/BitNet-class GGUF-class
    /// file). `TernaryCPURuntime.prepare` does a `fileExists` guard over exactly this path → a missing
    /// file is a clean `RuntimeError.modelMissing`, never a fake load.
    static func ternaryWeightsURL() -> URL {
        ternaryWeightsDirectory().appendingPathComponent("ternary.gguf")
    }

    /// Build the image `MediaRuntime` (the `generate_image` backend) for the user-selected `imageModelID`,
    /// or `nil` when the selection is unknown (an unknown id is REJECTED, never coerced to a default —
    /// `ImageModelCatalog.selected` returns nil, so the contributor simply doesn't advertise the tool).
    ///
    /// Resolves three things and hands them to `MFluxImageRuntime`:
    ///   1. the selected `ImageModelCatalog` descriptor (Q4 default / FP16 opt-in);
    ///   2. the on-disk weights dir — `Gemma4ModelCache.modelsDirectory/<org>/<repo>` derived from the
    ///      descriptor's `downloadURL` path (the same cache layout the chat path uses). It need not exist:
    ///      `MFluxImageRuntime.prepare`'s `fileExists` guard turns a missing dir into a clean
    ///      `MediaError` ("the image model isn't installed yet."), never a fake result;
    ///   3. the gallery output dir (`MediaGallery.defaultRoot()`), where a finished PNG would be written.
    ///
    /// FLAGGED: user xcodebuild + stable-signed build. The runtime's diffusion pipeline is UNBUILT until
    /// Wave 2, so a `generate_image` route returns a clean bounded `MediaError`, not a blank PNG.
    @MainActor
    public static func makeImageRuntime(imageModelID: String?) -> MediaRuntime? {
        configureModelStorage()   // ensure the non-purgeable model root is in effect (idempotent)
        configureGPUCacheLimit()  // ensure the bounded Metal buffer cache is in effect (idempotent)
        guard let descriptor = ImageModelCatalog.selected(imageModelID: imageModelID) else {
            return nil   // unknown id → rejected, no dead-end tool
        }
        // Weights dir off the descriptor's HF repo path (`mlx-community/image-gen-q4`), under the same
        // model cache root the chat path loads from — so a real Wave-2 download lands where this reads.
        var weightsURL = Gemma4ModelCache.modelsDirectory
        for part in descriptor.downloadURL.path.split(separator: "/") {
            weightsURL.appendPathComponent(String(part))
        }
        return MFluxImageRuntime(descriptor: descriptor,
                                 weightsURL: weightsURL,
                                 outputDirectory: MediaGallery.defaultRoot())
    }

    /// Bound MLX's Metal buffer cache (`fix-model-load-coalescing-and-gpu-cache`). By default the cache
    /// is UNBOUNDED: every freed generation buffer is retained for reuse and never returned to the OS —
    /// measured live as **24 GB of dirty IOAccelerator memory for a ~17 GB model after one short chat**,
    /// creeping further with use (the vendored pipeline clears it only on `unload()`). 2 GB is enough to
    /// recycle per-token scratch across a streaming turn while letting a settled app's footprint track
    /// the model size; generation beyond the limit falls back to direct Metal allocations (a perf
    /// trade-off, never a correctness one). Idempotent; both factory entry points call it before any
    /// runtime exists. Tune here, in one place, if profiling ever argues for a different bound.
    nonisolated(unsafe) private static var gpuCacheConfigured = false
    static func configureGPUCacheLimit() {
        guard !gpuCacheConfigured else { return }
        gpuCacheConfigured = true
        MLX.GPU.set(cacheLimit: 2 * 1024 * 1024 * 1024)
    }

    /// The model store must live under a **non-purgeable** root. The vendored `Gemma4ModelCache` defaults
    /// to `~/Library/Caches/models`, which macOS PURGES under disk pressure — silently forcing a ~17 GB
    /// re-download (see `docs/postmortem-idle-cpu-spin.md`). Point the cache at
    /// `ModelManager.defaultStorageRoot()` (`~/Library/Application Support/ThreeFingerSwitcher/models`),
    /// migrate any copy already sitting in the old Caches root (same volume → an instant rename, NOT a
    /// re-download), and exclude it from Time Machine (large, re-downloadable weights). Idempotent; the
    /// factory entry points call it once before any download / load.
    nonisolated(unsafe) private static var storageConfigured = false
    /// `@MainActor` because `ModelManager.defaultStorageRoot()` is main-actor-isolated (ModelManager is
    /// `@MainActor`); both callers (`makeModelManager` / `makeImageRuntime`) are already on the main actor.
    @MainActor
    static func configureModelStorage() {
        guard !storageConfigured else { return }
        storageConfigured = true
        let fm = FileManager.default
        let newRoot = ModelManager.defaultStorageRoot()
        try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        // Application Support IS backed up (unlike Caches) — keep the re-downloadable weights out of it.
        var root = newRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        // One-time migration off the old purgeable Caches root, if a model already downloaded there.
        let oldRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("models", isDirectory: true)
        if oldRoot != newRoot,
           let entries = try? fm.contentsOfDirectory(at: oldRoot, includingPropertiesForKeys: nil) {
            for src in entries {
                let dst = newRoot.appendingPathComponent(src.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) { try? fm.moveItem(at: src, to: dst) }
            }
            try? fm.removeItem(at: oldRoot)   // best-effort: drop the now-empty old dir
        }
        // From here, every `Gemma4ModelCache.modelsDirectory` read/write uses the non-purgeable root.
        Gemma4ModelCache.customModelsDirectory = newRoot
    }

    /// Remove `model`'s weights from `Gemma4ModelCache.modelsDirectory/<org>/<model>` — the exact dir
    /// `GemmaMLXRuntime.prepare` loads from and `isFullyDownloaded` probes — so a delete truly frees the
    /// weights. Mirrors `isFullyDownloaded`'s path construction; a missing dir is a silent no-op.
    static func deleteFromCache(_ model: Gemma4Pipeline.Model) {
        var dir = Gemma4ModelCache.modelsDirectory
        for part in model.rawValue.split(separator: "/") {
            dir.appendPathComponent(String(part))
        }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Whether `model`'s weights are COMPLETELY present in the EXACT directory the app loads from —
    /// the resumable downloader's cache dir (`Gemma4ModelCache.modelsDirectory/<org>/<model>`, the same
    /// path `GemmaMLXRuntime.prepare` builds). A model is "fully downloaded" only when it has a
    /// `config.json` + at least one `*.safetensors` AND no leftover `*.part` shard from an interrupted
    /// download.
    ///
    /// This is intentionally STRICTER than `Gemma4ModelCache.isDownloaded`, which (a) also accepts the
    /// HuggingFace cache (`~/.cache/huggingface/...`) that the app's `ensureModel` does NOT load from —
    /// so a HF-only copy would re-download — and (b) ignores `.part` files, so a half-finished
    /// multi-shard download would read as present and then fail to load. Matching the app's real load
    /// location makes the rediscovery `.ready` mean exactly "loadable without any network."
    static func isFullyDownloaded(_ model: Gemma4Pipeline.Model) -> Bool {
        var dir = Gemma4ModelCache.modelsDirectory
        for part in model.rawValue.split(separator: "/") {
            dir.appendPathComponent(String(part))
        }
        let fm = FileManager.default
        // Walk the model dir (shallow + any subdirs) so a `.part` shard anywhere disqualifies it.
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        var hasConfig = false, hasWeights = false
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".part") { return false }       // an interrupted download is NOT ready
            if name == "config.json" { hasConfig = true }
            if name.hasSuffix(".safetensors") { hasWeights = true }
        }
        return hasConfig && hasWeights
    }

    /// Map a Core `ModelDescriptor` (selected from `ModelCatalog.standard` or the §C1 `FleetRoster`) to a
    /// concrete `Gemma4Pipeline.Model`. Default = the flagship 31B 4-bit. Honors the selected descriptor
    /// id; an unrecognized id falls back to the default rather than failing the build of a request.
    ///
    /// FLAGGED: user xcodebuild + stable-signed build. The fleet's extended `ModelDescriptor` fields
    /// (`role`/`lane`/`provider`/`residencyBytes`) compile in this MLX path unchanged — only the chat
    /// `.role`/`.gpu` members map to a Gemma pipeline here; the ternary/image/video/cloud members route
    /// through their own runtimes/escalation (not this Gemma factory), so they intentionally hit the
    /// default. The chat id (`gemma-4-31b`) is shared with the FleetRoster, so a fleet chat selection
    /// resolves the same pipeline model with no API change.
    static func pipelineModel(for descriptor: ModelDescriptor) -> Gemma4Pipeline.Model {
        switch descriptor.id {
        case "gemma-4-31b":      return .b31b4bit                 // chat (FleetRoster + catalog); ~17 GB
        case "gemma-4-26b-a4b":  return .a4b4bit                  // mlx-community/gemma-4-26b-a4b-it-4bit (~14 GB)
        case "gemma-4-12b":      return .e4b4bit                  // mlx-community/gemma-4-e4b-it-4bit (~5 GB, audio-capable)
        default:                 return .b31b4bit
        }
    }

    /// A `ModelDownloading` placeholder to satisfy `ModelManager`'s required `downloader` dependency.
    /// On the real path the PROVISIONER owns the download (via `Gemma4Pipeline` / the HF Hub), so this
    /// is never actually invoked; it throws to make any accidental use loud rather than silent.
    private struct HubDownloader: ModelDownloading {
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            throw RuntimeError.unavailable(
                reason: "GemmaRuntime downloads via the pipeline/HF Hub through the provisioner, not the byte downloader."
            )
        }
    }
}
