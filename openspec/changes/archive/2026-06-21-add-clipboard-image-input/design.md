## Context

The on-device vision stack is already complete: `GemmaMLXRuntime` decodes PNG bytes → pixel tensors → soft tokens, `LLMRequest` carries `image: Data?`, `ModelManager.runtime(requiring:)` does capability-based selection, the model registry advertises `[.text, .vision]`, and seven Vision presets (`input: .screenRegion`, `output: .previewOnly`) stream into the preview canvas. The **only** image-acquisition path is `SelectionService.captureScreenRegion()`.

The clipboard text path (`AICommand.input == .clipboard`) reads the **live system pasteboard** via `SelectionService.readClipboardText()` — *not* the stored `ClipboardStore` history band. There is no symmetric image read, so an image on the clipboard is invisible to the AI. This change adds that symmetric path.

## Goals / Non-Goals

**Goals:**
- A vision command can read the image currently on the clipboard and stream a grounded result into the canvas, **on demand**.
- Static, content-independent capability routing is preserved (model selection must not depend on what happens to be on the clipboard at fire time).
- No new permission, no new dependency, no auto-trigger; stays MLX-free Core (`swift test`-able).

**Non-Goals:**
- **Auto-trigger on copy** — copying an image never spins up the model (decided on-demand). 
- **Polymorphic `.clipboard`** (image-if-present-else-text).
- Firing a vision command against a *stored* Clipboard-band **history** entry (future extension; this reads the live pasteboard, exactly like `.clipboard` text does).
- Multi-image input, PDF/other media, or non-PNG/TIFF formats.

## Decisions

**1. A distinct `.clipboardImage` input source — not a polymorphic `.clipboard`.**
`AICommand.requiredCapabilities` is derived *statically* from `input` (`.screenRegion → [.vision]`, everything else `[.text]`). Making `.clipboard` polymorphic would make required capabilities depend on runtime clipboard contents, which (a) breaks content-independent model selection — the manager couldn't know whether to load the multimodal graph until fire time — and (b) muddies the "no input" fallback (text-vs-image ambiguity). A separate `.clipboardImage` source keeps the mapping static: `.clipboardImage → [.vision]`, identical to `.screenRegion`. *Alternative considered:* overload `.clipboard` — rejected for the dynamic-capability mess.

**2. Read the live pasteboard, symmetric with text.**
`SelectionService.readClipboardImage() -> Data?` reads `NSPasteboard.general`, preferring `public.png`, falling back to `public.tiff`, and returns normalized **PNG** bytes. This mirrors `readClipboardText()` and feeds the runtime exactly the PNG bytes its image processor already decodes (via `CGImageSourceCreateWithData`). It deliberately does **not** touch `ClipboardStore`, keeping the `clipboard-history` capability out of scope.

**3. PNG normalization at the boundary.**
Some apps put only TIFF on the pasteboard. Normalize TIFF → PNG via `NSBitmapImageRep` so the runtime contract is always "PNG bytes." If image data exists but cannot be normalized/decoded, treat it as **no image** (yield nil) rather than passing garbage to the model.

**4. No text fallback for an image source.**
Unlike `.selection → clipboard`, an image command has no sensible text fallback. When the pasteboard holds no image, acquisition yields nil and the executor surfaces the **existing "no input" state** (the model is not invoked) — symmetric with how an input-requiring text command behaves on empty.

**5. Presets mirror the screen-region Vision presets.**
Add clipboard-image presets to the **Vision** category with `input: .clipboardImage`, `output: .previewOnly` — at minimum "Describe Clipboard Image" and "Clipboard Image → Text (OCR)". They reuse the same prompt templates as their screen-region cousins; only the input source differs.

## Risks / Trade-offs

- **Two image sources may confuse users** → preset naming carries the source ("… Clipboard Image" vs. the screen-region names); both live in the Vision category so the relationship is visible.
- **Large clipboard images (memory/latency)** → no new exposure: the runtime already accepts arbitrary-size PNG and caps soft tokens in the image processor; same envelope as screen-region capture.
- **Pasteboard mutates between fire and read** → acquisition reads once at fire time inside `acquireInput`; good enough (matches the text path's single live read).
- **A non-image clipboard fired at an image command** → yields nil → clean "no input" state, never a model run on empty.

## Open Questions

- Should a later slice let a user fire a vision command directly against a **stored** Clipboard-band image entry (the `.clipboardEntry` item), not just the live pasteboard? Deferred — the band-entry firing path could carry an image then. Out of scope here.
