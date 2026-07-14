## Why

Copying or previewing a large text clipboard item freezes the app for ~1s and, when the item is large enough, crashes it outright. The cost of every clipboard operation currently scales with the payload size in three independent places — capture, band build, and preview render — so a single big copy stalls the main thread and blows up memory. Clipboard history is supposed to be invisible background plumbing; today a large copy makes the whole app janky or dead.

## What Changes

- **Bound the de-dup fingerprint.** Stop embedding the raw copied text into an entry's `fingerprint` (`"text:\(str)"`). Derive it from a content **hash** instead, so the on-disk index and de-dup comparisons never scale with payload size. This alone removes the per-copy "re-encode the whole history" stall.
- **Make the Clipboard band lightweight.** Building the band SHALL NOT materialize every windowed entry's full payload into memory. Band items carry only metadata + a **bounded preview** (text truncated to a cap; images loaded on demand), so opening the band with several big items no longer OOM-crashes.
- **Bound the value preview.** The right-hand preview renders at most a capped amount of text (with a "showing a preview / full content will paste" affordance) instead of laying out the entire string in a non-virtualized SwiftUI `Text`. Decoding/scanning the payload happens once, not on every body evaluation.
- **Materialize the full entry only on demand.** Pasting a fired entry restores its **full** stored representations (fetched from the store by id at fire time), so faithful paste is preserved even though the band only ever held a bounded preview. Large images render in the preview via an on-demand, downsampled, one-at-a-time load.
- **Persist off the main thread.** Externalizing a large payload to a blob and writing the index SHALL NOT block the capture (main) thread, so a big copy never stalls the UI.
- **Defensive capture cap.** Refuse to record a pathologically large single payload (a hard byte ceiling above the retention byte-cap), consistent with the existing count/byte/age retention caps.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `clipboard-history`: Adds a bounded-resource guarantee for large entries and tightens four existing requirements — fingerprints become bounded (hash, not raw content); on-disk storage externalizes large **text** (not only images) and keeps the index small regardless of payload size; the synthetic band builds from bounded previews without loading full payloads and renders a bounded preview that never freezes/crashes; and paste-on-fire restores the full representations materialized on demand.

## Impact

- **Code:**
  - `Sources/ThreeFingerSwitcher/Clipboard/ClipboardMonitor.swift` — hash-based fingerprints; defensive capture cap.
  - `Sources/ThreeFingerSwitcher/Clipboard/ClipboardStore.swift` — new `bandWindow(limit:)` returning light entries; `materializedEntry(id:)` for on-demand full fetch; off-main persistence.
  - `Sources/ThreeFingerSwitcher/Clipboard/ClipboardBandBuilder.swift` — build from light entries.
  - `Sources/ThreeFingerSwitcher/Overlay/ClipboardBandView.swift` — bounded text preview (once-computed, capped) + on-demand downsampled image load.
  - `Sources/ThreeFingerSwitcher/Launcher/LaunchService.swift` — resolve the full entry by id before paste (injected clipboard resolver seam).
  - `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` — wire the band-window + resolver seam; `recentWindow` (full materialize) stays for the device-link outbound path.
- **Data:** on-disk `index.json` shrinks (no raw-text fingerprints); large text moves from the index into blob files. Backward-compatible — existing indexes load unchanged; fingerprints simply differ for entries recorded after the change (a legacy raw-text fingerprint still de-dups against itself, only a re-copy re-keys it, which is harmless).
- **Specs:** `openspec/specs/clipboard-history/spec.md`.
- **No new permissions, no gesture relocation, no re-login.** MLX-free Core → verifies under `swift build` / `swift test`.
