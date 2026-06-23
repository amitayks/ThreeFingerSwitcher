## Why

The V2 agent is meant to be a **companion**, not a stateless command box. Today the on-device AI has no
durable knowledge of the user: `AICommandExecutor.fire(_:)` starts from zero every time, and even the new
multi-turn conversation (`ai-conversation-runtime`) is compacted and eventually discarded — nothing the
user told the agent two sessions ago survives. A companion has to **remember**: stable facts ("I work at
Acme", "my partner is Dana", "I prefer metric units"), and the detail behind those facts ("the full notes
on the Acme migration project") — and it has to be able to **write** that memory itself ("remember that…")
and let the user edit it by hand.

The naive approach — one ever-growing memory file fed every session — fails on the V2 hardware budget for
the wrong reason: not that an M5 can't hold it, but that **dumping unbounded memory into every routing
prompt drowns the signal**. The router (`ai-tool-routing`) already learned this lesson for skills: it sees
a cheap **table of contents** of one-line summaries and pulls a full body only on demand
(`ai-skills-as-files` owns that `DocIndex` retriever). Memory has the identical shape — a small set of
always-true facts plus a large, named, on-demand detail corpus — so it must reuse the **same** retriever,
not invent a second one.

This slice builds that memory: a **two-tier store** (a hard-capped CORE of ground-truth facts + a table of
contents of named SUBFILES; the subfiles hold the details, pulled by relevance) with **memory tools** the
agent routes to (`memory.read` is free; `memory.write` / `memory.forget` are side-effecting and audited),
**editable by hand and by direction**. It is Wave 3: it consumes the `DocIndex` contract owned by
`ai-skills-as-files`, the `WritePolicyTier`/`AuditRecord` contract owned by `ai-background-autonomy`, and
`AgentSessionID` from `ai-conversation-runtime`. It is entirely MLX-free Core and verifies under
`swift test`.

## What Changes

- **A two-tier on-disk memory store** (`MemoryStore`, MLX-free Core) paralleling `DiskProjectStore`:
  under Application Support, a single **CORE** document (`core.md`) holding ground-truth facts **plus a
  table of contents** that lists every subfile by name with its one-line summary, and a **subfiles** folder
  (`memory/subfiles/<name>.md`) holding the details. CORE is read **every session**; subfiles are pulled
  **on demand by relevance**. CORE never holds details — only facts and the TOC of subfiles.
- **A hard size cap on CORE that physically evicts to subfiles.** When a write would push CORE past its
  byte/line cap, the store **evicts** the lowest-value detail-bearing content into a subfile and replaces it
  in CORE with a TOC entry — the cap is a backstop that cannot be exceeded, so the always-read tier stays
  bounded regardless of how much the agent tries to keep.
- **Promotion to CORE is propose-then-keep, with the cap as the backstop.** The agent does not silently
  fill CORE: it **proposes** ("keep this in core?") via a dedicated `memory.promote` step; the user (or the
  whitelist) decides. The hard cap is the structural guarantee underneath the proposal. The user can
  override promotion/eviction by editing the files by hand.
- **Memory tools, exposed as `ToolDescriptor`s into the `ToolRegistry`.** `memory.read` (free — runs even
  when the session is parked, carries `WritePolicyTier.auto`, reads CORE + retrieves relevant subfiles);
  `memory.write` / `memory.update` / `memory.forget` (side-effecting). **Per the adopted user decision,
  memory writes are WHITELISTED → effective `.auto`, so they run without a confirm even when parked** — but
  they are **always audited** (every write emits an `AuditRecord`) and the store is **contained** (it can
  only touch the memory folder). A dangerous memory operation (a bulk `forget`, a CORE rewrite) escalates to
  `.dangerous` and surfaces via the needs-you badge.
- **Editable by agent AND by hand.** The agent edits by direction ("remember…" → `memory.write`,
  "forget…" → `memory.forget`); the user edits the same Markdown files directly (no app needed), and the
  store **watches + reloads** off-main (the Files-band cache pattern). User edits and agent edits converge on
  the same files.
- **Memory contributes `IndexedDoc`s into the SHARED `DocIndex`** (kind `.memoryCore` / `.memorySubfile`),
  so the combined skills-and-memory table of contents is **one** enumeration ranked by **one** retriever.
  This slice **consumes** the `DocIndex` contract owned by `ai-skills-as-files`; it defines **no** second
  retriever (blueprint C2).

## Capabilities

### New Capabilities

- `ai-memory`: the two-tier agent memory — a hard-capped CORE ground-truth document carrying a table of
  contents of named subfiles, the on-demand subfile detail tier, the evict-on-cap + propose-to-promote
  policy, the `memory.read`/`write`/`update`/`forget`/`promote` tools (writes whitelisted-auto + audited),
  hand- and agent-editability with off-main watch/reload, and the contribution of memory `IndexedDoc`s into
  the shared `DocIndex`.

## Impact

- **Code (MLX-free Core, `swift test`):** new `AI/Memory/MemoryStore.swift` (the on-disk two-tier store,
  paralleling `DiskProjectStore`), `AI/Memory/MemoryDocument.swift` (the pure CORE parse/serialize: facts +
  TOC block, with the cap + eviction decision as a pure function), `AI/Memory/MemorySubfile.swift` (the
  subfile front-matter+body format, mirroring the skill file), `AI/Memory/MemoryToolProvider.swift` (the
  memory `ToolDescriptor`s + `invoke` that reads/writes and returns a `ToolStepResult`), and a new
  `enum MemoryError: Error, Equatable, LocalizedError` plus an `AIError.message(for:)` extension.
- **Reuse, not rebuild:** the `DocIndex`/`IndexedDoc`/`DocKind` retriever (owned by `ai-skills-as-files`) —
  memory contributes its docs into the SAME in-memory snapshot; `ToolDescriptor`/`ToolRoute`/`ToolStepResult`
  + `WritePolicyTier` (owned by `ai-tool-routing`); `AuditRecord`/`AuditLog` + the user whitelist + effective-
  tier resolution (owned by `ai-background-autonomy`); `AgentSessionID` (owned by `ai-conversation-runtime`)
  for write attribution; `DiskProjectStore`'s Application-Support + sanitized-filename + IO-boundary-error
  pattern; the Files-band sync-model + async-cache + coalesced-watch pattern; `AIError.message(for:)` as the
  one translator.
- **MLX-free Core only:** the store, the parse/serialize, the cap/eviction decision, the ranking
  contribution, and the tool provider are all pure value types + file IO + a stub-driven invoke, so the whole
  slice verifies under `swift build` / `swift test`. No piece links MLX. The full app link is
  `xcodebuild` compile-verify only; the **user** does the real install to exercise hand-editing the files
  end-to-end. (House rule: an agent never builds/signs/installs the `.app`.)
- **Out of scope:** the route → execute → continue loop and the `ToolRegistry` aggregation
  (`ai-tool-routing` owns them; this slice provides a contributor); defining `DocIndex`/`IndexedDoc` or any
  ranking/IO (`ai-skills-as-files` owns the retriever); defining `WritePolicyTier`/`AuditRecord`/`AuditLog`
  or the whitelist UI (`ai-background-autonomy` owns them; this slice sets the descriptor default and emits
  audit records); the parked-session lifecycle and the needs-you escalation transport (`ai-parked-sessions`
  owns `ParkScheduler.escalate`; this slice only marks dangerous ops); a Hub UI for browsing/editing memory
  (v1 editing is file-based, like dropping a `.md`); embeddings / semantic memory ranking (a future behind
  the same `DocIndex` seam); cross-device memory sync.
