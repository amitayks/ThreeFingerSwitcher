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
    // The factory carries the ALREADY-RESOLVED Full-Potential gates (AppCoordinator computes them via
    // `FullPotentialGate.isUnlocked`): the CPU ternary lane is installed only when `.cpuLane` is unlocked
    // and the multi-stream batched runtime only when `.batchedRuntime` is unlocked (§D1 / §7.1). Both OFF
    // (the default) → today's single-GPU-lane, single-session build (the calm panic-off).
    AIRuntimeInjection.modelManagerFactory = { optedIn, cpuLaneUnlocked, batchedRuntimeUnlocked in
        GemmaRuntime.makeModelManager(optedIn: optedIn,
                                      cpuLaneUnlocked: cpuLaneUnlocked,
                                      batchedRuntimeUnlocked: batchedRuntimeUnlocked)
    }
    // The image `MediaRuntime` (the `generate_image` backend) — same seam pattern. The runtime's
    // diffusion pipeline is unbuilt until Wave 2, so a `generate_image` route surfaces a clean, bounded
    // `MediaError` (model not installed / not ready), never a blank PNG or the model's raw tool-call text.
    AIRuntimeInjection.imageRuntimeFactory = { GemmaRuntime.makeImageRuntime(imageModelID: $0) }
}

runThreeFingerSwitcher()
