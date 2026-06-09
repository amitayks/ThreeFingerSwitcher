# CLAUDE.md — guidance for coding agents

Orientation lives in **`README.md`** (it's written for an agent: Job A = install/run, Job B = work on the code). This file is the short list of things that are easy to get wrong. Read the **Building & signing** rule before you build anything.

## Building & signing — read this first

**Do not assemble or install the `.app` from the agent's shell.** The sandboxed shell has **no keychain access**, so `scripts/build-app.sh` falls back to **ad-hoc signing**. Ad-hoc signing changes the app's code identity (CDHash) on every build, which **silently invalidates the macOS TCC permission grants** the app depends on — Accessibility, Input Monitoring, Screen Recording. The result: the app launches but quietly does nothing (no gesture capture, no thumbnails), which looks like a bug but is really a broken signature. An agent-built `.app` also **collides with the user's own stable-signed install** at the same path.

So the division of labor is:

- **Agent does:** edit code, and verify with **`swift build`** / **`swift test`** (the MLX-free `ThreeFingerSwitcherCore` + test target) and, for the MLX-linked `GemmaRuntime`/app target, **`xcodebuild`** to *compile-verify only*. These compile and run logic — they don't sign, install, or launch the app, so they're safe and useful. To compile-check a *subset* of the tree in isolation (e.g. one feature without another's uncommitted files), use a throwaway **`git worktree`** and `swift build` there — never the shared working tree's `.app`.
- **User does (in their own Terminal):** the real build for any in-app or permission testing —
  ```bash
  INSTALL=1 ./scripts/build-app.sh      # stable-signed, installed in place to /Applications
  ./scripts/make-dev-cert.sh            # run ONCE if the "ThreeFingerSwitcher Dev" cert is missing
  ```
  A stable signing identity means TCC grants (and Open-at-Login) **survive across rebuilds** — a rebuild *is* the update.

**Releases are never built locally.** Pushing a `vX.Y.Z` git tag triggers `.github/workflows/release.yml`, which builds, **Developer-ID-signs + notarizes + staples**, and publishes a DMG to GitHub Releases (see `docs/RELEASING.md`). Don't try to notarize or Developer-ID-sign from the agent shell — that's the CI runner's job, and it has the secrets.

## On-device AI (the AI Command Band) — build & landmines

The AI band runs **Gemma 4 in-process via MLX**. Two targets, on purpose: **`ThreeFingerSwitcherCore` stays MLX-free** (the `LLMRuntime` seam + a `StubLLMRuntime`/`DevAIRuntime`, the executor, tasks, selection, canvas — all verify under `swift build`/`swift test`); the real model lives in **`GemmaRuntime`**, which links MLX and therefore builds via **`xcodebuild` only** (MLX compiles Metal shaders — one-time `xcodebuild -downloadComponent MetalToolchain`). The app injects the real runtime at the seam in `main.swift`.

- **The metallib landmine:** MLX ships `default.metallib` as a SwiftPM resource bundle (`mlx-swift_Cmlx.bundle`). `build-app.sh` **must copy `*.bundle` into `Contents/Resources/`** — if it doesn't, the app launches but is **SIGKILL'd at first GPU use with no crash report**. This is already handled; don't regress it.
- **Errors: one taxonomy, one translator, mapped at the boundary, surfaced bounded + non-blocking.** New AI code inherits this convention (see the `harden-ai-error-handling` change):
  - **One taxonomy:** classify every AI failure into the shared `RuntimeError` (Core), which conforms to `LocalizedError` with a clean per-case string. **One translator:** `AIError.message(for:) -> AIPresentedError` (a clean `headline` + opt-in copyable `details`) is the SINGLE error→message function — every surface (Settings row, canvas, any alert) routes through it, so the same error reads identically everywhere.
  - **Ban raw interpolation in UI strings:** never put `"\(error)"` / `String(describing: error)` / an OS error's `.localizedDescription` into a headline. Raw text is allowed only in logs and as `AIPresentedError.details`.
  - **Map at the layer boundary:** convert vendor/OS errors (`Gemma4DownloadError`, `NSURLError`, EventKit, `FileManager`/`Process`) into the taxonomy where they cross into app code (e.g. `GemmaMLXRuntime.prepare`, the sinks) — Core stays MLX-free, so it can't see vendor types; only `RuntimeError`/`TaskError` cross into feature/UI code.
  - **Failure is observable state, never silence:** a failure transitions to a `.failed` state carrying the clean headline (never leaves a state stuck mid-flight; cancellation is not a failure). A side effect that didn't land (write/open/paste/task) becomes `.failed`, never a false "Done."
  - **Bounded + non-blocking UI:** never surface a background AI failure via app-modal `NSAlert.runModal()` (it freezes the Settings window) — use the in-window `.failed` row + Retry. Cap long messages (`.lineLimit` + `.truncationMode(.middle)`), put raw text behind a "Show details / Copy" disclosure, and keep layouts scroll-safe.
- **Swipe-to-resolve, not lift-to-commit:** while the preview canvas is open it's resolved by a *fresh four-finger swipe* — **down = commit/apply, horizontal = discard, up = ignored**; a stray re-lift is a no-op (the firing lift already raised the fingers).
- **No vision in v1**, and the model is **Apple-Silicon-only** (no Intel/low-end fallback). The `LLMRuntime` seam exists so another backend can replace Gemma without touching feature code.

## Final gesture mechanism

- **Opt-in ON** → `TrackpadThreeFingerVertSwipeGesture = 0` (one-time re-login). At runtime: the scroll tap consumes three-finger scroll; `GestureRecognizer` / `MissionControl` synthesize idle Mission Control / App Exposé, and post-activation vertical travel steps between Space-rows.
- **Opt-in OFF** → native three-finger Mission Control is untouched; the switcher is horizontal-only.

## Spec-first workflow

Behavior is specified in `openspec/specs/<capability>/spec.md`; every change goes through `openspec/changes/<name>/` (proposal → design → spec delta → tasks). Read the relevant spec before changing behavior, and update it after. See `README.md` Job B for the full loop.
