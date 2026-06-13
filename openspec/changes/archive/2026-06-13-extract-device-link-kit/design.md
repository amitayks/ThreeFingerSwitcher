## Context

The iOS companion app must consume the wire contract / mirror store / pairing crypto, but they lived in the macOS-only, MLX-pulling `ThreeFingerSwitcher` package. Extracting them to a standalone cross-platform package is the clean fix (vs. adding iOS to the Mac package, which would force the MLX graph to resolve for iOS).

## Goals / Non-Goals

**Goals:** a standalone `DeviceLinkKit` (macOS + iOS, no deps) hosting the three packages; both apps consume it; no behavior change; tests green; the iOS app builds.

**Non-Goals:** moving `PairedDevice`/`PairedDeviceStore` (Mac persistence — stays in Core); any behavior change.

## Decisions

**D1 — A sibling standalone package, consumed by local path.** `../DeviceLinkKit` is referenced by both `ThreeFingerSwitcher/Package.swift` and the iOS XcodeGen project. Local-path package deps keep everything on-disk, no publishing. *Alternative:* add `.iOS` to the Mac package — rejected: the `gemma-4-swift-mlx` dependency would have to resolve for iOS, and the macOS-only app/GemmaRuntime targets muddy the platform contract.

**D2 — Move source + tests verbatim; only the package home changes.** The types were already `public`; no edits to bodies. The Mac adapter/connection/store tests stay in the Mac suite and import the product (the test target gains an explicit `DeviceLinkProtocol` product dep). The pure-package tests travel to `DeviceLinkKit`.

## Risks / Trade-offs

- **Two `swift test` invocations now** (Mac repo + `DeviceLinkKit`). → Acceptable; CI runs both. Documented.
- **A consumer must have `../DeviceLinkKit` present.** → Both repos are siblings under `Projects/`; the iOS `project.yml` and the Mac `Package.swift` use the relative path.

## Migration Plan

Move the six directories; rewrite the two manifests; re-resolve. Verified by `DeviceLinkKit` `swift test` + the Mac suite + the iOS `xcodebuild`. Rollback = move them back and restore the targets.
