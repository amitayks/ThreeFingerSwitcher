# Design — fix-model-load-coalescing-and-gpu-cache

## Context

`ModelManager` is `@MainActor`, but its load paths (`loadIfNeeded()`, `loadDescriptor(_:)`, both funneling into `runProvisioner`) **await** the multi-second provisioner (`GemmaMLXRuntime.prepare` — a ~17 GB weight load). Awaiting suspends the main actor, so a second caller interleaves, observes `residentRuntime == nil`, and launches a second provisioner run. Empirically observed (unified log, two overlapping `prepare` cycles ~2s apart, both completing) — two full models resident at once on a 48 GB machine. Callers that can race: the launcher executor, any notch engine turn, the background driver's advance pass, and the Hub/Settings load affordances.

Separately, the MLX Metal buffer cache is unbounded by default. Measured: 24 GB dirty `IOAccelerator` for a 17 GB model after a single short chat. The vendored `Gemma4Pipeline` calls `MLX.GPU.clearCache()` only in `unload()`; no one calls `MLX.GPU.set(cacheLimit:)`.

Constraints: Core is MLX-free (`swift build`/`swift test`); MLX symbols may appear only in `GemmaRuntime`. The vendored checkout is read-only. The `ai-model-fleet` change (in flight) owns `ResidencyPlanner`/`residencyBytes` semantics.

## Goals / Non-Goals

**Goals:**
- The heavy load runs **at most once** at any moment, regardless of how many callers race; same-descriptor callers share the one result.
- Bounded GPU buffer cache so the resident footprint tracks the model size.
- A deterministic Core regression test for the coalescing.

**Non-Goals:**
- No queueing framework or per-descriptor task table (one in-flight load is the invariant, not N).
- No `ResidencyPlanner` budget changes (fleet change owns them).
- No changes to the vendored pipeline; no eviction-policy changes.

## Decisions

### D1 — One `loadTask`, join-or-start, in `runProvisioner`'s callers
`ModelManager` gains:

```swift
private var loadTask: Task<LLMRuntime, Error>?
private var loadTaskDescriptorID: String?
```

The coalescing lives in one private helper (`loadCoalesced(descriptor:body:)`-style) used by both `loadIfNeeded()` and `loadDescriptor(_:)`:
1. If `residentRuntime` satisfies the request (existing warm checks) → return it (unchanged fast path).
2. If `loadTask` exists **for the same descriptor id** → `try await loadTask.value` (JOIN — the provisioner is not re-run). Errors propagate to every joiner.
3. If `loadTask` exists **for a different descriptor** → `_ = try? await loadTask.value` first (drain — never two provisioners at once), then re-check the resident/warm state and fall through.
4. Otherwise START: wrap the existing load body in a `Task`, record it + its descriptor id, `defer`-clear both on completion (success, throw, or cancellation), and await it.

Because everything is `@MainActor`, the check-then-set between steps is race-free (no awaits between reading and writing `loadTask`). Joiners that are themselves cancelled stop waiting (their own `Task.checkCancellation`) without cancelling the shared load — a shared load is cancelled only through the existing explicit paths (e.g. `cancelDownload`), which also clear the task.
*Alternative*: an `AsyncSemaphore`/actor gate — rejected: a stored `Task` is the idiomatic single-flight primitive here and directly reuses the existing load body.

### D2 — State surfacing stays as-is
`runProvisioner` already drives `.loading`/`.downloading` observable state; joiners don't re-drive it. The existing behavior — the second caller simply gets the runtime when the one load lands — is exactly the spec's "kept resident / cold cost paid once" story extended to the in-flight window.

### D3 — GPU cache limit at the composition root, one constant
`GemmaRuntime.makeModelManager` (and `configureModelStorage`'s sibling call sites share it via a small `configureGPUCacheLimit()` idempotent helper) calls `MLX.GPU.set(cacheLimit: 2 * 1024 * 1024 * 1024)` — **2 GB**, documented: big enough to recycle per-token buffers across a streaming turn (KV-cache growth is allocation-fresh, not cache-served), small enough that a settled app returns generation scratch to the OS. Lives in `GemmaRuntime` only (MLX symbol). Applied once per process before any runtime is constructed.
*Alternative*: proportional-to-model limits — rejected for v1: the win is bounding the unbounded; tuning can follow with real measurements.

### D4 — The regression test shape
`ModelManagerTests`: a provisioner that increments an actor/lock-guarded counter, sleeps ~50 ms, returns a stub runtime. Launch two concurrent `loadIfNeeded()` (async let), assert both return, counter == 1, manager state `.loaded`. A second test: `runtime(requiring:)` racing `loadIfNeeded()` (the real-world pair) — provisioner still runs once. A third: a failing provisioner propagates the same error to both joiners and clears the task so a retry starts fresh.

## Risks / Trade-offs

- **[A joined caller inherits a load it didn't parameterize]** → same-descriptor joins only; different-descriptor callers drain then re-evaluate, preserving existing selection semantics.
- **[2 GB cache limit too small → per-token allocation churn]** → MLX falls back to direct Metal allocations (correctness unaffected); the constant is one line to tune, and the postmortem numbers (24 GB creep) justify erring toward bounded.
- **[Cancellation of a shared load]** → the shared task is cancelled only via the existing explicit cancel paths (which clear it); a joiner's own cancellation abandons the wait without killing the load for others.

## Migration Plan

Single change: Core coalescing + tests (`swift build`/`swift test`), then the one-line GemmaRuntime cache limit (compile-verified via `swift build`/`xcodebuild`). Rollback is a straight revert; no data or format changes.

## Open Questions

None.
