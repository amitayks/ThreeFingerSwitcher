# Design — context-driven AI action resolution

## The one-line model

`AICommand` stops storing *what to do* and starts storing *what it's allowed to do*. Two capability sets (`inputs`, `outputs`), default all-on. At fire time the executor **senses the live environment**, resolves the active input channel and the commit behavior from it, and picks the model capability from the chosen input. Toggles are guardrails on an automatic decision, not the decision.

```
ENVIRONMENT (sensed at fire)         COMMAND (capability toggles, default all-on)
  • selection present?               inputs  : {selection, clipboard, clipboardImage}
  • clipboard text?                  outputs : {replaceSelection, pasteAtCursor, previewOnly}
  • clipboard image?                 (or a side-effect: {runTask(k)} / {sendTo(d)})
        │
        ▼
  RESOLVE INPUT  ── first ENABLED channel that is live, by priority:
                    selection ▸ clipboardText ▸ clipboardImage ▸ (none)
        │
        ▼
  PICK MODEL     ── resolved channel is an image ⇒ vision, else text
        │
        ▼
  RUN + STREAM into the canvas (unchanged)
        │
        ▼
  RESOLVE OUTPUT ── in-place: wasSelection && replaceSelection enabled → REPLACE
                             else pasteAtCursor enabled → PASTE
                             else previewOnly → write nothing
                    side-effect: accept-step → execute (unchanged)
        │
        ▼
  two-finger DOWN commits the resolved behavior · horizontal ALWAYS discards
```

## Decisions

### D1 — Input priority: `selection ▸ clipboardText ▸ clipboardImage`
Text beats image when both exist: text is the overwhelming common case and cheaper, and it keeps a plain "Fix Grammar" a text run. The image channel engages only when there is **no usable text anywhere** — which is exactly the "the last thing I copied is an image" case. Selection always wins over the clipboard (it is the most intentional signal). A command narrows this by disabling channels: a "Describe image" command turns the text channels **off** so only the image channel can win, regardless of a stray selection.

### D2 — Output is resolved from the input channel, not stored
For an in-place command the commit is derived, not fixed:
```
if resolvedWasSelection && outputs.contains(.replaceSelection)  → replace selection
elif outputs.contains(.pasteAtCursor)                            → paste at cursor
elif outputs.contains(.replaceSelection)                         → replace (SelectionService pastes if no live selection)
elif outputs.contains(.previewOnly)                              → write nothing
else                                                             → write nothing (safe default)
```
This is what makes "swipe down replaces my selection **or** pastes at my cursor" a single behavior. `previewOnly` present without replace/paste = a read-only understanding command. Disabling `replaceSelection` = "never touch my selection, always paste."

### D3 — Model capability is resolved at runtime (reverses the old static rule)
The prior spec mandated `requiredCapabilities` be derived **statically** from the authored source and never depend on runtime clipboard contents. That is incompatible with "parse the clipboard image when one is present, else run text." So: the executor senses the input first, then requests `[.vision]` only when the **resolved** channel is an image, else `[.text]`. The command's `requiredCapabilities` becomes a **union hint** (does any enabled input *potentially* need vision?) used for informational/editor purposes — it no longer gates the model request. If the only live/enabled channel is an image and no vision model is available, the executor surfaces a clean `.failed` (not a silent text run).

### D4 — Screen region stays exclusive and region-first
`screenRegion` cannot be passively sensed — it needs the interactive picker to run **before** the canvas opens (existing `selection-io` / launcher flow). So a command whose `inputs` contain `screenRegion` is treated as a region command exactly as today (picker → capture → canvas → fire with the pre-supplied image); it is **not** blended into the ambient cascade. The editor presents `screenRegion` as mutually exclusive with the ambient channels. This keeps the region flow a pure rename (`command.input == .screenRegion` → `command.inputs.contains(.screenRegion)`), no behavior change.

### D5 — Persistence & skills migrate in place (no schema bump, no data loss)
`AICommand` gains a **custom `Codable`**: `init(from:)` decodes `inputs`/`outputs` when present, else the legacy `input`/`output` scalars, mapping each to a set; `encode(to:)` writes the sets. Legacy → set mapping (behavior-preserving):

| legacy `input`     | → `inputs`                       | legacy `output`        | → `outputs`                              |
|--------------------|----------------------------------|------------------------|------------------------------------------|
| `selection`        | `{selection, clipboard}`         | `replaceSelection`     | `{replaceSelection, pasteAtCursor}`      |
| `clipboard`        | `{clipboard}`                    | `pasteAtCursor`        | `{pasteAtCursor}`                        |
| `clipboardImage`   | `{clipboardImage}`               | `previewOnly`          | `{previewOnly}`                          |
| `screenRegion`     | `{screenRegion}`                 | `runTask(k)`           | `{runTask(k)}`                           |
| `none`             | `{}` (standalone)                | `sendTo(d)`            | `{sendTo(d)}`                            |

`selection → {selection, clipboard}` deliberately makes the old implicit selection→clipboard fallback **explicit** (and now honest: it pastes, not replaces). A **new blank** command defaults to `inputs = {selection, clipboard, clipboardImage}`, `outputs = {replaceSelection, pasteAtCursor, previewOnly}` (all-on). Catalog presets keep authoring with the legacy single `input:`/`output:` via a **convenience init** that runs the same mapping, so `AICommandCatalog`/`AIBand` change only their helper, not every entry. `SkillFile` serializes `inputs:`/`outputs:` (comma-joined) and still parses a legacy `input:`/`output:` line.

### D6 — Set element vocabulary reuses existing enums
`inputs: Set<InputSource>` reuses `InputSource` (its cases are already right); `.none` is represented by the **empty set**, never a member. `outputs: Set<OutputTarget>` reuses `OutputTarget`; a side-effecting `runTask`/`sendTo` is a single-element set, and the resolver prefers it when present. `InputSource`, `OutputTarget`, `TaskKind`, and `Destination` gain `Hashable` (all associated values are `String`/`Destination`, so it auto-synthesizes). No new top-level enum types — this keeps the skill serializer, the editor, and `requiredCapabilities` on one vocabulary and holds churn down.

## What does NOT change
The two-finger resolve grammar (DOWN commits at top / horizontal discards / UP scrolls), the one-shot "a fired command never becomes a conversation" contract, the region picker, the side-effecting accept-step, the model download/opt-in gate, and every non-AI surface. Only *which input is read* and *what DOWN does* become environment-resolved.
