## Why

An AI command today pins **one** input source and **one** output target at authoring time (two single-select dropdowns), and the executor obeys them literally. That produces two coupled failures:

- **The source is wrong in practice.** A command set to `selection` reads the selection via AX, and when AX can't expose it (the common case) it silently falls back to the user's **old clipboard** with no signal — so "run on my selected text" quietly runs on whatever was last copied.
- **The destination is dumb.** `replaceSelection` always replaces and `pasteAtCursor` always pastes, regardless of whether anything is actually selected — so the same verb can't "replace what I highlighted" *and* "paste where my cursor is" depending on context.

The user's mental model is that input and output are **one decision, driven by the live environment**: if there's a selection, work on it and **replace** it on commit; if there's nothing selected, take the **clipboard** (text *or* image) and **paste** the result at the cursor; a horizontal swipe always discards with no effect. And rather than hard-coding that as the only behavior, each command should expose its input and output options as a **capability toggle list** (default: all on) so a command can be narrowed (e.g. "only ever read the clipboard", "never touch my selection", "preview only").

## What Changes

- **Input becomes a capability set, resolved dynamically.** A command carries `inputs: Set<InputSource>` (the ambient channels it may consume). At fire, the executor **senses the environment** and activates the highest-priority **enabled** channel that is live: `selection ▸ clipboard-text ▸ clipboard-image`. Whichever wins is both the input *and* the remembered channel that drives commit. An empty set means "no input needed" (standalone prompt).
- **Output becomes a capability set, resolved dynamically.** A command carries `outputs: Set<OutputTarget>`. For in-place commands the commit behavior is **derived from the resolved input**: input was a selection **and** `replaceSelection` is enabled → replace; else `pasteAtCursor` enabled → paste at cursor; else `previewOnly` → write nothing. A side-effecting `runTask`/`sendTo` in the set keeps its own accept-step→execute flow. Nothing is a fixed one-shot toggle; it is resolved every fire from *action nature × environment*.
- **Model capability is resolved at runtime, from the chosen input.** The static "an image source always requires vision" rule is replaced: the executor senses the input first, and requests a **vision** model only when the **resolved** channel is an image (the clipboard actually holds an image), else a text model. This is what lets one command transparently OCR/parse a clipboard image when that's what's present, and stay a cheap text run otherwise.
- **The editor's two dropdowns become two toggle lists.** Inputs and (in-place) outputs are multi-select, defaulting to all-on for a new command; the side-effecting task/destination sub-editor is unchanged.
- **The silent-clipboard bug is designed out.** A failed selection read now *cascades* to the clipboard **and** the commit becomes paste (not a surprise replace of stale clipboard) — the fallback is intentional and honest, never a false "replace" on content the user didn't select.
- **Screen region stays a deliberate, exclusive input.** A command whose inputs contain `screenRegion` is region-first (the pre-canvas picker runs, unchanged); it is not mixed into the ambient cascade.
- **Persistence + skills migrate.** A one-time, in-place decode maps every legacy `input`/`output` scalar to the new sets (e.g. `selection` → `{selection, clipboard}`, `replaceSelection` → `{replaceSelection, pasteAtCursor}`), preserving behavior; the skill-file format gains `inputs:`/`outputs:` and still parses legacy `input:`/`output:`.

## Capabilities

### Modified Capabilities

- `ai-command-band`: the value model's input/output become **capability sets**; **input acquisition** and **in-place output routing** become **environment-resolved** (selection→replace, clipboard→paste, clipboard-image→vision), replacing the static single-source acquisition and the static replace/paste routing; **required model capability** is resolved from the chosen input at runtime rather than derived statically from the authored source.
- `selection-io`: the read path gains a **capability-cascade** framing (probe selection, else clipboard text, else clipboard image) and the write path is chosen by the **resolved input channel**, not a stored output enum.

## Impact

- **Code (all MLX-free Core):** `AI/AICommand.swift` (sets + `Hashable` on `InputSource`/`OutputTarget`/`TaskKind`/`Destination`, custom `Codable` migration, legacy convenience init, pure input/output **resolution** helpers, union `requiredCapabilities`); `AI/AICommandExecutor.swift` (sense→cascade input acquisition, runtime capability request, remembered resolved channel, resolved commit); `AI/AICommandCatalog.swift` + `AI/AIBand.swift` (preset helper maps legacy args → sets — call sites barely change); `AI/Skills/SkillFile.swift` (serialize/parse `inputs:`/`outputs:` with legacy fallback); `Hub/BandsCanvas.swift` (two dropdowns → two toggle lists); `Overlay/LauncherOverlayController.swift` + `App/AppCoordinator.swift` (`screenRegion` routing keys off `inputs`).
- **Tests:** `AICommandTests` (set model, migration decode, resolution helpers, union capabilities), `AICommandExecutorTests` (selection→replace, empty-selection→clipboard→paste, clipboard-image→vision, no-input), `AICommandCatalogTests`/`SkillsTests` (set-shaped presets + skill round-trip).
- **Spec-mandated change:** `ai-command-band` currently requires `requiredCapabilities` be **static** and never depend on runtime clipboard contents. This proposal **deliberately reverses that** for the resolved-capability behavior; the requirement is rewritten accordingly.
- **No signing, no permission, no TCC interaction, no gesture relocation.** The resolve/commit grammar (two-finger DOWN commits at top, horizontal discards) is unchanged; only *what DOWN does* becomes contextual. Verified under `swift build` / `swift test`; the live AX/clipboard/vision behavior needs the user's signed build.
- **Out of scope:** mixing `screenRegion` into the ambient cascade; new input sources; changing the side-effecting task/`sendTo` dispatch or its accept-step; any change to the canvas gesture grammar or the parked-session/notch surfaces.
