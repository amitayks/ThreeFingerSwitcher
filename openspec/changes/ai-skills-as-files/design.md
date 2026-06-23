## Context

The existing AI feature already encodes everything a "skill" is, just in code:

- `AICommand` (`AI/AICommand.swift`) is a pure `Codable` value: `name`, `icon`, `tint`, `input: InputSource`, `promptTemplate`, `output: OutputTarget`, `model`, `confirmBeforeRun`, `runtimeParameter`, `reasoning`, with `requiredCapabilities` derived statically from the input source.
- `AICommandCatalog` (`AI/AICommandCatalog.swift`) is ~75 of those, built via a `preset(...)` factory, grouped into nine `Category`s (each with a `tint` and `sfSymbol`), with `commands(in:)`, `copy(of:)` (fresh id on add), and `seeded()` (a curated 8-command subset for fresh install). `AIBand.seeded()` calls straight through.
- `ParsedActions` (`AI/Tasks/ParsedActions.swift`) supplies one `StructuredSchema` per side-effecting `TaskKind` (calendar/reminder/contact/save-to-project/open-tool/send-to), each with an `applicable` decline affordance.
- `PromptTemplate.resolve(_:with:activeLanguage:)` resolves `{input}/{date}/{app}/{url}/{lang}` against a `FireContext`; unknown tokens pass through verbatim.

V2 adds a router (`ai-tool-routing`) that picks a capability via `runtime.structured(routeSchema, as: ToolRoute.self)`. A capability the router can pick must describe itself: a `ToolDescriptor{name, summary, argsSchema, writePolicy}`. The router never wants to load 75 full prompt templates to decide; it wants a cheap **TOC of one-line summaries** and to load the chosen skill's body on demand. That is the same shape memory needs. So this slice externalizes the catalog into **declarative skill files** and owns the **shared retrieval index**.

The constraint that shapes every decision below: the curated catalog and its Bands-editor browse/add/seed behavior are good product and must survive byte-for-byte. So skills are the new source of truth; `AICommandCatalog` becomes a projection.

## Goals / Non-Goals

**Goals:**
- A concrete on-disk **skill file format** (one file per action, named for the action) that externalizes `AICommand` + the `ParsedActions` sink binding + a router-facing summary, parseable into a pure `SkillManifest` (MLX-free Core).
- A **skills folder + authoring path**: built-in skills (read-only, bundled), user skills (writable Application Support folder), validation at load, malformed-skill surfaced bounded + non-blocking, user-shadows-built-in by id.
- The **shared `DocIndex`/`IndexedDoc`/`DocKind` retrieval contract** (blueprint 3.4) owned here, with progressive disclosure (TOC always, body on demand). Pure synchronous index; async file IO bridged by the store.
- The **skill → `ToolDescriptor` projection** + an invocation seam consumed by `ai-tool-routing`'s `ToolRegistry`.
- An **identity-preserving, idempotent migration**: the 75 presets become built-in skill files; `AICommandCatalog` projects over them so Bands-editor browse/add and `seeded()` are unchanged.

**Non-Goals:**
- The route→execute→continue loop and the `ToolRegistry` aggregation — owned by `ai-tool-routing`; this slice only *provides* descriptors + an invoke seam.
- The memory store, its TOC/subfiles, and its read/write tools — `ai-agent-memory` *consumes* our `DocIndex`; we do not build it.
- Launching `claude` — `ai-claude-handoff` owns the process spawn and `ClaudeHandoffConfig`; we only carry the optional per-skill block on the file and surface it on the manifest.
- A Hub UI for editing a skill (v1 authoring is file-based, like dropping a `.md`). A skill marketplace / remote fetch.
- Changing `AICommand`, `PromptTemplate`, or `ParsedActions` behavior — they are reused verbatim.

## Decisions

### 1. Skill file format — front-matter + body, one file per action.

A skill is a UTF-8 text file `<action-id>.skill.md` (e.g. `create-meeting-in-gcal.skill.md`, `fix-grammar.skill.md`). It has a YAML front-matter block delimited by `---`, then a markdown body that IS the prompt template:

```
---
id: fix-grammar
title: Fix Grammar
summary: Correct spelling and grammar in the selected text, returning only the fixed text.
keywords: [grammar, spelling, proofread, correct]
category: Writing            # built-in only; preserves AICommandCatalog.Category for the projection
icon: text.badge.checkmark   # ItemIcon.sfSymbol name
tint: "#40B866"              # ItemColor; optional, defaults to the category tint
input: selection             # InputSource raw value
output: replaceSelection     # OutputTarget; see §2 for the sink encoding
confirmBeforeRun: false      # optional; defaults from output.isSideEffecting (AICommand.init parity)
runtimeParameter:            # optional; mirrors RuntimeParameter
  language: { default: English }
reasoning: null              # optional; AIReasoning .on/.off, null = follow global
tools: []                    # optional allow-list of extra ToolDescriptor names this skill may call
claudeHandoff: null          # optional ClaudeHandoffConfig block (owned by ai-claude-handoff)
---
Fix the spelling and grammar of the following text. Return only the corrected text, with no commentary:

{input}
```

- **`summary` is the router-facing when-to-use line** — the single most load-bearing addition over `AICommand`. It is the `IndexedDoc.summary` (the TOC line the router ranks) AND the `ToolDescriptor.summary` (the one line the model sees in route mode). The in-code catalog never had this; it is authored per skill.
- The **body is the prompt template** verbatim, resolved by the unchanged `PromptTemplate`. Keeping it as the body (not a quoted YAML string) keeps multi-line templates readable and editable.
- **Markdown (`.skill.md`) over JSON/TOML/plist** — chosen because (a) it is the human-authoring sweet spot (front-matter is a known idiom, the body is just text), (b) it mirrors the memory subfile format (`ai-agent-memory` also wants human-editable docs over the same index), and (c) it survives copy/paste and version control. *Rejected:* one JSON file per skill (machine-friendly but hostile to no-code authoring of a multi-line prompt); a single monolithic `skills.json` (loses one-file-per-action, harder to drop in / shadow / diff).

### 2. `SkillManifest` (pure Core) — the parsed in-memory form, an `AICommand` superset.

```
struct SkillManifest: Equatable, Sendable, Identifiable {
    var id: String                 // the file's `id`, path-relative, stable; the ToolDescriptor.name
    var origin: SkillOrigin        // .builtIn / .user  (drives read-only + shadowing)
    var title: String
    var summary: String            // router-facing when-to-use; the TOC line
    var keywords: [String]
    var category: String?          // built-in projection grouping (nil for user skills)
    var command: AICommand         // the reused value model: icon/tint/input/template/output/param/reasoning
    var toolNames: [String]        // optional allow-list of extra tools this skill may invoke
    var claudeHandoff: ClaudeHandoffConfig?   // consumed type, owned by ai-claude-handoff
    var updatedAt: Date
}
enum SkillOrigin: String, Codable, Sendable { case builtIn, user }
```

- The skill **reuses `AICommand`** rather than re-flattening its fields: `SkillFile` parse builds an `AICommand` (with `id = UUID()` minted fresh — the file `id` string is the *skill* identity, the `AICommand.id` is the per-instance identity when added to a band, exactly the `copy(of:)` stencil rule). So `requiredCapabilities`, `resolvedReasoning`, `defaultConfirmBeforeRun`, and the `runtimeParameter`/`{lang}` plumbing all come for free and stay consistent with band items.
- **Sink encoding in the file.** `OutputTarget` has associated values (`.runTask(TaskKind)`, `.sendTo(Destination)`). The front-matter encodes these as a small tagged form: `output: replaceSelection | pasteAtCursor | previewOnly`, or `output: { runTask: addToCalendar }`, `output: { runTask: { saveToProject: Inbox } }`, `output: { sendTo: { shortcut: "My Shortcut" } }`. `SkillFile` maps these to/from `OutputTarget` at the boundary. This is the "output schema / sink binding" externalized.

### 3. The skill → `ToolDescriptor` projection (the skill↔router contract).

A skill projects to a `ToolDescriptor` (blueprint 3.3, owned by `ai-tool-routing`):

- `name` = `SkillManifest.id`.
- `summary` = `SkillManifest.summary`.
- `argsSchema` = the skill's parsed-action `StructuredSchema`: for a side-effecting sink (`.runTask`/`.sendTo`) it is the corresponding `ParsedActions` schema (`ParsedCalendarEvent.schema`, etc.) so the model emits the same validated/declinable shape the dispatcher already consumes; for an in-place sink (`replaceSelection`/`pasteAtCursor`/`previewOnly`) it is a minimal text schema (`{ "result": string }`) since the model just produces text.
- `writePolicy` = `.confirm` when `command.output.isSideEffecting` (the existing `confirmBeforeRun` default), else `.auto` — exactly mirroring `AICommand.defaultConfirmBeforeRun`. A skill may pin `confirmBeforeRun: true` to force `.confirm`. (`ai-background-autonomy` later intersects this with the user whitelist; this slice only sets the descriptor default — blueprint C1: the bare `WritePolicyTier` is defined with `ToolDescriptor` in `ai-tool-routing`, so we *read/set* it, we do not define it.)

`SkillToolProvider` (Core) exposes `descriptors() -> [ToolDescriptor]` (the TOC-cheap projection) and `invoke(skillID:arguments:context:) -> ToolStepResult` which resolves the template via `PromptTemplate`, calls the runtime, and routes to the bound sink via `TaskDispatching`. `ai-tool-routing`'s `ToolRegistry` aggregates this provider alongside memory tools and `launch_claude`. **This slice does not run the loop**; it hands the registry a contributor.

### 4. The shared index — `DocIndex`/`IndexedDoc`/`DocKind` (OWNED here, blueprint 3.4).

```
struct IndexedDoc: Codable, Equatable, Identifiable, Sendable {
    let id: String; var title: String; var summary: String
    var keywords: [String]; var kind: DocKind; var bodyPath: URL; var updatedAt: Date
}
enum DocKind: String, Codable, Sendable { case skill, memoryCore, memorySubfile }
protocol DocIndex: Sendable {
    func allSummaries() -> [IndexedDoc]               // the combined TOC the model always sees
    func retrieve(query: String, limit: Int) -> [IndexedDoc]   // ranked summaries
    func body(of id: String) throws -> String         // load full body on demand
}
```

- **Progressive disclosure.** `allSummaries()` returns every doc's `summary` line — cheap, always shown to the router. The full body (the prompt template for a skill, the subfile text for memory) is loaded only via `body(of:)` when the model selects that doc — a routed `retrieve`/`read` tool step. This bounds the route prompt to ~75 one-liners, not 75 full templates.
- **Pure synchronous over an in-memory snapshot; async IO bridged by the store** (the documented Files-band pattern: `FilesNavigationModel` pure/sync, `DirectoryLister` async/off-main, `FilesColumnController` bridges with a cache). `SkillStore` builds the `[IndexedDoc]` snapshot off-main (read each file's front-matter), then a pure `InMemoryDocIndex` answers `allSummaries`/`retrieve` synchronously; `body(of:)` reads the file (cached). The pure index never touches `FileManager`.
- **Ranking** (`retrieve`) is a cheap keyword/substring score over `title`+`summary`+`keywords` — deterministic, unit-testable, no embedding model (M5 could run one, but the router already does the heavy lifting via `structured()`; the TOC scan is a cheap pre-filter, and a deterministic ranker is testable without a model). The index is `kind`-agnostic, so the combined skills+memory TOC is one `allSummaries()` over a merged snapshot — `ai-agent-memory` contributes its `IndexedDoc`s into the same index; **memory defines no second retriever** (blueprint C2).
- `kind` distinguishes a skill doc (`.skill`) from a memory doc so a consumer (or the route prompt) can group/label them; the retriever ranks uniformly.

### 5. `SkillStore` — built-in + user, validation, shadowing, watch.

```
final class SkillStore {              // owns IO; bridges to the pure index
    func loadAll() async -> SkillLoadResult       // built-in bundle ∪ user folder, shadowed, validated
    func index() -> DocIndex                       // the pure snapshot for the router
    func manifest(id: String) -> SkillManifest?
    // user-folder writes are out of band (user edits files); the store watches + reloads
}
struct SkillLoadResult { var skills: [SkillManifest]; var problems: [SkillProblem] }
struct SkillProblem: Equatable { var fileName: String; var headline: String }  // bounded, non-blocking
```

- **Locations.** Built-in skills ship read-only inside the app bundle (`Contents/Resources/Skills/`, generated at build from the migration — §7). User skills live in a writable folder under Application Support (e.g. `~/Library/Application Support/<bundle>/Skills/`), created on first run. No new permission (reads the filesystem on demand, like `keepClipboardHistory` / the Files band).
- **Coexistence + shadowing.** The store loads built-in then user; a **user skill whose `id` matches a built-in shadows it** (the user's file wins; `origin: .user`). This is the no-code "edit a built-in" path: copy the built-in to the user folder, edit, done. Otherwise both appear, user skills after built-in.
- **Validation at load (never a crash, never a silent drop).** Each file is parsed; failures (missing front-matter, missing `id`/`summary`, unknown `input`/`output` enum value, malformed sink, bad `runtimeParameter`, template that fails to parse) are mapped at the parse boundary into a `SkillProblem{fileName, headline}` (a clean `AIPresentedError.headline`) and collected — the skill is excluded from the index but the load **succeeds for the rest**. Problems surface as a bounded, non-blocking list (a Hub row), never an `NSAlert`; raw parse text rides only in logs / opt-in details.
- **Watch + reload.** The user folder is watched (a coalesced reload like the Files-band cache); a dropped/edited file re-indexes off-main and republishes. Built-in skills are loaded once.

### 6. Error taxonomy.

A new `enum SkillError: Error, Equatable, LocalizedError` ONLY for skill-load/validation cases `RuntimeError`/`TaskError` cannot carry: `.malformedFrontMatter(detail:)`, `.missingRequiredField(name:)`, `.unknownEnumValue(field:value:)`, `.duplicateID(id:)`, `.unreadable(detail:)`. Each has a clean `errorDescription`; raw OS/parse text stays in opt-in `details`/logs. `AIError.message(for:)` is extended to translate `SkillError` into an `AIPresentedError` (the one translator). Skill **invocation** failures (template/model/sink) flow through the existing `RuntimeError`/`TaskError` and become a `ToolStepResult(status: .failed(headline:))` — never a false "Done", never silence. Vendor/OS errors (`FileManager`, YAML parse) map into `SkillError` at the `SkillFile`/`SkillStore` boundary; Core stays MLX-free.

### 7. Catalog migration — built-in skill files + `AICommandCatalog` as a projection.

- **Generation.** A deterministic generator iterates `AICommandCatalog.entries` and emits one built-in skill file per preset: `id` = a slug of the name (e.g. "Fix Grammar" → `fix-grammar`), `title`/`icon`/`tint`/`input`/`output`/`runtimeParameter` from the `AICommand`, `category` from the `Entry`, body = the `promptTemplate`. The `summary` (the new router line) is authored per preset (a short when-to-use sentence — the one piece not derivable from the existing command; the generator seeds a reasonable default from `name`+template and is hand-tuned). Generation runs as a build/dev step writing into `Contents/Resources/Skills/`; the generated files are checked in so the build is reproducible and `swift test` can read them from a known fixtures path.
- **`AICommandCatalog` becomes a projection.** After migration, `AICommandCatalog.entries`/`commands(in:)`/`seeded()` are computed from the loaded **built-in** skill set (filtered to `origin: .builtIn`, grouped by `category`), preserving: the nine categories and their `tint`/`sfSymbol`, the per-category command lists (catalog order), `copy(of:)` (fresh `AICommand.id` on add), and `seeded()` (the same curated 8 names in the same order). The Bands-editor browser, "add as a band", and the fresh-install seed are therefore **byte-identical** to today.
- **Idempotent + identity-preserving.** No persisted `Favorites`/band record is rewritten; an upgrading user's bands (already holding `.aiCommand` items with their own `AICommand.id`s) are untouched. `AIBand.seeded()`/`seededBand()` still call `AICommandCatalog.seeded()`, which now projects from skills — same names, same templates, same ids-are-fresh-on-add semantics. The fresh-install guard (don't re-seed an upgrading user) is unchanged.
- **Why a projection, not a deletion.** The Bands editor adds an `.aiCommand` band *item* (a persisted `AICommand`), not a live skill reference — that behavior is load-bearing and tested. Keeping `AICommandCatalog` as a projection means zero churn to the Bands editor / `AIBand` / `Favorites` while the *source of truth* moves to files. The router uses the skill files; the launcher grid keeps using `AICommand` band items. The two views never diverge because the catalog is computed from the same files.

## Target split & verification (per component)

| Component | Target | Verified by |
|---|---|---|
| `SkillManifest`, `SkillOrigin` (value types) | Core | `swift test` (round-trip, defaults parity with `AICommand`) |
| `SkillFile` parse/serialize (front-matter + body, sink encoding) | Core | `swift test` (parse fixtures, malformed → `SkillProblem`, round-trip stability) |
| `IndexedDoc`/`DocKind`/`DocIndex` + `InMemoryDocIndex` (the shared retriever) | Core | `swift test` (`allSummaries`, deterministic `retrieve` ranking, `body(of:)`) |
| `SkillStore` (built-in ∪ user, shadowing, validation, watch) | Core | `swift test` against temp dirs (shadowing, problem collection, reload) |
| `SkillToolProvider` (skill → `ToolDescriptor`, `invoke`) | Core | `swift test` against `StubLLMRuntime` (descriptor projection, invoke → `ToolStepResult`, decline path) |
| `SkillError` + `AIError.message(for:)` extension | Core | `swift test` (clean headline, no raw interpolation) |
| Migration generator + `AICommandCatalog` projection | Core | `swift test` (projection equals today's catalog: categories, per-category lists, `seeded()` names/order) |
| Generated built-in `.skill.md` corpus (checked-in resource) | Core fixture | `swift test` reads the bundled corpus; count + parse-clean assertion |
| Full app link (no MLX code added here) | app/GemmaRuntime | `xcodebuild` compile-verify only; **user** does the real install to author skills on disk end-to-end |

No piece of this slice links MLX. Everything is pure value types + file IO + a stub-driven invoke, so the whole slice verifies under `swift build`/`swift test`. (House rule: an agent never builds/signs/installs the `.app`.)

## Edge cases

- **Two skills, same `id`, both user files** → `SkillError.duplicateID`; the first loaded wins, the second is a `SkillProblem` (deterministic order by filename). User-shadows-built-in is NOT a duplicate (different `origin`, intended).
- **Built-in skill the user deleted from the user folder** → built-in still loads (deletion of a *user* override just un-shadows; you cannot delete a built-in, only shadow it). A user wanting to "remove" a built-in shadows it with an empty/disabled file (a future `enabled: false` front-matter key — noted, not in v1).
- **Skill bound to a side-effecting sink but the model declines** (`applicable: false`) → `invoke` returns `ToolStepResult(status: .declined(reason:))`, the dispatcher fires nothing, exactly the existing decline path; never a false "Done."
- **Skill with a `{lang}` template but no `runtimeParameter`** → `{lang}` resolves to empty (the unchanged `PromptTemplate` rule); not an error.
- **Vision skill (`input: screenRegion`/`clipboardImage`)** → `requiredCapabilities == [.vision]` flows from the reused `AICommand`; the route/executor enforces a vision model exactly as today.
- **Malformed front-matter mid-corpus** → that one file is a `SkillProblem`; the rest of the corpus indexes; the router never sees the broken skill; the Hub shows one bounded problem row.
- **Empty user folder / folder absent** → store creates it; built-in skills alone form the index; no error.
- **`retrieve` query with no keyword hits** → returns an empty (or score-floored) list; the router falls back to the full `allSummaries()` TOC; never throws.
- **A user skill `id` that collides with a memory doc `id`** → `IndexedDoc.id` is namespaced by a path-relative id and `kind`; skills and memory live in different folders, so collision is structurally impossible (documented contract for `ai-agent-memory`).

## Rejected alternatives

- **Keep `AICommandCatalog` as the source of truth, add a separate router-only descriptor table.** Rejected: two sources of the same verbs drift; the whole point is one declarative unit the user can author and the router can read.
- **Per-skill JSON / single `skills.json`.** Rejected: hostile to no-code authoring of a multi-line prompt; loses one-file-per-action drop-in/shadow/diff. Markdown front-matter is the human sweet spot and mirrors memory subfiles.
- **An embedding-based retriever in this slice.** Rejected for v1: the `structured()` router is the real selector; the TOC scan is a cheap deterministic pre-filter (unit-testable without a model). An embedding ranker is an additive future behind the same `DocIndex` seam (M5 can run it).
- **A second retriever for memory.** Rejected by blueprint C2: skills and memory share ONE `DocIndex`; memory contributes `IndexedDoc`s, it does not define its own ranking/IO.
- **Defining `WritePolicyTier` here.** Rejected by blueprint C1: the bare enum is defined with `ToolDescriptor` in `ai-tool-routing`; we set it on the descriptor, we do not own it.
- **Deleting the Bands-editor `.aiCommand`-item flow in favor of live skill references.** Rejected: that flow is load-bearing and tested; the projection keeps it intact with zero churn while moving the source of truth to files.
