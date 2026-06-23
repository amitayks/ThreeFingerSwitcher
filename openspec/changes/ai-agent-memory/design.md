## Context

Three existing seams shape every decision here, and two sibling V2 slices own the contracts this slice
consumes verbatim.

**Existing code (V2 evolves, never forks):**

- `DiskProjectStore` (`AI/Tasks/TaskSinks.swift`) is the exact on-disk pattern memory parallels: an
  Application-Support directory under `ThreeFingerSwitcher/`, a sanitized deterministic filename per logical
  unit, an append/write that maps every `FileManager`/`FileHandle` throw into a clean `TaskError.sinkFailed`
  **at the IO boundary** (raw OS error to the log only), and a pure `static` block-builder (`entryBlock`)
  that is unit-testable without disk. Memory reuses this shape wholesale: `defaultDirectory()` →
  `…/ThreeFingerSwitcher/memory`, sanitized subfile names, boundary-mapped errors, a pure document builder.
- The **Files-band sync-model + async-cache + coalesced-watch** pattern: a pure synchronous model reads a
  cache; a miss spawns an off-main listing that stores and republishes; a folder watch coalesces reloads.
  Memory's pure document/index logic never touches `FileManager`; the `MemoryStore` bridges IO off-main.
- `AIError.message(for:) -> AIPresentedError` is the single error translator; every memory failure routes
  through it. Raw text rides only in logs / opt-in `details`, never a headline.

**Consumed contracts (owned elsewhere — do NOT redefine):**

- `DocIndex` / `IndexedDoc` / `DocKind` — OWNED by `ai-skills-as-files` (blueprint 3.4). The shared retriever:
  `allSummaries()` (the combined TOC the router always sees), `retrieve(query:limit:)` (deterministic ranked
  summaries), `body(of:)` (lazy body load). `IndexedDoc` carries `id`, `title`, `summary` (the TOC line),
  `keywords`, `kind` (`.skill`/`.memoryCore`/`.memorySubfile`), `bodyPath`, `updatedAt`. Memory contributes
  `IndexedDoc(kind: .memoryCore/.memorySubfile)` into the **same** in-memory snapshot. **Memory defines no
  second retriever** (blueprint C2).
- `ToolDescriptor` / `ToolRoute` / `ToolStepResult` / `ToolStepStatus` + the bare `WritePolicyTier` — OWNED
  by `ai-tool-routing` (blueprint 3.3, integration fix C1). `WritePolicyTier` is `.auto`/`.confirm`/
  `.dangerous`, defined WITH `ToolDescriptor`, so each memory descriptor carries its tier with no DAG
  back-edge. Memory **reads/sets** the tier; it does not own the enum.
- `AuditRecord` / `AuditLog` + the user whitelist + effective-tier resolution — OWNED by
  `ai-background-autonomy` (blueprint 3.7). Effective tier = descriptor default ∩ user whitelist; the
  whitelist marks memory writes `.auto`. Every memory write emits an `AuditRecord`. Escalation
  (`ParkScheduler.escalate` → `.needsYou`) is owned by `ai-parked-sessions`; memory only *classifies* an op
  dangerous so the policy layer escalates it.
- `AgentSessionID` — OWNED by `ai-conversation-runtime` (blueprint 3.1). Stable across park/restore; used to
  attribute a memory write in its `AuditRecord`.

The router never wants the whole memory dumped into its prompt — it wants the cheap CORE facts plus the
subfile TOC, and a subfile body only when it picks one. That is the **identical** progressive-disclosure
shape skills already use, which is exactly why memory reuses the skills retriever rather than building its
own.

## Goals / Non-Goals

**Goals:**

- A **two-tier** on-disk memory: a single hard-capped **CORE** document (ground-truth facts + a table of
  contents of subfiles), read every session; **named SUBFILES** holding the details, pulled on demand by
  relevance through the shared `DocIndex`.
- A **hard byte/line cap on CORE that physically evicts** detail content into a subfile (replacing it in
  CORE with a TOC entry) so the always-read tier can never overflow.
- **Promotion to CORE is propose-then-keep**: the agent proposes via a `memory.promote` step; the cap is the
  structural backstop; the user overrides by hand-editing.
- **Memory tools** projected as `ToolDescriptor`s for the `ToolRegistry`: `memory.read` (free, `.auto`,
  runs even when parked), `memory.write`/`memory.update`/`memory.forget`/`memory.promote` (side-effecting,
  whitelisted → effective `.auto` per the adopted decision, **always audited**, dangerous ops `.dangerous`).
- **Editable by agent (by direction) AND by user (by hand)**, converging on the same Markdown files; the
  store watches + reloads off-main.
- A pure `MemoryDocument` (CORE parse/serialize + cap/eviction decision) and `MemorySubfile` (front-matter +
  body) in MLX-free Core, `swift test`-able headless.

**Non-Goals:**

- The route → execute → continue loop, candidate selection, and `ToolRegistry` aggregation
  (`ai-tool-routing`); this slice provides a `MemoryToolProvider` contributor only.
- Defining `DocIndex`/`IndexedDoc`/`DocKind` or any ranking/IO (`ai-skills-as-files` owns the retriever).
- Defining `WritePolicyTier`/`AuditRecord`/`AuditLog`, the whitelist, or effective-tier resolution
  (`ai-background-autonomy`); this slice sets descriptor defaults and emits records.
- The needs-you escalation transport and parked lifecycle (`ai-parked-sessions`).
- A Hub UI for browsing/editing memory (v1 is file-based, like dropping a `.md`).
- Embeddings / semantic ranking (a future behind the same `DocIndex` seam — M5 can run it, but the
  deterministic keyword ranker the skills retriever already provides is the v1 mechanic).
- Cross-device memory sync; encryption-at-rest beyond the OS default.

## Decisions

### 1. Two tiers, two file shapes — CORE document + named subfiles.

The memory folder (`…/Application Support/ThreeFingerSwitcher/memory/`) contains:

- **`core.md`** — the single always-read CORE document. Two sections:
  - **`## Facts`** — a flat list of short ground-truth lines (one fact per bullet). This is what makes the
    agent a companion: it is injected into **every** session's context (as a synthetic `system` prefix turn,
    assembled by `ai-conversation-runtime`).
  - **`## Contents`** — the **table of contents**: one line per subfile, `name — summary`. This is the
    memory half of the combined `DocIndex` TOC; the router sees it alongside the skills TOC and can pull a
    subfile body on demand. CORE holds the TOC line, never the subfile's detail.
- **`subfiles/<name>.md`** — one named subfile per detail topic, the **same** front-matter+body shape as a
  skill file (so the two doc kinds parse through one familiar idiom and contribute uniformly to the index):

  ```
  ---
  name: acme-migration
  summary: Notes and decisions on the Acme data-migration project.
  keywords: [acme, migration, project, deadline]
  updatedAt: 2026-06-22T10:00:00Z
  ---
  The Acme migration is targeted for Q3. Dana owns the schema work…
  ```

  The body is free Markdown detail. `name` is the stable id (sanitized, deterministic filename); `summary`
  is the TOC line that appears in `core.md`'s `## Contents` AND is the `IndexedDoc.summary` the router ranks.

*Why a single `core.md` rather than two files (facts vs TOC):* the facts and the TOC are the **one** thing
read every session and must round-trip atomically under the cap; splitting them invites a desync between
"what CORE claims it has" and "what subfiles exist." The reconciliation pass (Decision 6) keeps the
`## Contents` block honest against the actual subfiles folder.

*Why Markdown front-matter for subfiles:* it mirrors the skill file format (`ai-skills-as-files` Decision 1),
so a subfile and a skill index identically; it is the human-authoring sweet spot for hand-editing; it
survives copy/paste and version control.

### 2. `MemoryDocument` (pure Core) — CORE parse/serialize + the cap/eviction decision.

```
struct MemoryFact: Equatable, Sendable { var text: String }
struct MemoryTOCEntry: Equatable, Sendable { var name: String; var summary: String }

struct MemoryDocument: Equatable, Sendable {
    var facts: [MemoryFact]
    var contents: [MemoryTOCEntry]            // mirrors the subfiles; the table of contents
    // pure parse from core.md text; pure serialize back to core.md text
    static func parse(_ text: String) -> MemoryDocument
    func serialized() -> String

    // The cap, as a pure decision. byteCount/lineCount of serialized() must stay ≤ cap.
    func wouldExceedCap(addingFact: MemoryFact, cap: MemoryCap) -> Bool
    // Eviction picks the lowest-value fact(s) to move out and returns the residual doc + the evicted text.
    func evicting(toFit cap: MemoryCap) -> (kept: MemoryDocument, evicted: [MemoryFact])
}

struct MemoryCap: Equatable, Sendable {
    var maxBytes: Int        // hard cap on serialized() size; default tuned (e.g. 8 KB)
    var maxFacts: Int        // hard cap on fact count; default tuned (e.g. 60)
}
```

- **The cap is on the serialized CORE**, because CORE is what gets injected every session — the cost is the
  always-read token budget, not disk. Both a byte cap and a fact-count cap (whichever binds first) make the
  decision robust to a few very long facts vs. many short ones.
- **`evicting(toFit:)` is a pure function** so the eviction policy is unit-testable headless: it selects the
  facts to move out (v1 policy: **oldest-first among the longest facts** — favor evicting bulky detail-bearing
  lines, keep terse identity facts), bundles them into subfile body text, and returns the residual document.
  The store turns the evicted text into an actual `subfiles/<name>.md` + a `## Contents` entry.
- On M5 this never needs a defensive "memory too big to load" path — the cap keeps CORE tiny by construction
  and subfiles are loaded one at a time on demand.

### 3. The cap is the backstop; promotion to CORE is propose-then-keep.

The agent does not silently inflate CORE. Two distinct write intents:

- **`memory.write`** with `tier: subfile` (the default for detail) → writes/updates a **subfile** and
  ensures a `## Contents` TOC entry. CORE's fact list is untouched. This is the common case ("remember the
  notes on the Acme project").
- **`memory.promote`** → the agent **proposes** keeping something as a CORE **fact** ("keep this in core?").
  Promotion is a side-effecting step the policy layer can gate; the **hard cap is the structural backstop** —
  even an approved promotion that would breach the cap triggers `evicting(toFit:)`, so CORE stays bounded
  regardless. The user **overrides** by hand: edit `core.md`'s `## Facts` directly to add/remove a fact, or
  move a line between `## Facts` and a subfile.

So the chosen policy is: **proposal + hard cap.** The proposal keeps the agent honest about what is
"ground truth" worth reading every session; the cap guarantees the always-read tier never grows unbounded no
matter how aggressively the agent (or a buggy loop) promotes. Documented user-override seam: the files are
plain Markdown the user edits by hand, and the store reconciles (Decision 6).

### 4. Memory tools as `ToolDescriptor`s — read is free, writes are whitelisted-auto + audited.

`MemoryToolProvider` (Core) exposes `descriptors() -> [ToolDescriptor]` and
`invoke(tool:argumentsJSON:sessionID:) async -> ToolStepResult`, aggregated by `ai-tool-routing`'s
`ToolRegistry`. The descriptors:

| Tool | argsSchema (`StructuredSchema`) | `writePolicy` (descriptor default) | Behavior |
|---|---|---|---|
| `memory.read` | `{ query?: string }` | `.auto` | Reads CORE (facts + TOC); if `query` present, `retrieve(query:)` the relevant subfiles and loads their bodies. **Free**: runs even when the session is parked; never escalates. |
| `memory.write` | `{ scope: "fact"\|"subfile", name?: string, summary?: string, content: string }` | `.confirm` (→ effective `.auto` via the memory whitelist) | Writes/updates a fact or a subfile + its TOC entry. |
| `memory.update` | `{ name: string, content: string, summary?: string }` | `.confirm` (→ effective `.auto`) | Replaces a named subfile's body/summary. |
| `memory.forget` | `{ scope: "fact"\|"subfile", name?: string, match?: string }` | `.confirm` (→ `.auto` for single; `.dangerous` for bulk) | Removes a fact or a subfile (+ its TOC entry). A `match` that would remove **many** entries, or a CORE-wide clear, classifies `.dangerous`. |
| `memory.promote` | `{ content: string }` | `.confirm` | Proposes a CORE fact (Decision 3); the cap is the backstop. |

- **Per the adopted user decision (do NOT relitigate):** memory writes are **whitelisted → effective
  `.auto`**, so they run **without a confirm even when the session is parked**, BECAUSE the store is
  **contained** (it can only ever touch the memory folder — no calendar, no network, no arbitrary file) and
  **every write is audited**. `ai-background-autonomy` owns the whitelist + the effective-tier resolution
  (descriptor default ∩ whitelist); this slice sets the descriptor default to `.confirm` so that, absent the
  whitelist, a memory write is a normal confirm step — and ships the memory whitelist entry as the thing the
  user can toggle off to re-require confirmation.
- **Dangerous escalation.** A bulk `memory.forget` (a `match` hitting many entries) or a destructive CORE
  rewrite classifies **`.dangerous`** regardless of the whitelist, so it escalates to the foreground via the
  needs-you badge even when parked (`ai-parked-sessions` owns the escalation; memory only sets the tier).
- **Every write emits an `AuditRecord`** (`sessionID`, `tool`, `policy`, a **redacted/short**
  `argumentsSummary` — the subfile name + a length, never the full secret content — `outcome`,
  `wasBackground`, `timestamp`). `memory.read` is also recorded (audit is for every step) but is `.auto` and
  free.
- A write whose side effect **does not land** (disk full, permission, read-only volume) maps the IO throw at
  the boundary into `MemoryError`, returns `ToolStepResult(status: .failed(headline:))`, and audits the
  failure — **never a false "Done."**

### 5. `MemoryStore` (Core) — owns IO; bridges to the shared index; contains all writes.

```
final class MemoryStore {                  // owns IO; pure logic lives in MemoryDocument/MemorySubfile
    init(directory: URL = MemoryStore.defaultDirectory())
    static func defaultDirectory() -> URL  // …/ThreeFingerSwitcher/memory  (parallels DiskProjectStore)

    func loadCore() async throws -> MemoryDocument
    func indexedDocs() async -> [IndexedDoc]      // .memoryCore (one) + .memorySubfile (per subfile) → merged into DocIndex
    func body(of id: String) throws -> String     // a subfile body, or the CORE facts text, for the shared index

    func write(scope:name:summary:content:) async throws -> MemoryWriteOutcome   // fact|subfile, applies cap+eviction
    func update(name:content:summary:) async throws -> MemoryWriteOutcome
    func forget(scope:name:match:) async throws -> MemoryForgetOutcome            // classifies dangerous for bulk
    func promote(content:) async throws -> MemoryWriteOutcome                     // cap is the backstop

    // user-folder writes are out of band (user edits files); the store watches + reloads (coalesced, off-main)
}
```

- **Containment is structural:** every path the store writes is rooted at `directory`; a `name` is run
  through the same sanitizer `DiskProjectStore.fileName(for:)` uses (alphanumerics + `-_ `, never empty, no
  traversal), so `memory.write` can never escape the memory folder. This is what makes auto-when-parked
  safe.
- **Sync-model + async-cache bridge** (the Files-band pattern): the pure `MemoryDocument`/`MemorySubfile`
  logic never touches `FileManager`. `MemoryStore` reads/writes off-main, then publishes an updated
  `[IndexedDoc]` snapshot that the shared `InMemoryDocIndex` (owned by skills) answers `allSummaries()` /
  `retrieve()` over synchronously. `body(of:)` reads the file (cached), mirroring the skill store.
- **Memory contributes into the SAME index.** `ai-skills-as-files`'s `SkillStore` and this `MemoryStore`
  each produce `[IndexedDoc]`; the combined snapshot is one merged enumeration ranked by the one retriever.
  IDs are namespaced by a path-relative id and `kind`, and skills/memory live in different folders, so a
  skill-id ↔ memory-name collision is structurally impossible (the documented contract from
  `ai-skills-as-files` Decision 4 / its edge case).
- **Watch + reload** off-main (coalesced, like the Files-band cache): a hand-edited `core.md` or a dropped
  subfile re-indexes and republishes; user edits and agent edits converge on the same files.

### 6. Reconciliation — `## Contents` always matches the subfiles folder.

CORE's `## Contents` block and the actual `subfiles/` folder can drift (the user deletes a subfile by hand;
the agent's write crashed between the subfile write and the TOC update). On load and after every write, the
store runs a pure reconciliation: a subfile with no TOC entry gets one (from its front-matter `summary`); a
TOC entry with no subfile is dropped. The **subfiles folder is the source of truth for existence**; the TOC
is a derived view kept honest. This is the same "projection stays consistent because it is computed from the
files" discipline `ai-skills-as-files` uses for the catalog.

### 7. Error taxonomy — `MemoryError`, mapped at the boundary, one translator.

A new `enum MemoryError: Error, Equatable, LocalizedError` ONLY for cases `RuntimeError`/`TaskError` cannot
carry: `.unreadableCore(detail:)`, `.writeFailed(detail:)`, `.subfileNotFound(name:)`, `.capExceeded` (a
defensive guard — eviction should always make room, but a single fact larger than the whole cap is a clean
`.capExceeded`), `.malformedSubfile(name:detail:)`. Each has a clean `errorDescription`; raw OS/parse text
rides only in opt-in `details` / logs (the `DiskProjectStore` boundary-mapping discipline). `FileManager`
throws map into `MemoryError` at the `MemoryStore` IO boundary; Core stays MLX-free. `AIError.message(for:)`
is extended to translate `MemoryError` into an `AIPresentedError` — the single translator; never raw error
text in a headline, never an `NSAlert.runModal`. A memory tool failure becomes a
`ToolStepResult(status: .failed(headline:))` fed back into the route loop — observable, never silent.

## Target split & verification (per component)

| Component | Target | Verified by |
|---|---|---|
| `MemoryFact`/`MemoryTOCEntry`/`MemoryDocument` (parse/serialize/cap/evict) | Core | `swift test` (round-trip stability, cap boundary, deterministic eviction order) |
| `MemoryCap` defaults + `wouldExceedCap`/`evicting(toFit:)` | Core | `swift test` (byte vs fact cap, evict-to-fit, single-fact-over-cap → `.capExceeded`) |
| `MemorySubfile` parse/serialize (front-matter + body) | Core | `swift test` (parse fixtures, malformed → `MemoryError.malformedSubfile`, round-trip) |
| `MemoryStore` (IO, containment, write/update/forget/promote, reconcile, watch) | Core | `swift test` against temp dirs (containment/sanitization, evict-on-write, reconcile drift, dangerous classification, coalesced reload) |
| Memory `IndexedDoc` contribution into the shared `DocIndex` | Core | `swift test` (memory docs appear in `allSummaries()`, `retrieve()` ranks them, `body(of:)` loads a subfile; combined-with-skills enumeration is one) |
| `MemoryToolProvider` (descriptors + `invoke` → `ToolStepResult`) | Core | `swift test` against `StubLLMRuntime`/fakes (descriptor tiers, read-free, write-audited, forget-bulk-dangerous, fail → `.failed`) |
| `AuditRecord` emission on every write | Core | `swift test` (a fake `AuditLog` records redacted args + outcome + `wasBackground`) |
| `MemoryError` + `AIError.message(for:)` extension | Core | `swift test` (clean headline, no raw interpolation) |
| Full app link (no MLX code added here) | app/GemmaRuntime | `xcodebuild` compile-verify only; **user** does the real install to hand-edit files end-to-end |

No piece of this slice links MLX — it is value types + file IO + a stub-driven invoke. The whole slice
verifies under `swift build` / `swift test`. (House rule: an agent never builds/signs/installs the `.app`.)

## Edge cases

- **A single fact larger than the whole cap** (a user pastes a paragraph as one "fact") → `evicting(toFit:)`
  cannot make room by moving other facts; the store routes it to a **subfile** instead (it is detail, not a
  fact) and adds a TOC entry, or, if `memory.promote` forced it, returns `MemoryError.capExceeded` as a clean
  `.failed` step — never a false "kept in core."
- **Concurrent agent write + user hand-edit of `core.md`** → the store writes atomically (`.atomic`, like
  `DiskProjectStore`) and the watch reload re-parses; last-writer-wins on `core.md`, but subfiles are
  independent files so a fact write and a subfile edit don't collide. Documented as acceptable for v1
  (single-user, single-machine).
- **`memory.read` while parked** → runs (`.auto`, free), reads CORE + retrieves subfiles, never escalates,
  still audited. This is the "background memory writes + whitelisted reads are auto even when parked"
  decision in action.
- **`memory.forget(match:)` hitting many entries** → classified `.dangerous`; escalates to foreground via the
  needs-you badge even if parked; applies nothing until approved.
- **A subfile on disk with malformed front-matter** → that subfile is a `MemoryError.malformedSubfile`
  bounded problem (excluded from the index, the rest load), surfaced as a bounded non-blocking row — never an
  `NSAlert`, never a crash, never a silent drop.
- **TOC entry with no backing subfile** (user deleted the subfile by hand) → reconciliation drops the stale
  TOC line on next load; the router never sees a phantom subfile.
- **Subfile with no TOC entry** (agent crashed between writes) → reconciliation re-adds the TOC line from the
  subfile's front-matter `summary`; the fact tier is unaffected.
- **Empty / absent memory folder** → store creates it on first write; an empty CORE document is valid (no
  facts, no TOC); `memory.read` returns an empty-but-valid result, never an error.
- **A memory write whose disk IO fails** → mapped at the boundary into `MemoryError.writeFailed`,
  `ToolStepResult(.failed(headline:))`, audited as a failure; never a false "Done."
- **A memory name colliding with a skill id** → structurally impossible: different folders, `kind`-tagged,
  path-relative ids (the contract documented by `ai-skills-as-files`).

## Rejected alternatives

- **One ever-growing memory file fed every session.** Rejected: it drowns the routing prompt as it grows
  (the same problem skills solved with a TOC). The two-tier split keeps the always-read tier hard-capped and
  pulls detail on demand.
- **A second, memory-specific retriever.** Rejected by blueprint C2: skills and memory share ONE `DocIndex`;
  memory contributes `IndexedDoc`s, it does not define its own ranking/IO. Two retrievers would duplicate
  ranking + IO and let the combined TOC drift.
- **Defining `WritePolicyTier` / `AuditRecord` here.** Rejected by blueprint C1 + the ownership split: the
  bare `WritePolicyTier` is defined with `ToolDescriptor` in `ai-tool-routing`; `AuditRecord`/`AuditLog` +
  the whitelist are owned by `ai-background-autonomy`. Memory sets the descriptor default and emits records;
  it owns neither type.
- **Confirm-every-memory-write even when parked.** Rejected by the adopted user decision: a confirm wall on
  every "remember…" makes the companion feel like a form. Containment (memory-folder-only) + a full audit
  trail makes auto-when-parked safe; the whitelist toggle is the user's off-switch, and dangerous bulk ops
  still escalate.
- **Silent auto-promotion of frequently-mentioned facts into CORE.** Rejected: silent CORE growth is exactly
  what the cap exists to prevent, and "what is ground truth" is a judgment the user should see. The agent
  **proposes** (`memory.promote`); the cap is the backstop; the user overrides by hand.
- **Embedding-based memory retrieval in v1.** Rejected for v1: the shared deterministic keyword ranker is
  unit-testable without a model and is the cheap pre-filter; an embedding ranker is an additive future
  behind the same `DocIndex` seam (M5 can run it).
- **A separate JSON store for facts.** Rejected: Markdown facts + Markdown subfiles are hand-editable
  (the whole point of "editable by the user"), mirror the skill file format, and survive version control;
  JSON is hostile to no-code editing of detail prose.
