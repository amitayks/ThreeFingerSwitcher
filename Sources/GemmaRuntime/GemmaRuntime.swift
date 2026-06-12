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

/// The composition root for the real, in-process Gemma 4 runtime.
public enum GemmaRuntime {

    /// Build a `ModelManager` wired to the real Gemma 4 (MLX) runtime.
    ///
    /// Uses `ModelRegistry.standard` (whose descriptors carry the mlx-community repo names/sizes) and a
    /// `ModelProvisioner` that, on `downloadAndVerify(descriptor)`, creates a `GemmaMLXRuntime` and
    /// `prepare`s it — the pipeline downloads the weights from the HuggingFace Hub (which verifies
    /// integrity) and loads them resident, reporting a 0…1 fraction back through the manager's
    /// `.downloading(progress:)` state. The manager then stores the returned runtime and settles
    /// `.loaded`, bypassing its byte-SHA + `runtimeFactory` path entirely.
    ///
    /// `optedIn` seeds the manager's opt-in from settings (no download happens until opt-in).
    @MainActor
    public static func makeModelManager(optedIn: Bool) -> ModelManager {
        ModelManager(
            registry: .standard,
            downloader: HubDownloader(),
            optedIn: optedIn,
            provisioner: { descriptor, progress in
                let model = pipelineModel(for: descriptor)
                let runtime = GemmaMLXRuntime()
                try await runtime.prepare(model: model, progress: progress)
                return runtime
            },
            // Network-free disk probe so the manager rediscovers an already-downloaded model on launch
            // (→ `.ready`) and lazy-loads it on first use, instead of asking the user to "Download"
            // again. Deliberately stricter than `Gemma4ModelCache.isDownloaded` (see `isFullyDownloaded`).
            provisionedOnDisk: { descriptor in
                isFullyDownloaded(pipelineModel(for: descriptor))
            },
            // Delete the weights from the EXACT dir the app loads from / `isFullyDownloaded` probes, so a
            // per-model Delete or the Danger zone genuinely frees them and the model reads as
            // not-downloaded afterwards (Core deletes only its own app-support dir, the wrong location).
            provisionedDelete: { descriptor in
                deleteFromCache(pipelineModel(for: descriptor))
            }
        )
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

    /// Map a Core `ModelDescriptor` (selected from `ModelRegistry.standard`) to a concrete
    /// `Gemma4Pipeline.Model`. Default = the flagship 31B 4-bit. Honors the selected descriptor id;
    /// an unrecognized id falls back to the default rather than failing the build of a request.
    static func pipelineModel(for descriptor: ModelDescriptor) -> Gemma4Pipeline.Model {
        switch descriptor.id {
        case "gemma-4-31b":      return .b31b4bit                 // mlx-community/gemma-4-31b-it-4bit (~17 GB)
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
