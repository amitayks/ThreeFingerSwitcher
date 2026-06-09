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
            }
        )
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
