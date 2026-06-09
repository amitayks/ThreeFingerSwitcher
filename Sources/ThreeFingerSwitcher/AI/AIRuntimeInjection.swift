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
    @MainActor public static var modelManagerFactory: (@MainActor (_ optedIn: Bool) -> ModelManager)? = nil
}
