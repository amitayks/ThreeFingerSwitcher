## 1. Input source model

- [x] 1.1 Add `clipboardImage` case to `AICommand.InputSource` (Codable; preserves existing raw values / decoding of the other cases).
- [x] 1.2 Extend `AICommand.requiredCapabilities` so `clipboardImage` returns `[.vision]` (statically, alongside `screenRegion`); all other cases unchanged.
- [x] 1.3 Add/adjust unit tests asserting `requiredCapabilities` for each input source, including `clipboardImage → [.vision]`.

## 2. Clipboard image read (selection I/O)

- [x] 2.1 Add `SelectionService.readClipboardImage() -> Data?` reading `NSPasteboard.general`: prefer `public.png`, fall back to `public.tiff`, normalize to PNG via `NSBitmapImageRep`; return nil when no image / undecodable. Reads the live pasteboard only (no `ClipboardStore`).
- [x] 2.2 Keep the read AppKit-side; expose it through the same seam the executor already uses for `readClipboardText()` so the pure model/tests stay AppKit-free. (Added `imageData()` to the `PasteboardAccess` seam; `readClipboardImage()` on `SelectionProviding`; PNG normalization in the pure `normalizedPNG(from:)` static.)
- [x] 2.3 Tests: PNG present → PNG bytes; TIFF-only → normalized PNG; no image → nil; non-image text on clipboard → nil. (+ pure `normalizedPNG` nil/empty/garbage cases.)

## 3. Executor acquisition

- [x] 3.1 In `AICommandExecutor.acquireInput`/run, handle `clipboardImage`: read the clipboard image into the request's `image:`; do **not** fall back to text.
- [x] 3.2 When `clipboardImage` yields no image, transition to the existing "no input" state (model not invoked) — same surface as the text no-input path.
- [x] 3.3 Build the `LLMRequest` with the acquired image so capability routing selects a vision model (reuse existing `runtime(requiring:)`).
- [x] 3.4 Tests (CapturingLLMRuntime with `.vision`): clipboard image → vision request fired carrying the image; empty clipboard → "no input" state, no runtime call.

## 4. Catalog presets

- [x] 4.1 Add clipboard-image presets to the Vision category in `AICommandCatalog` with `input: .clipboardImage`, `output: .previewOnly` — "Describe Clipboard Image" and "Clipboard Image → Text (OCR)".
- [x] 4.2 Test: catalog enumerates ≥1 Vision preset with input `clipboardImage`, each complete/fireable. (Relaxed the existing `testVisionPresetsArePreviewOnlyScreenRegion` → accepts both image sources + asserts `[.vision]`.)

## 5. Verify

- [x] 5.1 `swift build` and `swift test` green (Core + tests) — 920 tests, 0 failures; 11 new tests pass.
- [x] 5.2 `openspec validate --strict` passes; spec deltas match implementation. (`/opsx:verify` is the deeper, user-invoked check.)
- [x] 5.3 Update CLAUDE.md's stale "No vision in v1" note (confirmed with maintainer): now describes vision support, the `.screenRegion` / `.clipboardImage` inputs, and points the picker work at `add-region-capture-picker`.
