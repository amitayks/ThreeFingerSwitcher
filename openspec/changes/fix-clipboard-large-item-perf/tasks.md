## 1. Bounded fingerprints + capture cap (capture path)

- [x] 1.1 In `ClipboardMonitor.makeEntry`, derive text/url fingerprints from the existing FNV-1a `hash(_:)` over the payload bytes (`"text:\(hash(data))"`, `"url:\(hash(data))"`) instead of embedding the raw string — leave image/color/rtf as-is (already hashed).
- [x] 1.2 Add a hard per-item capture ceiling (`maxCaptureBytes`, default 64 MB, overridable instance var for tests); in `ClipboardMonitor.capture`, skip recording when the entry's total inline bytes exceed it (no partial entry).
- [x] 1.3 Unit tests: identical large content de-dups via hash fingerprint (no second entry); fingerprint string length is bounded + omits the raw content (text and url); an over-`maxCaptureBytes` payload is not recorded. *(Verified green in the isolated harness — see note in §6.)*

## 2. Light band window + on-demand materialization (store)

- [x] 2.1 Added `previewByteCap` (16 KB) + `boundedForBand(_:)` on `ClipboardStore`: textual kinds keep plain text truncated via a bounded read (inline slice or first `previewByteCap+1` bytes of the blob via `FileHandle`, trimmed to valid UTF-8 by `validUTF8Prefix`) and drop RTF; `color`/`file` kept whole; `image` bytes dropped. Sets `isPreviewTruncated` when cut.
- [x] 2.2 Added `ClipboardStore.bandWindow(limit:)` = `recentWindow` slice mapped through `boundedForBand`. `recentWindow` (full materialize) left untouched for the device-link outbound path.
- [x] 2.3 Added `ClipboardStore.materializedEntry(id:) -> ClipboardEntry?` (looks up by id + resolves blobs to inline).
- [x] 2.4 Unit tests: `bandWindow` truncates oversized text to ≤ `previewByteCap`, keeps small text whole, drops image bytes, trims UTF-8; `materializedEntry(id:)` returns the complete representations (nil for unknown id); `recentWindow` still fully materializes. *(Verified green in the isolated harness.)*

## 3. Off-main persistence (store)

- [x] 3.1 `insert` keeps `dedup`/`evict` synchronous on the MainActor; `save()` now snapshots the entries and dispatches the disk work (blob writes + index write + orphan prune) to a serial `ioQueue` via `nonisolated static persist(...)`. Added `flush()` (`ioQueue.sync {}`) for deterministic durability.
- [x] 3.2 Verified via the harness that `flush()` + reload round-trips entries, pins, large-text blobs and image blobs consistently, and the index stays small; existing reload tests updated to `flush()` before reloading.

## 4. Bounded preview render + on-demand image (view)

- [x] 4.1 Added non-persisted `isPreviewTruncated: Bool = false` to `ClipboardEntry`, excluded via an explicit `CodingKeys` that omits it (on-disk schema unchanged; verified the flag never appears in `index.json`).
- [x] 4.2 `ClipboardValueView` decodes the bounded text **once** (`let display = previewText`), computes `looksMonospaced` once over it, and caps the render with `.lineLimit(previewLineCap=500)`.
- [x] 4.3 When `isPreviewTruncated`, shows the footer "Preview truncated — the full content will be pasted."
- [x] 4.4 `.image` renders `ClipboardImagePreview(entryID:)`: loads the full entry on demand via `ClipboardStore.shared.materializedEntry`, downsamples off-main with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize`), `.task(id:)` cancels superseded loads, spinner→image→placeholder states. *(Subview compiled in isolation against the real store.)*

## 5. On-demand paste + wiring (fire path + coordinator)

- [x] 5.1 Added injectable `clipboardResolver: (UUID) -> ClipboardEntry?` to `LaunchService` (default `{ _ in nil }`); `pasteEntry` resolves the full entry by `entry.id` (`?? entry` fallback) before `writeToPasteboard`.
- [x] 5.2 `AppCoordinator`: all three band-build sites now use `bandWindow(limit:)`; wired `clipboardResolver: { [weak self] id in self?.clipboardStore.materializedEntry(id: id) }`. `sendLatestClipboardToDevices` still uses `recentWindow(limit: 1)` (full bytes).
- [x] 5.3 Covered by `testMaterializedEntryReturnsFullContentNotPreview` — a truncated band entry's id resolves to the FULL content that paste writes; the `?? entry` fallback is a trivial nil-coalesce (nil resolver → passed entry, no crash). *(pasteEntry itself synthesizes ⌘V via AppKit and isn't unit-drivable.)*

## 6. Verify

- [~] 6.1 The whole-repo `swift build`/`swift test` is **blocked by a pre-existing baseline break unrelated to this change** — pristine `main` has ~453 errors from many unstarted/partial AI OpenSpec changes (missing `MediaRuntime`, `ModelCatalog`, `NotchSessionEngine`, `FullPotentialCapability`, `HubFleetRosterView`, …). Instead, every changed MLX-free file (`ClipboardEntry`/`Capture`/`Store`/`Monitor` + the new `ClipboardImagePreview` subview) was compiled and unit-tested in an **isolated SwiftPM harness under Swift 6.3.3 — 15/15 green**. The real test-suite additions (Store + Monitor) mirror those and will run when the baseline builds. `LaunchService`/`AppCoordinator` edits are mechanical and type-checked by inspection.
- [x] 6.2 `openspec validate fix-clipboard-large-item-perf` passes.
- [ ] 6.3 User validates in a signed build: paste a multi-MB text → no copy-time freeze; open + scrub the band with several large entries → no crash, bounded previews; fire a truncated entry → full content pastes; images still preview and paste (PNG+TIFF).
