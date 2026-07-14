## Context

Clipboard history is MLX-free Core (`Sources/ThreeFingerSwitcher/Clipboard/*` + `Overlay/ClipboardBandView.swift`), verifiable under `swift build` / `swift test`. The pipeline today: `ClipboardMonitor` polls the pasteboard → `ClipboardStore.insert` (dedup → evict → `save`) → on launcher open, `ClipboardStore.recentWindow(limit:)` materializes entries → `ClipboardBandBuilder` wraps each in a `LaunchItem(kind: .clipboardEntry(entry))` → `ClipboardBandView` renders the selected entry's value; firing pastes via `LaunchService.pasteEntry`.

Three places make cost scale with payload size, and a large text copy hits all three:

1. **Capture (`ClipboardMonitor.makeEntry`).** For `.text`/`.url`, `fingerprint = "text:\(str)"` embeds the **entire** copied string. Fingerprints live in `index.json` and are **never** externalized to blobs (only `representations` are, via the 16 KB `blobThreshold`). So a big text lands in the index in full, and every subsequent `insert` → `save()` re-encodes it (JSON) and re-writes the whole index **synchronously on the MainActor**. `dedup` also does full-string `fingerprint ==` compares. → "stuck for a second" on copy, growing with history.
2. **Band build (`recentWindow` + `ClipboardBandBuilder`).** `recentWindow(limit:).map(materialized)` reads **every** windowed entry's blob back into memory at once, and the builder embeds the **full** entry (all inline payloads) into each `LaunchItem`. Opening the band holds the sum of the whole window in RAM. → OOM crash when several/one entries are big.
3. **Preview (`ClipboardValueView`).** Text renders in a non-virtualized SwiftUI `Text` inside a `ScrollView` with **no line limit and no size cap**; TextKit lays out the whole string. `text` re-decodes the full `Data → String` and `monospaced` re-scans it 4× on every body evaluation. → freeze scaling with length, OOM at the extreme.

Constraints: keep Core MLX-free and unit-testable; preserve **faithful paste** (the full representations must still reach the pasteboard); preserve the existing `recentWindow` (full materialize) that the **device-link outbound** path (`sendLatestClipboardToDevices` → `LinkOutboundAdapter`) depends on; no new permission, no gesture relocation, no re-login; backward-compatible on-disk format.

## Goals / Non-Goals

**Goals:**
- A copy of any size never stalls the UI thread perceptibly.
- Opening the Clipboard band and scrubbing through it uses memory bounded to **one** entry at a time, regardless of entry sizes — no crash.
- The value preview renders in bounded time/memory regardless of payload size (truncated preview).
- Faithful paste is preserved: firing restores the entry's **full** representations.
- All logic stays in MLX-free Core and is unit-testable (pure functions over `[ClipboardEntry]` / bounded-derivation helpers).

**Non-Goals:**
- Streaming/virtualized rendering of huge text (a *bounded preview* is sufficient and simpler than a lazy TextKit pipeline).
- Changing the retention model, the pin model, de-dup semantics, or the device-link protocol.
- Surfacing the new caps as user-facing settings (internal constants for now; can be promoted to `AppSettings` later, like the retention caps).
- Compressing or de-duplicating blob contents beyond the existing content-hash blob naming.

## Decisions

### D1 — Fingerprint from a bounded content hash, never raw content
`ClipboardMonitor.makeEntry` derives text/url fingerprints from the existing FNV-1a `hash(_:)` over the payload bytes (already used for image/color/rtf), e.g. `fingerprint = "text:\(hash(data))"`. De-dup semantics are unchanged (identical content → identical hash → same entry). The index row per entry becomes O(1) in size, `dedup` compares are O(1), and `save()` no longer re-encodes megabytes.

- *Why not keep raw for short text?* A branch on length is extra surface for no benefit — hashing is cheap and uniform. URLs are usually short but a `data:` URL can be huge, so hash them too.
- *Collision risk:* FNV-1a 64-bit collision across a ≤200-entry history is negligible, and a collision only means one copy fails to create a new entry (bumps recency of a different item) — non-destructive, and the same risk class the image/color fingerprints already accept.
- *Backward compat:* legacy entries keep their raw-text fingerprints on disk; they still de-dup against themselves. Re-copying the same content after the change computes the hash form and appends a second entry once (the two coexist until one evicts). Acceptable, non-destructive, self-heals.

### D2 — Band build produces **light** entries; full payloads never enter the band
Add `ClipboardStore.bandWindow(limit:) -> [ClipboardEntry]` that returns the same slice as `recentWindow` but with each entry passed through a new `boundedForBand(_:)` instead of `materialized(_:)`:
- **Textual kinds** (`text`, `richText`, `url`): the plain-text representation is materialized **but truncated to `previewByteCap`** (read at most the cap — from the inline bytes, or the first `previewByteCap` bytes of the blob file via a bounded read — never the whole blob). The truncated bytes are stored inline on the light entry, and an `isTruncated` marker (see D5) records that the source was larger. RTF payloads are **dropped** from the band entry (preview uses plain text; the full RTF returns on paste via D4).
- **`color`**: kept inline (tiny, < ~200 B).
- **`file`**: the file-URL reference kept inline (a short path); the QuickLook preview already loads from the URL, not from stored bytes.
- **`image`**: image bytes **dropped** from the band entry; the preview loads the selected image on demand (D3). The light entry keeps its `key` (pixel dimensions) so the row renders without bytes.

`recentWindow` (full materialize) stays untouched for the device-link outbound path. `ClipboardBandBuilder.build` is unchanged in shape — it just receives light entries.

- *Why bounded inline text rather than fully-lazy per-selection text load?* Small text (the 99% case, ≤ `blobThreshold`) is already tiny and passes through whole → the preview stays **instant** with no async/spinner and no behavior change. Only oversized text is truncated. This avoids adding an async load + spinner to the common path.
- *Why still drop image bytes (async load) instead of a bounded slice?* A byte-prefix of an image is a broken image; a downsampled on-demand load (D3) is the correct bound for images and keeps only one image resident.

### D3 — Preview materializes the selected entry on demand for images; bounded downsample
For `image`, `ClipboardValueView` loads the full image for the **selected** entry only, via an injected resolver (D4) + `.task(id: entry.id)` so scrubbing cancels superseded loads. The load runs off-main and **downsamples** to the preview's pixel budget (via `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize`) so a giant image never fully decodes into an `NSImage`. Memory stays at one downsampled image. Text/color/file need no async — text is already bounded inline (D2), color is tiny, file uses the existing async `FilePreview`.

### D4 — Materialize the full entry on demand for paste (and image preview) via a resolver seam
Because band items now hold truncated/absent payloads, paste must fetch the full entry. Add `ClipboardStore.materializedEntry(id:) -> ClipboardEntry?` (public wrapper over the existing private `materialized`). Inject a `clipboardResolver: (UUID) -> ClipboardEntry?` closure into `LaunchService` (wired by `AppCoordinator` to `clipboardStore.materializedEntry(id:)`), defaulting to `nil`. `pasteEntry` resolves the full entry by `entry.id` (falling back to the passed light entry if the resolver is nil / returns nil), then writes the full representations exactly as today. The same resolver backs D3's image load.

- *Why a closure seam, not injecting `ClipboardStore` into `LaunchService`?* `LaunchService` is a MLX-free fire dispatcher with no store dependency; a closure keeps it decoupled and its paste logic unit-testable with a stub resolver. Mirrors existing `on…` closure seams (`onAutomation`, `onAICommand`).
- *Correctness:* the fired id is the entry id (`LaunchItem.id == entry.id`), which is stable across rebuilds, so the resolver always finds the live full entry.

### D5 — Bounded, once-computed preview render
`ClipboardValueView` for textual kinds:
- Renders `entry`'s (already-bounded) plain text, decoded **once** (a stored/`let` value, not a recomputed computed-property call per body eval), capped defensively with `.lineLimit(previewLineCap)`.
- Computes `monospaced` **once** over the bounded text.
- When the entry `isTruncated`, shows an unobtrusive footer ("Preview truncated — the full content will be pasted."), so the user understands the pane isn't the whole payload but paste is faithful.

`isTruncated` is a transient, band-only marker. Rather than add a stored field to the persisted `ClipboardEntry`, it is derived at band-build time and carried on the light entry. Options: (a) a non-persisted `isPreviewTruncated` var defaulted false and never encoded; (b) reuse an existing signal. Chosen: **(a)** a `var isPreviewTruncated: Bool = false` on `ClipboardEntry` excluded from `Codable` (custom coding keys omit it), keeping the on-disk schema unchanged.

### D6 — Off-main persistence
`ClipboardStore.insert` keeps the in-memory update (`dedup` → `evict`) **synchronous on the MainActor** (so the next `bandWindow` build sees the new entry immediately), but moves `save()`'s disk work — blob externalization writes + the `index.json` atomic write + orphan pruning — onto a **serial background** context so a large blob write never blocks capture. Saves are serialized (a serial queue / actor) to preserve last-writer ordering; the encoded snapshot is captured on the main actor before handoff so the background writer sees a consistent set. `load()` stays synchronous at init.

- *Why not fully async `insert`?* The band and dedup must observe the new entry synchronously; only the I/O is deferred.
- *Simplicity option:* if serializing proves fiddly under `@MainActor`, an acceptable v1 is to keep `save()` on-main but (i) hashed fingerprints already shrink the index to sub-millisecond encodes and (ii) write only *new* blobs (already the case via `fileExists`). The remaining cost is the single large blob write; deferring just that write off-main is the minimum. Design target is D6; fall back to "defer blob writes only" if needed.

### D7 — Defensive capture cap
`ClipboardMonitor.capture` skips recording a single payload whose total bytes exceed a hard `maxCaptureBytes` ceiling (default well above normal copies, e.g. 64 MB, and ≥ the retention byte-cap makes little sense per-item — a per-item ceiling independent of the aggregate `maxBytes`). A skipped over-cap copy is simply not recorded (no partial/corrupt entry). Keeps the store from ever ingesting a pathological multi-hundred-MB copy.

## Risks / Trade-offs

- **Truncated preview surprises the user** → Mitigated by the D5 footer making truncation explicit and clarifying that paste is full. Cap sized generously (a few KB / many lines) so ordinary multi-line snippets show whole.
- **Image preview now async (brief spinner on scrub)** → Mitigated by `.task(id:)` cancellation and downsampling; matches the existing `FilePreview` async pattern, and the alternative (holding full image bytes for every band item) is the crash we're fixing.
- **Resolver returns nil (store cleared/evicted mid-session)** → `pasteEntry` falls back to the light entry's own (bounded) representations; worst case a truncated text pastes, which is strictly safer than a crash. Rare (fire happens moments after open).
- **Fingerprint change creates a transient duplicate** for content re-copied across the upgrade boundary (D1) → non-destructive, self-heals via eviction; no user-visible corruption.
- **Off-main save ordering bugs** (D6) → Mitigated by serializing saves and snapshotting on the main actor; fallback path (defer only blob writes) bounds the blast radius if the full async proves risky.
- **Backward compatibility** → `index.json` schema is unchanged (fingerprints are still strings; the transient `isPreviewTruncated` is not encoded); old indexes load as-is. No migration needed.

## Migration Plan

1. Land the pure/bounded helpers (`hash` fingerprints, `boundedForBand`, `previewByteCap`, `maxCaptureBytes`) with unit tests — no behavior change to persisted data.
2. Swap the band build to `bandWindow` + wire the resolver seam; keep `recentWindow` for device-link.
3. Bound the preview render + on-demand image load.
4. Move persistence off-main (or fall back to deferring blob writes).
5. Verify with `swift build` / `swift test`; the user validates the real freeze/crash repro (paste a multi-MB text, open + scrub the band, fire it) in their signed build.

Rollback: revert the change; on-disk data remains readable (schema unchanged), only newly-recorded entries carry hash fingerprints, which the reverted code also handles (it treats fingerprints opaquely).

## Open Questions

- Exact cap values (`previewByteCap`, `previewLineCap`, `maxCaptureBytes`) — pick sane defaults now (e.g. 16 KB / ~500 lines / 64 MB); tune after the user tries the repro. Promote to `AppSettings` only if requested.
- Whether to persist a small cached image thumbnail (spec already permits "cached thumbnails") to make image preview synchronous too — deferred; the on-demand downsample (D3) is sufficient for v1.
