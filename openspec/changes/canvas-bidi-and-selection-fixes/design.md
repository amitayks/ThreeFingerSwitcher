# Design — canvas bidi + selection fixes

## Fix 1 — first-strong, per line, stable

```
per line:  base direction = direction of the FIRST strong char (first word/char), then FIXED
           "AICommand שומר"  → first strong 'A' → LTR  (stays LTR as Hebrew follows)
           "שומר AICommand"  → first strong 'ש' → RTL  (stays RTL as Latin follows)
```

### D1 — Why first-strong (not dominant)
The user's explicit rule: the line's side is decided by how it *starts*, and must not change based on characters that arrive later. Dominant/majority (the prior attempt) re-decides from the whole line, so a streaming line flips alignment mid-arrival — jarring, and against the rule. First-strong reads the first strong char and stops; appending content never changes that char, so the side is stable. The one legitimate transition is a line that begins with neutrals (a number, a bullet, whitespace): it stays LTR-default until its first strong char streams in, then locks. That is "deciding," not "re-deciding," and preserves the existing streamed-content requirement.

### D2 — All RTL scripts
`isStrongRTL` is one contiguous range `U+0590–U+08FF` (Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic Extended-A/B) plus presentation forms `U+FB1D–U+FB4F`, `U+FB50–U+FDFF`, `U+FE70–U+FEFF`. Strong-LTR is "alphabetic and not in an RTL block." Digits/punctuation/whitespace are neutral (skipped). `dominantDirection` is deleted; `firstStrongDirection` + `naturalTextDirection` are the only base-direction paths.

## Fix 2 — read the selection before the panel takes key

### D3 — The bug is an ordering race
```
handleFire (AI):  onFire → executor.fire()          // schedules run() as a Task — read happens LATER
                  setCanvasInteractive(true)          // makeKeyAndOrderFront — SYNCHRONOUS, runs FIRST
main actor free:  run() → readSelectedText()          // panel is already key ⇒ front app not key ⇒ read empty
```
A `.nonactivatingPanel` becoming key doesn't activate our app, but it *does* take the system key window from the captured front app. With that app no longer key, `AXFocusedUIElement`→`AXSelectedText` is empty and a ⌘C posted to its PID doesn't land — so `readSelectedText()` returns nil and the ambient cascade falls through to the clipboard. This is the "doesn't recognize the selection" report.

### D4 — Defer key-focus until after the read (a callback, not a delay)
The executor knows exactly when the read is done (it just did it). So it calls `onReadyForInteraction()` right after acquisition; the controller makes the panel key **then**. No fixed delay, no polling. The panel is pass-through in the meantime — fine, because there is nothing to scroll/tap yet (the model hasn't produced output), and the four-finger swipe-to-resolve rides the multitouch device, not window events, so commit/discard keep working. For the `.unavailable` state (no read happens) the hook fires immediately so Enable/Download stay clickable. `makeCanvasInteractive()` is guarded on `model.canvasActive` so a hook that arrives just after a fast discard is a no-op.

### D5 — Retain the acquired input for a language re-run
Once the user opens the language pill, the panel *is* key (they clicked it) — so a `setLanguage` re-fire must NOT re-read the selection (it would fail exactly as in D3). The executor retains the first fire's `Acquisition` and `setLanguage` passes `reuseInput: true`, so a re-translate reuses the same source. Bonus correctness: it re-translates the *original* text even if the selection changed since. Mirrors how `presuppliedCapture` is already retained for a vision re-translate. A fresh fire (`reuseInput: false`) always clears the retained value and re-reads.

### D6 — Why not just drop `makeKeyAndOrderFront`?
Relying on click-to-key (`canBecomeKey = true`) alone risks the SwiftUI language `Picker`/unavailable buttons needing two clicks (first focuses the window, second acts) or not opening from a non-key window. Deferring the *proactive* key-grab past the read keeps the exact interaction behavior the canvas had, and only moves *when* it happens — the low-risk change.

## Verification note
The heuristics and the acquire/retain/hook logic are pure/observable and unit-tested. The actual AX selection read and RTL `NSTextView` rendering ride system APIs that can't be exercised headless — final confirmation is on the user's signed build (fire a command with text selected → it uses the selection and a down-swipe replaces it; fire with nothing selected → clipboard + paste; fire a Hebrew translation → each line anchors to its first word).
