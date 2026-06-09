import Foundation

/// A **development wiring** for the AI model layer used until the real MLX/Gemma runtime (phase 10) is
/// wired into the app's `xcodebuild` target. It lets the streaming preview canvas and the whole
/// command pipeline run in a signed build TODAY without a real multi-gigabyte download:
///
/// - The standard `ModelRegistry` ships **placeholder** download URLs (`models.invalid`) and dummy
///   integrity SHAs, so a real download can't succeed and `downloadAndVerify` would always fail the
///   SHA check. This builds a **dev registry** whose `integritySHA` is the SHA of a small fabricated
///   payload, paired with a `ModelDownloading` that returns exactly that payload — so download +
///   verify + load succeed deterministically and instantly.
/// - The `runtimeFactory` resolves a `StubLLMRuntime`, which echoes its prompt and serves structured
///   output, so commands produce a visible (if canned) result on-device with no network.
///
/// Swapping in the real runtime is a single `runtimeFactory` change + the real registry/downloader
/// (design D1/D7): feature code only ever sees `LLMRuntime`, so nothing here leaks upward.
enum DevAIRuntime {

    /// The fabricated dev "weights" payload. Tiny and deterministic; its SHA pins the dev descriptor.
    private static let payload = Data("three-finger-switcher-dev-gemma-stub".utf8)

    /// A dev registry mirroring `ModelRegistry.standard`'s ids/display names/capabilities, but with an
    /// integrity SHA that matches `payload` so verification passes. Keeps the real registry's selection
    /// behavior (default-first, capability subset) intact for the band/executor.
    @MainActor
    static var devRegistry: ModelRegistry {
        let standard = ModelRegistry.standard
        let models = standard.models.map { d in
            ModelDescriptor(
                id: d.id,
                displayName: d.displayName,
                sizeBytes: Int64(payload.count),
                integritySHA: ModelManager.sha256Hex(payload),
                downloadURL: d.downloadURL,
                capabilities: d.capabilities,
                quantization: d.quantization
            )
        }
        return ModelRegistry(models: models, defaultModelID: standard.defaultModelID)
    }

    /// Build a `ModelManager` wired to the dev stub: the dev registry, a downloader that returns the
    /// pinned payload, and a `StubLLMRuntime` factory. `optedIn` seeds the opt-in from settings.
    @MainActor
    static func makeModelManager(optedIn: Bool) -> ModelManager {
        ModelManager(
            registry: devRegistry,
            downloader: DevDownloader(payload: payload),
            optedIn: optedIn,
            runtimeFactory: { descriptor in StubLLMRuntime(capabilities: descriptor.capabilities) }
        )
    }

    /// A `ModelDownloading` that returns the fabricated dev payload immediately (no network). Honors
    /// the `ModelManager` contract: reports full progress, returns the bytes for the integrity check.
    private struct DevDownloader: ModelDownloading {
        let payload: Data
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            progress(1.0)
            return payload
        }
    }
}
