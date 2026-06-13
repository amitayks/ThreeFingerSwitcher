## Context

The Mac already has a complete clipboard subsystem: `ClipboardEntry` (value model with `representations: [UTI: ClipboardPayload]`), `ClipboardStore` (on-disk index + blobs, de-dup by fingerprint, retention caps), `ClipboardMonitor.makeEntry` (the per-kind pasteboard→entry builder), and `ClipboardBandBuilder` (store→synthetic band). The single write seam is `ClipboardStore.insert` (ClipboardStore.swift:76) — origin-agnostic. This change adds a *second source* of entries (the network) without duplicating any of that machinery. `ThreeFingerSwitcherCore` is MLX-free but may use AppKit, so image sizing can reuse `NSBitmapImageRep` exactly as `makeEntry` does. The adapter depends on the `DeviceLinkProtocol` package (change #1) for the `LinkItem` type.

## Goals / Non-Goals

**Goals:**
- A thin, unit-tested `LinkItem → ClipboardEntry` adapter that reuses key/fingerprint conventions so peer and local copies de-dup.
- Received files persisted to a real, openable path (an inbox dir), referenced as a `.file` entry.
- Device provenance recorded on the entry and surfaced in the band.
- Zero new storage/retention path — everything goes through `insert`.

**Non-Goals:**
- Networking, Bonjour, TLS, the receive loop — `device-link-transport`.
- The opt-in toggle + `AppCoordinator` start/stop wiring + the Hub Devices page — `device-link-hub`.
- Mac→iPhone send — `device-link-outbound`.

## Decisions

**D1 — `origin` is an optional additive field, no schema-version bump.** Adding `var origin: ClipboardOrigin?` (default `nil`) to `ClipboardEntry` is forward- and backward-compatible: synthesized `Codable` decodes a missing key to `nil`, and the existing initializer keeps `nil` as the default so no call site changes. `nil` is read as local. This avoids touching `ClipboardStore.migrate`/`currentSchemaVersion` and the tests that assert the v1 schema. *Alternative considered:* a v1→v2 migration setting `.local` — rejected as unnecessary churn for an additive optional; the model is already tolerant. (Provenance can be normalized lazily if ever needed.)

**D2 — `ClipboardOrigin` is a `Codable`/`Equatable` enum with an associated value.** `enum ClipboardOrigin { case local; case peer(deviceName: String?) }`. Swift synthesizes `Codable` for enums with associated values, so no hand-rolled coding. The peer case carries the device name for the band chip.

**D3 — The adapter is a struct with an injected inbox `URL`, not a singleton.** `LinkInboundAdapter(inboxDirectory:)` makes file-write behavior unit-testable against a temp dir. It produces a `ClipboardEntry` (and writes any file bytes) but does **not** call `insert` itself — the caller (the transport, on `@MainActor`) inserts, keeping the adapter free of `@MainActor`/store coupling and trivially testable.

**D4 — Files: write bytes to `inbox/received-<messageID>-<name>`, reference via the `fileURL` representation.** The wire `.file` `LinkItem` carries the file's bytes (under whatever UTI key the sender chose) plus `suggestedName`. The adapter writes those bytes to the inbox and stores `representations[ClipboardUTI.fileURL] = .inline(Data(url.absoluteString.utf8))` — the same shape `makeEntry` produces for a local file (a UTF-8 file-URL string), so `LaunchService`'s paste path works unchanged. Fingerprint is `"file:<path>"` (per-path, matching local convention); re-sends of the same file create distinct inbox copies (acceptable for v1; a content-hash fingerprint is a possible later refinement). The inbox is a sibling of `blobs/` so `externalizedForStorage`/`pruneOrphanBlobs` never touch it.

**D5 — Provenance chip lives in `ClipboardBandView`.** The band item already carries the whole `ClipboardEntry` (`.clipboardEntry(entry)`), so the view reads `entry.origin` and renders a small "from \<device\>" chip for `.peer`. SwiftUI views in Core compile under `swift build`, so the change is compile-verified (runtime appearance is user-verified).

## Risks / Trade-offs

- **A huge received file is held in memory by the adapter before the inbox write.** → For v1 the adapter writes the materialized bytes it is handed; the *streamed-to-disk* large-file path (assembler bypass, design D4 of the protocol change) is a transport concern and will hand the adapter a path rather than bytes when added. The adapter's file API is shaped to accept either.
- **Per-path file fingerprint means re-sending a file doesn't de-dup.** → Acceptable for v1; noted as a future content-hash refinement. Text/image/url/color still de-dup against local copies.
- **`origin` optional could be read inconsistently (`nil` vs `.local`).** → A single `var isPeer`/helper on the entry centralizes the "nil = local" reading.

## Migration Plan

Additive only. `ClipboardEntry` gains an optional field with a default; old indexes load unchanged; no migration step. `ThreeFingerSwitcherCore` gains a dependency on `DeviceLinkProtocol`. Rollback = delete the adapter + field. Nothing calls the adapter yet (the transport change wires it), so there is no runtime behavior change from this change alone.

## Open Questions

- Should the inbox have its own size cap separate from the store's byte cap? For v1 it shares the store's retention (evicted entries' inbox files can be cleaned when their entry is evicted — a possible follow-up; for now eviction drops the entry and the file is orphaned until a future inbox sweep). Flagged for the transport/hub change to decide an inbox-sweep policy.
