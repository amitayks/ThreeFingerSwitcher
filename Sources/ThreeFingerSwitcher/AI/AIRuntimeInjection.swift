import Foundation

/// The injection seam that lets the app executable wire a REAL `LLMRuntime`-backed `ModelManager`
/// into Core WITHOUT Core ever referencing a concrete model or framework (design D1/D7).
///
/// Core (and `swift test`) stay MLX-free: the factory is nil by default, so `AppCoordinator` falls
/// back to `DevAIRuntime.makeModelManager` (the stub). The app target's `main.swift` sets the factory
/// to `GemmaRuntime.makeModelManager` BEFORE `runThreeFingerSwitcher()`, so the lazily-built
/// `modelManager` resolves to the in-process Gemma 4 (MLX) runtime in a real build.
public enum AIRuntimeInjection {
    /// When set, `AppCoordinator` builds its `ModelManager` from this factory (the real Gemma runtime).
    /// nil → the dev-stub path. `@MainActor` to match `ModelManager`'s isolation.
    ///
    /// The factory carries the live Full-Potential gate flags (`fullPotentialEnabled` / `cpuLaneEnabled`
    /// / `batchedRuntimeEnabled`, §D1 — read, not owned) so `GemmaRuntime.makeModelManager` can install
    /// the CPU ternary lane AND the multi-stream batched runtime behind their gates. OFF (the default for
    /// each) → no CPU lane is constructed and the GPU runtime is the proven single-session
    /// `GemmaMLXRuntime`, so the build behaves exactly as today's single-GPU-lane one; the dev-stub
    /// fallback ignores them. The wiring resolves each flag through `FullPotentialGate.isUnlocked` (the
    /// single resolver) at the call site, so a master-OFF locks both at once (the calm panic-off).
    @MainActor public static var modelManagerFactory:
        (@MainActor (_ optedIn: Bool,
                     _ cpuLaneUnlocked: Bool,
                     _ batchedRuntimeUnlocked: Bool) -> ModelManager)? = nil

    /// When set, `AppCoordinator` builds the image `MediaRuntime` the `MediaToolContributor`/`MediaGenSink`
    /// consume (the `generate_image` backend). Parallel to `modelManagerFactory`: nil keeps Core MLX-free
    /// (no image runtime ⇒ the contributor advertises `generate_image` only if some other runtime is
    /// wired, i.e. NOT at all in a Core/test build), and the app target's `main.swift` sets it to
    /// `GemmaRuntime.makeImageRuntime`. The app passes the user-selected `imageModelID` (the catalog
    /// selection); the GemmaRuntime side resolves the `ImageModelCatalog` descriptor + weights + the
    /// gallery output dir and constructs `MFluxImageRuntime`. The runtime's pipeline is unbuilt until
    /// Wave 2, so it surfaces a CLEAN `MediaError` (never a blank PNG) — an honest "model isn't ready yet."
    @MainActor public static var imageRuntimeFactory:
        (@MainActor (_ imageModelID: String?) -> MediaRuntime?)? = nil
}
