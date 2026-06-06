# CLAUDE.md — guidance for coding agents

Orientation lives in **`README.md`** (it's written for an agent: Job A = install/run, Job B = work on the code). This file is the short list of things that are easy to get wrong. Read the **Building & signing** rule before you build anything.

## Building & signing — read this first

**Do not assemble or install the `.app` from the agent's shell.** The sandboxed shell has **no keychain access**, so `scripts/build-app.sh` falls back to **ad-hoc signing**. Ad-hoc signing changes the app's code identity (CDHash) on every build, which **silently invalidates the macOS TCC permission grants** the app depends on — Accessibility, Input Monitoring, Screen Recording. The result: the app launches but quietly does nothing (no gesture capture, no thumbnails), which looks like a bug but is really a broken signature. An agent-built `.app` also **collides with the user's own stable-signed install** at the same path.

So the division of labor is:

- **Agent does:** edit code, and verify with **`swift build`** / **`swift test`** only. These compile and run logic — they don't sign, install, or launch the app, so they're safe and useful. To compile-check a *subset* of the tree in isolation (e.g. one feature without another's uncommitted files), use a throwaway **`git worktree`** and `swift build` there — never the shared working tree's `.app`.
- **User does (in their own Terminal):** the real build for any in-app or permission testing —
  ```bash
  INSTALL=1 ./scripts/build-app.sh      # stable-signed, installed in place to /Applications
  ./scripts/make-dev-cert.sh            # run ONCE if the "ThreeFingerSwitcher Dev" cert is missing
  ```
  A stable signing identity means TCC grants (and Open-at-Login) **survive across rebuilds** — a rebuild *is* the update.

**Releases are never built locally.** Pushing a `vX.Y.Z` git tag triggers `.github/workflows/release.yml`, which builds, **Developer-ID-signs + notarizes + staples**, and publishes a DMG to GitHub Releases (see `docs/RELEASING.md`). Don't try to notarize or Developer-ID-sign from the agent shell — that's the CI runner's job, and it has the secrets.

## Final gesture mechanism

- **Opt-in ON** → `TrackpadThreeFingerVertSwipeGesture = 0` (one-time re-login). At runtime: the scroll tap consumes three-finger scroll; `GestureRecognizer` / `MissionControl` synthesize idle Mission Control / App Exposé, and post-activation vertical travel steps between Space-rows.
- **Opt-in OFF** → native three-finger Mission Control is untouched; the switcher is horizontal-only.

## Spec-first workflow

Behavior is specified in `openspec/specs/<capability>/spec.md`; every change goes through `openspec/changes/<name>/` (proposal → design → spec delta → tasks). Read the relevant spec before changing behavior, and update it after. See `README.md` Job B for the full loop.
