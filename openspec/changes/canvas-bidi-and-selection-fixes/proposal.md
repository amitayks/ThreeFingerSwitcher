## Why

Two defects surfaced while using the AI preview canvas with real bilingual content (Hebrew/English screenshot):

1. **Line direction was unstable.** An earlier attempt keyed each paragraph's base direction off its *dominant* script, so a line could flip alignment (LTR↔RTL) as more characters streamed in. The user's rule is the opposite and simpler: **a line's direction is decided by its first word/char and then held fixed** — it must not re-decide from characters that arrive later in the sentence. (First-strong, per line, stable.) Separately, RTL detection only covered Hebrew/Arabic, not "all RTL languages."

2. **The app doesn't recognize selected text — it falls back to the clipboard.** When an AI command fires, the canvas panel calls `makeKeyAndOrderFront` to become key-interactive (for the language pill / Enable+Download controls). That runs *synchronously* at fire, while the executor's selection read runs *asynchronously* a moment later — so the non-activating panel grabs key focus **before** the read. With the captured front app no longer key, its AX focused element is empty and the ⌘C fallback doesn't land, so `readSelectedText()` returns nothing and the input silently cascades to the clipboard. The context-resolution work fixed the *logic*; this fixes the *timing* that was starving it.

## What Changes

**Fix 1 — per-line first-strong base direction, stable, all RTL scripts** (`BidiText.swift`):
- The per-paragraph base direction + alignment is chosen by the paragraph's **first strong directional character** (the first word/char decides the side). Leading neutrals (whitespace, a number, a bullet) are skipped to that first strong char; once it is present the side is **stable** — later characters never re-decide it. (The dominant/majority heuristic is removed.)
- RTL detection is broadened to **all RTL scripts** — the contiguous `U+0590–U+08FF` block (Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic Extended) plus the Hebrew/Arabic presentation-form blocks — so any RTL/LTR language is honored, not just Hebrew/Arabic. `naturalTextDirection` (short review-field values) uses the same rule. Mixed runs within a paragraph still resolve via the Unicode Bidi algorithm.

**Fix 2 — read the selection before the canvas panel takes key focus** (`AICommandExecutor`, `LauncherOverlayController`, `AppCoordinator`):
- The canvas panel stays **pass-through (non-key)** at fire; it becomes key-interactive only **after** the executor has read the fire's input, via a new `onReadyForInteraction` callback the executor invokes once acquisition completes (and immediately for the `.unavailable` state, whose Enable/Download controls need the mouse). So the selection is read while the captured front app still holds key focus.
- The executor **retains the acquired input**; a language re-run (`setLanguage`) **reuses** it (`reuseInput`) instead of re-reading the selection — which would now fail, since by then the user has interacted with the language pill and the panel holds key. This also makes a re-translate use the exact same source, not a since-changed selection.

**Fix 2b — the ⌘C fallback actually lands** (`SelectionService`; found via on-device `[Selection]` logging):
- With the ordering fixed, on-device logs showed the remaining failure: for an AX-opaque app (Terminal), the ⌘C fallback was posted to the app's PID **without activating it**, so it never processed the copy (`changeCount advanced=false`) and the input fell through to the clipboard. The copy path now **re-asserts the captured app as frontmost** (`activate` + settle) before synthesizing ⌘C — exactly what the working paste path already does for ⌘V.
- **Secure Keyboard Entry** (Terminal's, or any app's) blocks synthesized keystrokes system-wide; the fallback now **detects and logs** this (`IsSecureEventInputEnabled()`) so it is diagnosable rather than a silent clipboard fall-through.
- A `Selection`-category `os.Logger` across the read path (kept for now) makes the whole chain observable in Console: which app, whether AX exposed a selection, whether the ⌘C landed, and which channel won.

## Capabilities

### Modified Capabilities

- `launcher-overlay`: the "Bidirectional (RTL/LTR) text rendering" requirement is restated as **first-strong per line, stable, covering all RTL scripts** (replacing the short-lived dominant-direction wording); a new requirement states the **canvas panel takes key focus only after the fired command's input is read**, and a language re-run reuses the acquired input.
- `selection-io`: the "Clipboard fallback with restore" requirement gains **activate-the-captured-app-before-⌘C** (a ⌘C posted to a non-active app doesn't land) and **Secure-Keyboard-Entry detection** (a system-wide synthetic-key block is surfaced/logged, not a silent success).

## Impact

- **Code (MLX-free Core):** `Overlay/BidiText.swift` (first-strong base direction, broadened `isStrongRTL`; `dominantDirection` removed); `AI/AICommandExecutor.swift` (`onReadyForInteraction` hook, `Acquisition` refactor of the input read, `retainedAcquisition` + `reuseInput`); `Overlay/LauncherOverlayController.swift` (defer `setCanvasInteractive` → new guarded `makeCanvasInteractive()`); `App/AppCoordinator.swift` (wire the hook).
- **Tests:** `BidiTextDirectionTests` (first-strong decides + is stable as content appends, leading-neutral skip, all-RTL-scripts, neutral→LTR, class guards); `AICommandExecutorTests` (the interaction hook fires once after acquisition; a language re-run reuses the retained input rather than re-reading a changed selection).
- **No gesture/permission/signing/model impact.** The two-finger resolve grammar is unchanged; the four-finger swipe-to-resolve already rides the multitouch device, so it keeps working while the panel is pass-through. Verified under `swift build`/`swift test`; the live selection read + RTL rendering ride AX/`NSTextView` and are confirmed on the user's signed build.
- **Out of scope:** markdown rendering of the model's output (`**`, `$\rightarrow$` are a model artifact); the notch conversation surfaces (same `BidiText` benefits from Fix 1 automatically; its own key-focus timing is not in scope here); any change to how `SelectionService` reads (AX-then-⌘C) — only *when* it runs relative to the panel taking key.
