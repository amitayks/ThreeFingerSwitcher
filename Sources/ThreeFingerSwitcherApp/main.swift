import ThreeFingerSwitcherCore
import GemmaRuntime

// Thin executable: all app logic lives in the ThreeFingerSwitcherCore library so that a
// test target can `@testable import ThreeFingerSwitcherCore`. (A test target cannot
// @testable-import an executable module that contains top-level code.)

// Wire the REAL in-process Gemma 4 (MLX) runtime into Core's model seam BEFORE app startup, so the
// lazily-built `ModelManager` resolves to it (Core itself stays MLX-free; see AIRuntimeInjection).
// Top-level executable code runs on the main thread, so asserting MainActor isolation is valid here
// (same pattern as runThreeFingerSwitcher) and lets us set the @MainActor-isolated factory.
MainActor.assumeIsolated {
    AIRuntimeInjection.modelManagerFactory = { GemmaRuntime.makeModelManager(optedIn: $0) }
}

runThreeFingerSwitcher()
