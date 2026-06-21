## Why

The on-device vision runtime is already built end-to-end — Gemma 4 multimodal processes images, `LLMRequest` carries `image: Data?`, the model registry routes vision commands, and seven vision presets stream their results into the preview canvas. But the **only** way to feed it an image is a screen-region capture. The most common way people already "have an image they want to ask about" — a screenshot or picture copied to the clipboard — is invisible to the AI: the `.clipboard` input source reads **text only**. This adds the missing acquisition path so an existing vision command can read the image sitting on the clipboard.

## What Changes

- Add a **`clipboardImage`** input source to the AI command model. It **statically requires the `vision` capability** — kept a distinct source (not a polymorphic `.clipboard`) so model selection stays independent of clipboard contents at fire time.
- Add a **live-pasteboard image read** to selection I/O (`readClipboardImage()` → PNG bytes), symmetric to the existing live `readClipboardText()`. Reuses no new permission (reading the pasteboard is free).
- When a `clipboardImage` command fires, acquire the current pasteboard image as the request's `image:`. If the pasteboard holds **no** image, surface the existing **"no input"** state rather than running the model on nothing.
- Add at least one **clipboard-image preset** to the Vision category (e.g. "Describe Clipboard Image", "Clipboard Image → Text (OCR)").
- **On-demand only.** Copying an image never auto-triggers the model — you fire the command, it reads the clipboard.

## Capabilities

### New Capabilities

_None — the vision runtime, capability routing, and streaming canvas already exist; this is a new input-acquisition path on the finished downstream._

### Modified Capabilities

- `ai-command-band`: add the `clipboardImage` input source, its input-acquisition behavior, and its `vision` capability requirement.
- `selection-io`: read the current clipboard **image** as vision input (no new permission).
- `ai-command-catalog`: include at least one clipboard-image vision preset.

## Impact

- **Code:** `AICommand` (`InputSource`, `requiredCapabilities`), `SelectionService` (+ `readClipboardImage()`), `AICommandExecutor` (acquire image for `clipboardImage`), `AICommandCatalog` (presets).
- **No new dependency, no new permission, no gesture relocation, no model change** — the runtime already advertises and processes `vision`.
- **MLX-free Core**: verifiable under `swift build` / `swift test` with `StubLLMRuntime` (capabilities include `.vision`); no `xcodebuild`-only surface.
