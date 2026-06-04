## Context

`cross-space-windows` made `snapshot()` return all-Spaces windows (each `WindowInfo` carries `spaceID` + `isOnCurrentSpace`) and the overlay shows them as one flat row. The recognizer currently hard-axis-locks: after activation it tracks only horizontal travel and ignores vertical. On-device testing confirmed the key enabler: once the gesture starts horizontal, macOS does not fire Mission Control on subsequent vertical motion, so the vertical channel is available post-activation.

## Goals / Non-Goals

**Goals:**
- Left/right scrubs windows within the current Space-row; up/down switches Space-rows; lift commits.
- A *fresh* three-finger up/down still triggers Mission Control / App Exposé.
- Smooth, deliberate row switching that doesn't trigger on horizontal-scrub jitter.

**Non-Goals:**
- Live OS Space switching during scrub (only at commit).
- Per-display Space semantics (v1 uses the single global ordered Space list).
- Changes to enumeration/raising (done in the substrate).

## Decisions

### D1 — 2D only after horizontal activation
Activation still requires horizontal dominance (axis-lock decides horizontal vs. vertical-yield as today), so a fresh vertical gesture is never claimed and still reaches the OS. Only *after* the overlay activates does the recognizer begin tracking vertical travel for row steps. This preserves the original "fresh up/down = Mission Control" contract.

### D2 — Separate vertical accumulator with a larger threshold + carry
Maintain `stepAccumulatorY` independent of the horizontal `stepAccumulator`. Emit a row step (`gestureDidStepRow(±1)`) each time `|stepAccumulatorY| ≥ rowStepDistance`, subtracting with carry. `rowStepDistance` defaults larger than the horizontal `stepDistance` (≈0.12 vs 0.05) so ordinary horizontal scrubbing (with small vertical wobble) does not flip rows. Reversal steps back. Direction honors `reverseVerticalDirection` (OMS y-axis sign normalized so "up" = next by default).
- *Alternative considered*: re-lock to a single dominant axis per increment. Rejected — feels notchy and prevents the fluid "curve from horizontal into vertical" the user demonstrated.

### D3 — Grid model layered on the existing strip
`SwitcherModel` gains `rows: [[WindowInfo]]`, `currentRow`, `selectedColumn`, and Space labels. `windows` and `selectedIndex` become computed (`rows[currentRow]`, `selectedColumn`) so the existing card strip, adaptive width, thumbnails, and highlight keep working unchanged. Grouping: bucket the flat snapshot by `spaceID` preserving Space order, drop empty buckets, start `currentRow` at the bucket whose windows are `isOnCurrentSpace`.

### D4 — Row change resets the column and prefetches
On a row step, clamp (or wrap per setting) `currentRow`, reset `selectedColumn` to 0, and prefetch that row's thumbnails. Commit raises `rows[currentRow][selectedColumn]`; because that window carries its Space, the raise switches Spaces once.

### D5 — Overlay row affordance
Render the current row's cards as today, plus a compact row indicator (dots or "Space N / M") so the user knows which row they're on and that more exist above/below. Animate vertical row swaps. Neighbor-row peek is optional polish, not required.

## Risks / Trade-offs

- **[Vertical threshold tuning]** Too low → accidental row flips during horizontal scrub; too high → unresponsive. → Separate larger `rowStepDistance` + carry + on-device tuning task.
- **[Diagonal activation]** A diagonal initial move could mis-pick the axis. → Activation keeps the existing axis-lock ratio (horizontal must dominate to activate); vertical is only tracked after.
- **[Fresh vertical must still reach the OS]** → Vertical is tracked only post-activation; pre-activation vertical yields exactly as today.
- **[Single-Space users]** With one Space-row, up/down is a no-op (clamped); behavior is identical to today.

## Refinements (from on-device testing)

- **Finger-count debounce (D6).** Swiping toward the trackpad edge can briefly flicker a finger to a non-contact state, which previously read as a lift and committed/closed the overlay. The recognizer now ends only on a true 0-finger lift or a count below 3 sustained for ≥2 frames; a 1–2 frame dip is ignored. (A genuine all-fingers lift at the edge is physical — mitigated by lowering `rowStepDistance`.)
- **Animated row switching (D7).** The container resizes between Space-rows via `NSAnimationContext` on the panel's animator (0.32s ease-in-out), and the strip slides directionally (up → next Space enters from the bottom; down → previous enters from the top) with a matched 0.32s vertical move+fade, clipped to the container.
- **Vertical row indicator (D8).** The Space-row dots are a vertical column inside the container's left edge (reserved gutter so they never overlap the first card), with the current Space at the bottom so swiping up moves the highlight upward.
