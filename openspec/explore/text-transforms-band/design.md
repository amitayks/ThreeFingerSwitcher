# Text Transforms Band — design exploration

> Status: **explore seed.** No proposal/specs/tasks yet. Promote to `openspec/changes/` when ready.

## Context

The cheapest member of the "verbs on your selection" axis, and the natural **warm-up for the AI band**: a launcher band of **pure-local text transforms** that act on whatever you have selected in the front app — no network, no API key, **no new permission** (reuses the Accessibility we already hold). It proves out the exact pipeline the AI band needs — *read selection → transform → write back* — minus the model. Where the AI band's verb is an LLM call, here the verb is a deterministic, unit-testable function.

This is on-brand in a way the AI band isn't: 100% on-device, instant, private, zero cost, and it keeps the "pure trackpad" identity (pick a verb, act on context).

## Goals / Non-Goals

**Goals:**
- A band whose items are text transforms; scrub to one, lift, it rewrites the current selection in place (or copies the result).
- Read the selection via AX `AXSelectedText`; write it back via AX (settable) or paste fallback.
- A solid starter set, each a **pure function** (so they're trivially tested, like `LaunchService.targetLevel` / the clipboard store logic):
  - **Case:** UPPER, lower, Title, Sentence, tOGGLE
  - **Encode/decode:** base64 ⇄, URL-encode ⇄, HTML-entities ⇄
  - **JSON:** pretty-print, minify
  - **Lines:** sort (A→Z / Z→A), dedupe, reverse, shuffle, trim trailing whitespace, join/split
  - **Slug/format:** slugify, smart-quotes ⇄ straight, collapse whitespace, strip markdown → plain
  - **Wrap:** quote / code-fence / bracket the selection
  - **Count:** chars / words / lines → result (paste, or a brief HUD)
- Reuses the band + hand-off substrates verbatim; the only new piece is the selection read/write helper (shared with the AI band).

**Non-Goals:**
- No model, no network, nothing that leaves the device.
- Not a general scripting surface (that's the existing `.script` item kind). These are curated, safe, in-place text ops.
- No freeform input (keyboardless) — the transform set is the interface.

## Decisions (proposed)

### Selection read/write helper (shared substrate with the AI band)
A small AX helper:
- **Read:** `AXSelectedText` of the focused element of the captured front app. Fallback: synthesize ⌘C, snapshot pasteboard, **restore** the prior clipboard afterward (don't clobber).
- **Write:** set `AXSelectedText` when settable (clean, no clipboard touch); else set the general pasteboard to the result and synthesize ⌘V (the `LaunchService` paste muscle).
This helper is the single dependency both this band and the AI band sit on — building it here de-risks the AI band.

### Transforms are pure functions behind a registry
Each transform: `(String) -> String`, registered with a name/icon. The band renders the registry; firing applies `fn(selection)` and writes back. Pure ⇒ unit-tested without any app, matching the project's testing discipline.

### Output: replace in place, default
Default `.replaceSelection`. A per-transform option for `.copyResult` (e.g. "count words" → put the number on the clipboard / show a HUD rather than replace the prose).

### Graceful "no selection"
If there's no selection (empty `AXSelectedText`), fall back to the **clipboard** as input (transform the clipboard), or show a tiny "nothing selected" hint — never error.

## Risks / Trade-offs

- **App doesn't expose `AXSelectedText`** (some Electron/web views) — fall back to ⌘C-with-restore; if even that yields nothing, no-op with a hint.
- **Writing back where AX set isn't supported** — paste fallback; in apps that intercept paste oddly, the result still lands as a normal paste.
- **Destructive replace** — it's just text and the app's own Undo (⌘Z) recovers it; still, "replace" should feel safe (it's the user's selection, by their gesture).
- **Encoding edge cases** (non-UTF8, huge selections) — bound the size; transforms operate on strings, so binary selections simply aren't applicable.

## Open Questions

- **Replace-in-place vs. preview-then-commit** — do simple transforms commit immediately on lift (fast), while the AI band uses the preview pane (review)? Probably yes: transforms are deterministic and Undo-able, so instant is better UX.
- **Which transforms ship v1** vs. a longer tail behind a "more…" — keep the band scannable.
- **Surfacing results that aren't replacements** (counts) without a keyboard/HUD — a brief overlay toast, or write to clipboard?
- **Should this and the AI band be one band** ("Edit") with local transforms + AI verbs interleaved, or two? (Local = instant/in-place; AI = streamed/preview — different commit UX argues for two, or a visual split.)
- **User-defined transforms** — expose a "custom transform = a shell filter" (selection piped through a command), bridging to the existing `.script` kind?
