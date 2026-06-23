# AI Agent V2 — Shared Contracts Blueprint

**Status:** binding on the 9 parallel slice architects. Read this BEFORE writing your slice's
`proposal.md` / `design.md` / `tasks.md` / spec delta. It pins the shared TYPES so we do not invent
nine conflicting `Message`/`Conversation`/`AgentSessionID`/route/index/audit shapes.

This is the V2 evolution of the on-device AI feature: from preset, one-shot, fire-then-commit
commands into a **conversational, tool-using, memory-bearing, background-capable agent companion** on
Apple-Silicon M5. The decomposition is 9 slices, each planned by a separate architect in parallel.
This document is the only thing they all share.

---

## 0. Ground truth in the existing code (what V2 EVOLVES, never forks)

Read these before your slice. V2 reuses every one of these seams; it does not reinvent them.

| Existing seam | File | V2 role |
|---|---|---|
| `LLMRuntime` protocol (`generate`, `structured`, `capabilities`) | `AI/LLMRuntime.swift` | The single model seam. V2 ADDS a messages/conversation entry point alongside the existing prompt-string one — additive, never breaking. |
| `LLMRequest` (`prompt`, `image: Data?`, `parameters`, `reasoning`) | `AI/LLMRuntime.swift` | The per-turn request. V2 adds a messages-bearing constructor + optional per-turn image (already present). |
| `Token` / `TokenChannel` (`.response` / `.thinking`) | `AI/LLMRuntime.swift` | The thinking-channel split ALREADY EXISTS. V2 reuses it verbatim for the conversation runtime. Do NOT add a third channel without cross-slice sign-off. |
| `StructuredSchema` / `StructuredOutcome<T>` (`.value` / `.declined`) | `AI/LLMRuntime.swift` | The router (`ai-tool-routing`) reuses `structured()` as the tool-selection mechanism. Routing is a `structured()` call against a route schema. |
| `RuntimeError` (LocalizedError, Equatable taxonomy) | `AI/LLMRuntime.swift` | THE error taxonomy. Each slice adds at most one `<Slice>Error` LocalizedError; everything maps through `AIError.message(for:)`. |
| `AIError.message(for:) -> AIPresentedError` | `AI/AIError.swift` | THE single translator. Every new error surface routes through it. Never raw-interpolate an error into a headline. |
| `AICommandExecutor` + `State` machine | `AI/AICommandExecutor.swift` | The conversational canvas (`ai-conversational-canvas`) EXTENDS this state machine; it does not replace it. New states are additive cases. |
| `TaskDispatching` / `TaskDispatcher` / `TaskReview` / `PreparedAction` / `ReviewField` / `ParsedActions` | `AI/Tasks/*` | The tool-execute layer. A "tool" in V2 is a `TaskKind`-shaped capability; the route loop calls `prepare`/`execute`. Reuse `TaskReview`/`PreparedAction` for tool-step review. |
| `ModelManager` (lifecycle, residency, registry, provisioner) | `AI/ModelManager.swift` | Owns weights/residency. The batched runtime (`ai-batched-runtime-and-context`) plugs in behind `ModelProvisioner` / `runtimeFactory`. Context-size tuning lives adjacent. |
| `AICommand` / `TaskKind` / `Destination` / `OutputTarget` / `ModelSelector` | `AI/AICommand.swift` | The persisted command value model. `claudeHandoff` per-skill config and skill-as-file migration evolve from here. |
| `AICommandCatalog` (presets → categories) | `AI/AICommandCatalog.swift` | The seed corpus migrated into skills-as-files (`ai-skills-as-files`). |
| `GestureRecognizer.trackCanvasResolution` → `launcherCanvasResolve(dx:dy:)` + `canvasResolveThreshold` + `canvasAtTop` | `Gesture/GestureRecognizer.swift`, `AICommandExecutor` | The two-finger compass. V2 ADDS overscroll-park (UP past bottom) at the CONSUMER (AppCoordinator), not in the recognizer. Recognizer emits raw `±1`; interpretation stays at the seam. |
| `DockPreviewOverlayController` pattern (non-activating, `GlobalCursorMonitor`, orientation anchor, synchronous `orderOut`) | `Overlay/DockPreviewOverlay.swift` | The template for the notch home-zone rail surface (`ai-parked-sessions`). Reuse, do not reinvent. |

---

## 1. Naming conventions (binding)

- **Capabilities / spec dirs** keep the assigned names: `ai-command-band`, `on-device-ai-runtime`,
  `ai-command-tasks`, `ai-command-catalog`, `ai-memory`, `ai-parked-sessions`,
  `ai-background-autonomy`, `ai-claude-handoff`. New specs go under `openspec/specs/<capability>/`;
  deltas go under `openspec/changes/<change-name>/specs/<capability>/spec.md`.
- **Change directory names** = the slice names verbatim: `ai-conversational-canvas`,
  `ai-conversation-runtime`, `ai-tool-routing`, `ai-skills-as-files`, `ai-agent-memory`,
  `ai-parked-sessions`, `ai-background-autonomy`, `ai-claude-handoff`,
  `ai-batched-runtime-and-context`.
- **Swift types:** PascalCase, no `V2` suffix (this IS the codebase now). Prefix agent-era types with
  `Agent` ONLY where a bare name would collide with an existing one: `AgentMessage`,
  `AgentConversation`, `AgentSessionID`, `AgentTurn`. Where there is no collision and the concept is
  clearly the new world, no prefix is needed (`ToolRoute`, `SkillManifest`, `MemoryStore`,
  `AuditRecord`, `ParkedSession`).
- **Error taxonomy:** one `enum <Domain>Error: Error, Equatable` conforming to `LocalizedError` with a
  clean per-case `errorDescription`. Allowed new ones: `MemoryError`, `AuditError`, `HandoffError`,
  `ParkError` — each only if `RuntimeError`/`TaskError` genuinely cannot carry the case. Map vendor/OS
  errors into the taxonomy at the layer boundary. Surface via `AIError.message(for:)`.
- **Persisted keys** (in `AppSettings` / a new store): camelCase, agent-scoped prefix where ambiguous
  (`agentContextTokens`, `agentBackgroundWritePolicy`, `claudeHandoffBudgetPerDay`).
- **Files:** new agent code lives under `Sources/ThreeFingerSwitcher/AI/Agent/` (Core, MLX-free),
  `AI/Memory/`, `AI/Skills/`, `AI/Parked/`, `AI/Audit/`, `AI/Handoff/`; MLX-linked batched runtime
  lives in the `GemmaRuntime` target. Overlays under `Overlay/`.

---

## 2. Target-split & verification (binding, per house rules)

- **MLX-free `ThreeFingerSwitcherCore`** holds: all value types in this blueprint (messages,
  conversation, route schema, skill manifest, memory store + index, audit record, park scheduler,
  handoff config), the conversation state machine, the route→execute→continue loop logic, the
  retrieval/index logic, the park lifecycle. **Verified by `swift build` + `swift test`.** This is the
  majority of every slice. Every shared type below is Core.
- **MLX-linked `GemmaRuntime` / app target** holds: the batched MLX runtime conformer, KV-quant,
  context-window wiring, the real `LLMRuntime` messages path, and the overlay panels. **Verified by
  `xcodebuild` COMPILE ONLY.** Agents NEVER build/sign/install the `.app` (ad-hoc signing breaks TCC).
  The user does real builds.
- Each slice's `design.md` MUST state, per component, which target it lives in and how it is verified.
- To compile-check a subset in isolation, use a throwaway `git worktree` + `swift build` — never the
  shared working tree's `.app`.

---

## 3. SHARED CONTRACTS (canonical sketches — binding)

These are sketches, not final code. The OWNER slice writes the real type; CONSUMERS depend on it as
written here. If a consumer needs a change, it is a cross-slice negotiation, not a local fork.

### 3.1 Message / Conversation / session identity — OWNER: `ai-conversation-runtime`

```swift
// Core, MLX-free. The atom of a conversation. Reuses TokenChannel semantics for thinking.
public enum AgentRole: String, Codable, Sendable { case user, assistant, system, tool }

public struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var role: AgentRole
    public var text: String                 // the committed response/user text (NEVER the thinking)
    public var thinking: String?            // reasoning, retained for display only; never re-fed verbatim as ground truth
    public var image: Data?                 // optional per-turn image (PNG); mirrors LLMRequest.image
    public var toolCalls: [ToolRoute]?       // assistant turn that routed to tools (see 3.3)
    public var toolResult: ToolStepResult?   // for role == .tool: the executed step's outcome (see 3.3)
    public var createdAt: Date
}

// The session identity threaded through EVERY slice. One opaque value, stable across park/restore.
public struct AgentSessionID: Hashable, Codable, Sendable { public let raw: UUID }

public struct AgentConversation: Codable, Equatable, Identifiable, Sendable {
    public let id: AgentSessionID
    public var title: String                 // short, model- or first-turn-derived; shown on rail/badge
    public var messages: [AgentMessage]
    public var createdAt: Date
    public var updatedAt: Date
    public var compactedSummary: String?     // compaction output: prefix summary replacing old turns
    public var skillID: String?              // the active skill (file id) driving this session, if any
}

// A single conversational turn unit fed to the runtime (after compaction is applied).
public struct AgentTurn: Sendable {
    public var messages: [AgentMessage]      // the windowed/compacted message list for this generation
    public var image: Data?                  // convenience: latest turn's image
    public var reasoning: Bool
    public var parameters: GenerationParameters
}
```

- **Compaction** is OWNED here: when the windowed token estimate exceeds budget, old turns collapse
  into `compactedSummary` (a model call) and drop from `messages`. Core holds the pure
  windowing/estimate logic; the actual summarization is an `LLMRuntime` call.
- **Persistence:** `AgentConversation` is `Codable` and stored by the parked-sessions slice's store;
  the runtime slice owns the type, the parked slice owns durable storage. Do not duplicate the store.

### 3.2 Evolved `LLMRuntime` request (messages + per-turn image) — OWNER: `on-device-ai-runtime` (extended by `ai-conversation-runtime` & `ai-batched-runtime-and-context`)

The existing `LLMRuntime` protocol and `LLMRequest(prompt:image:parameters:reasoning:)` stay. V2 adds
a messages-bearing request and a protocol method — **additive**, default-implemented so existing
conformers (`StubLLMRuntime`, `DevAIRuntime`) keep compiling.

```swift
public struct LLMChatRequest: Sendable {
    public var messages: [AgentMessage]      // role-tagged multi-turn context (already compacted upstream)
    public var image: Data?                  // optional per-turn image; vision-capable runtime required if non-nil
    public var parameters: GenerationParameters
    public var reasoning: Bool
    public var tools: [ToolDescriptor]?      // advertised tools for route-mode (see 3.3); nil = plain chat
}

extension LLMRuntime {
    // Additive. Default impl flattens messages → a single prompt and calls generate(_:) so old
    // conformers work unchanged; the batched MLX conformer overrides for true KV-reuse multi-turn.
    func chat(_ request: LLMChatRequest) -> AsyncThrowingStream<Token, Error> { /* default flatten */ }
}
```

- The **batched runtime** (`ai-batched-runtime-and-context`) is a new `LLMRuntime` conformer that
  multiplexes K sessions over one weight read. It implements `chat` + a batched-stream extension
  (see 3.6). It plugs into `ModelManager` via the existing `ModelProvisioner` seam — no ModelManager
  API change required.
- **Context size** is a runtime/registry property: add `maxContextTokens` to `ModelDescriptor` and a
  user-adjustable `agentContextTokens` (clamped to model max), with RAM/speed cost surfaced in the UI.
  Owned by `ai-batched-runtime-and-context`; consumed by conversation-runtime's compaction budget.

### 3.3 Tool ROUTE schema — OWNER: `ai-tool-routing`

The router uses the EXISTING `structured()` call as the selection mechanism (house rule: reuse seams).
A tool is a `TaskKind`-shaped capability; routing decides which tool(s) to call with which arguments,
then the route→execute→continue loop runs them via `TaskDispatching`.

```swift
// A tool the model may call. Describes itself to the router (name + JSON-Schema args).
public struct ToolDescriptor: Codable, Equatable, Sendable {
    public let name: String                  // stable id, e.g. "add_to_calendar", "memory.write", "launch_claude"
    public let summary: String               // one line the model sees
    public let argsSchema: StructuredSchema   // reuse the runtime's schema type
    public let writePolicy: WritePolicyTier   // see 3.7 — drives auto/confirm/escalate
}

// The model's decision for one step. Produced via runtime.structured(routeSchema, as: ToolRoute.self).
public struct ToolRoute: Codable, Equatable, Sendable {
    public let tool: String                  // matches a ToolDescriptor.name, or "" for a plain text answer
    public let argumentsJSON: String         // JSON object string validated against that tool's argsSchema
    public let rationale: String?            // short, for the audit log + thinking display
}

// The outcome of executing one routed step. Reuses TaskReview/PreparedAction underneath.
public struct ToolStepResult: Codable, Equatable, Sendable {
    public let tool: String
    public let status: ToolStepStatus        // .done / .declined(reason) / .failed(headline) / .awaitingApproval
    public let summary: String               // short human-readable outcome, fed back into the loop as a tool message
}
public enum ToolStepStatus: Codable, Equatable, Sendable {
    case done, awaitingApproval
    case declined(reason: String)
    case failed(headline: String)            // clean headline only (AIPresentedError.headline); raw text to logs
}
```

- **The loop** (`route → execute → continue`) is OWNED here, pure in Core: ask `structured()` for a
  `ToolRoute`; if `tool == ""`, stream a text answer and stop; else look up the `ToolDescriptor`,
  validate args, dispatch via `TaskDispatching`, append a `.tool` `AgentMessage` carrying
  `ToolStepResult`, and re-enter. Bounded iteration count.
- **Approval grammar (canvas):** a tool step whose `writePolicy` requires confirmation surfaces a
  `TaskReview`-backed step; the canvas resolves it with **DOWN=approve / RIGHT=skip** (mirrors
  commit/discard). `awaitingApproval` is the observable state.
- Tools are registered in a `ToolRegistry` (Core) that aggregates: the existing `TaskKind` tasks,
  memory read/write tools (from `ai-agent-memory`), skill-invocation, and `launch_claude` (from
  `ai-claude-handoff`). Each contributor exposes `ToolDescriptor`s; routing slice owns the registry.

### 3.4 Shared retrieval / index shape — OWNER: `ai-skills-as-files` (the index); CO-OWNED contract with `ai-agent-memory`

Skills and memory are BOTH declarative files with a table-of-contents + on-demand retrieval. They
share ONE index/retrieval shape so we do not build two retrievers.

```swift
// One retrievable unit (a skill file, a memory subfile, a memory TOC entry).
public struct IndexedDoc: Codable, Equatable, Identifiable, Sendable {
    public let id: String                    // stable: file path-relative id
    public var title: String
    public var summary: String               // the TOC line — what the retriever ranks/returns first
    public var keywords: [String]
    public var kind: DocKind                  // .skill / .memoryCore / .memorySubfile
    public var bodyPath: URL                  // lazily loaded; retrieval returns summaries, body on demand
    public var updatedAt: Date
}
public enum DocKind: String, Codable, Sendable { case skill, memoryCore, memorySubfile }

// The shared retriever seam. Pure, synchronous over an in-memory index; file IO is bridged off-main
// by the owning store (mirrors the Files-band sync model + async cache pattern).
public protocol DocIndex: Sendable {
    func allSummaries() -> [IndexedDoc]                       // the TOC the model always sees
    func retrieve(query: String, limit: Int) -> [IndexedDoc]   // ranked summaries for on-demand expansion
    func body(of id: String) throws -> String                  // load a doc's full body when the model asks
}
```

- **Skills format** (`ai-skills-as-files`): a declarative file (front-matter `title/summary/keywords`
  + a prompt/body + optional `claudeHandoff` config + optional `tools` allow-list). The catalog
  migration (`AICommandCatalog` presets → skill files) is owned here. The skill folder + index/load is
  owned here; it produces `IndexedDoc(kind: .skill)`.
- **Memory** (`ai-agent-memory`): two-tier — a core ground-truth file + TOC, plus named subfiles,
  editable by agent and user. It produces `IndexedDoc(kind: .memoryCore/.memorySubfile)` over the SAME
  `DocIndex` seam. Memory owns its store + read/write tools; it reuses the retriever contract, it does
  not define a second one.
- **Retrieval mechanic:** the model always sees `allSummaries()` (the combined TOC); it requests a
  body via a `retrieve`/`read` tool (a `ToolDescriptor`), so retrieval is itself a routed tool step.

### 3.5 Parked-session scheduler interface — OWNER: `ai-parked-sessions`

The batched runtime plugs into THIS. Parked sessions are durable conversations the agent advances in
the background; the scheduler decides which session each batch slot serves.

```swift
public enum ParkState: Codable, Equatable, Sendable {
    case active                              // foreground, in the canvas
    case parked                              // stashed at the notch home zone, may run in background
    case needsYou                            // a dangerous write / approval escalated to foreground (badge)
    case idle                                // nothing pending
}

public struct ParkedSession: Codable, Equatable, Identifiable, Sendable {
    public var id: AgentSessionID            // SAME identity as AgentConversation.id (3.1)
    public var title: String
    public var state: ParkState
    public var badgeCount: Int               // unseen results / needs-you items, shown on the rail
    public var nextRunAt: Date?              // scheduler hint (a timed/scheduled continuation)
    public var updatedAt: Date
}

// The seam the batched runtime consumes to pick work. Pure scheduling decisions in Core.
public protocol ParkScheduler: Sendable {
    func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID]   // which parked sessions to advance
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult)         // feedback after a batch step
    func escalate(_ id: AgentSessionID, reason: String)                    // → .needsYou + badge (dangerous write)
}
```

- The **batched runtime** (`ai-batched-runtime-and-context`) calls `runnableSessions(now:maxSlots:)`
  to fill its K batch slots, advances each via `chat`, and reports back via `didAdvance`. The scheduler
  itself is pure/testable; `now:` is an input (mirrors `DockHoverModel`).
- The **notch home zone + rail** is a `DockPreviewOverlay`-pattern non-activating panel (synchronous
  `orderOut`). Park is triggered by **overscroll-past-bottom** (UP excursion past the canvas bottom) —
  the consumer (AppCoordinator) interprets the recognizer's raw direction; the recognizer is unchanged.

### 3.6 Batched runtime extension — OWNER: `ai-batched-runtime-and-context`

```swift
// MLX-linked. A new LLMRuntime conformer; plugs into ModelManager via ModelProvisioner.
// K streams share ONE weight read per token step. KV cache is quantized per stream.
protocol BatchedLLMRuntime: LLMRuntime {
    // Advance up to K sessions one decode step each, sharing the weight read.
    func batchStep(_ requests: [AgentSessionID: LLMChatRequest]) -> AsyncThrowingStream<(AgentSessionID, Token), Error>
    var maxConcurrentStreams: Int { get }    // K
}
```

- Consumes `ParkScheduler.runnableSessions` for which sessions to batch; consumes `LLMChatRequest`
  (3.2) per session; emits `Token`s keyed by `AgentSessionID`. Foreground active session always gets a
  slot. KV-quant + context tuning are internal to this slice; the user-facing context slider
  (`agentContextTokens`, RAM/speed cost surfaced) is owned here.

### 3.7 Write-policy tiers + audit record — OWNER: `ai-background-autonomy`

```swift
public enum WritePolicyTier: String, Codable, Equatable, Sendable {
    case auto                                // whitelisted/safe: runs without confirm, even when parked (still audited)
    case confirm                             // default: needs foreground approval (DOWN=approve / RIGHT=skip)
    case dangerous                           // always escalates to foreground via needs-you badge, even if parked
}

// One row in the append-only background audit log. Every tool step (auto or not) writes one.
public struct AuditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: AgentSessionID
    public let tool: String
    public let policy: WritePolicyTier
    public let argumentsSummary: String      // redacted/short args, NOT raw secrets
    public let outcome: ToolStepStatus       // reuses 3.3
    public let wasBackground: Bool           // true if applied while parked
    public let timestamp: Date
}

public protocol AuditLog: Sendable {
    func record(_ r: AuditRecord)
    func recent(limit: Int) -> [AuditRecord]
}
```

- **User decision (adopted, do not relitigate):** background memory writes + whitelisted writes are
  **AUTO even when parked** (still audited). **Dangerous** writes escalate to foreground via the
  needs-you badge (`ParkState.needsYou`). The **user whitelist** is owned here: which tools/skills are
  `.auto`. The routing slice reads `writePolicy` off the `ToolDescriptor`; this slice owns the
  policy resolution (descriptor default ∩ user whitelist → effective tier) and the audit log.

### 3.8 Per-skill Claude handoff config — OWNER: `ai-claude-handoff`

```swift
public enum HandoffConfirmMode: String, Codable, Equatable, Sendable {
    case confirm                             // DEFAULT: confirm per call
    case auto                                // per-skill opt-in: fire without confirm (still budget-capped + audited)
}

public struct ClaudeHandoffConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var confirmMode: HandoffConfirmMode   // default .confirm
    public var maxCallsPerDay: Int               // budget/rate cap
    public var maxConcurrent: Int
    // v1 is FIRE-AND-FORGET: launch Claude Code with a prompt/cwd; no structured round-trip back.
    public var defaultWorkingDirectory: URL?
}
```

- **User decision (adopted):** handoff defaults to **CONFIRM per call**, with **per-skill AUTO
  opt-in** and a **budget/rate cap**; **v1 handoff is FIRE-AND-FORGET** (round-trip is documented
  future, out of scope). `launch_claude` is a `ToolDescriptor` (write-policy `.confirm` unless the
  skill opts into `.auto`); the handoff slice owns launching `claude` (process spawn, like the existing
  open-claude-here change). Per-skill config rides on the skill file (3.4) as an optional block.

---

## 4. Dependency DAG & implementation order (coarse, binding)

```
on-device-ai-runtime (LLMChatRequest, chat(), context props)  ── foundational, do first
        │
        ├──> ai-conversation-runtime (AgentMessage/Conversation/SessionID, compaction)  ── the type home
        │            │
        │            ├──> ai-tool-routing (ToolRoute/ToolDescriptor/ToolStepResult, the loop, ToolRegistry)
        │            │            │
        │            │            ├──> ai-skills-as-files (DocIndex, skill files, catalog migration)  ┐
        │            │            ├──> ai-agent-memory   (DocIndex consumer, memory tools)            ├ share DocIndex (3.4)
        │            │            └──> ai-claude-handoff  (launch_claude tool, ClaudeHandoffConfig)    ┘
        │            │
        │            └──> ai-conversational-canvas (extends AICommandExecutor.State, the compass, park-trigger)
        │
        └──> ai-batched-runtime-and-context (BatchedLLMRuntime, KV-quant, context tuning)
                     │
                     └──> ai-parked-sessions (ParkedSession/ParkState/ParkScheduler, notch rail, lifecycle)
                                  │
                                  └──> ai-background-autonomy (WritePolicyTier, AuditRecord, whitelist)
```

**Coarse order (waves):**
1. **Wave 1 (foundations, define-the-types):** `on-device-ai-runtime` (chat request + context props),
   `ai-conversation-runtime` (message/conversation/session types + compaction).
2. **Wave 2 (routing + batched core):** `ai-tool-routing` (route schema + loop + registry),
   `ai-batched-runtime-and-context` (batched conformer + context tuning).
3. **Wave 3 (capability providers, parallel):** `ai-skills-as-files`, `ai-agent-memory`,
   `ai-parked-sessions`.
4. **Wave 4 (policy + UX + handoff):** `ai-background-autonomy`, `ai-claude-handoff`,
   `ai-conversational-canvas`.

Architects plan in parallel NOW regardless of wave; the waves are the *implementation* order so a
later slice can assume an earlier slice's types exist. If you OWN a Wave-1/2 type, write it exactly as
3.x; if you CONSUME it, import it as written and do not redefine.

---

## 5. Per-slice interface notes (MUST expose / MUST consume)

**1. ai-conversational-canvas** (cap `ai-command-band`)
- MUST EXPOSE: additive `AICommandExecutor.State` cases for multi-turn (`.conversing`, `.awaitingApproval(ToolReview)`, `.parked`); the seed → float-up → gesture-compass UX; the park-on-overscroll trigger consumed by `ai-parked-sessions`.
- MUST CONSUME: `AgentConversation`/`AgentMessage` (3.1); the route loop's observable state (3.3); the CANONICAL compass — DOWN=affirm (only when `canvasAtTop`), UP=scroll/overscroll-park, RIGHT=discard, LEFT=reserved, Enter=send; `canvasResolveThreshold`. Reuse `AICommandCanvasView`, `BubbleMorph`, `TaskReview` rendering.

**2. ai-conversation-runtime** (cap `on-device-ai-runtime`)
- MUST EXPOSE: `AgentMessage`/`AgentRole`/`AgentConversation`/`AgentSessionID`/`AgentTurn` (3.1); the compaction (windowing + summary) logic; the conversation→`LLMChatRequest` assembly.
- MUST CONSUME: `LLMChatRequest`/`chat()` (3.2); `TokenChannel` for thinking; `agentContextTokens` budget from `ai-batched-runtime-and-context`.

**3. ai-tool-routing** (cap `ai-command-tasks`)
- MUST EXPOSE: `ToolDescriptor`/`ToolRoute`/`ToolStepResult`/`ToolStepStatus` (3.3); the `ToolRegistry`; the pure route→execute→continue loop (bounded); the approval-step contract (DOWN=approve/RIGHT=skip).
- MUST CONSUME: `structured()` + `StructuredSchema`/`StructuredOutcome` as the router; `TaskDispatching`/`TaskReview`/`PreparedAction` for execution; `WritePolicyTier` (3.7) off each descriptor; `AgentMessage` (3.1) to append `.tool` turns.

**4. ai-skills-as-files** (cap `ai-command-catalog`)
- MUST EXPOSE: the skill file format (front-matter + body + optional `claudeHandoff`/`tools`); the skill folder layout; `IndexedDoc(kind: .skill)` over `DocIndex` (3.4); the `AICommandCatalog` → skill-files migration (idempotent, identity-preserving).
- MUST CONSUME: `DocIndex` (3.4, OWNS the index but shares the contract with memory); `ToolDescriptor` for the skill's allowed tools; `ClaudeHandoffConfig` (3.8) as an optional skill block.

**5. ai-agent-memory** (cap `ai-memory`)
- MUST EXPOSE: the two-tier store (core ground-truth + TOC, named subfiles); `IndexedDoc(kind: .memoryCore/.memorySubfile)` over the SHARED `DocIndex` (3.4); memory read/write `ToolDescriptor`s (write tools carry `WritePolicyTier`).
- MUST CONSUME: `DocIndex` contract (3.4, do NOT define a second retriever); `WritePolicyTier`/`AuditRecord` (3.7) for edits; `AgentSessionID` (3.1) for attribution.

**6. ai-parked-sessions** (cap `ai-parked-sessions`)
- MUST EXPOSE: `ParkedSession`/`ParkState`/`ParkScheduler` (3.5); the durable `AgentConversation` store; the notch home-zone rail + badges (DockPreviewOverlay pattern, synchronous teardown); the lifecycle (park/restore/needs-you).
- MUST CONSUME: `AgentConversation`/`AgentSessionID` (3.1); the canvas overscroll-park trigger (slice 1); the batched runtime as the background advancer (3.6); `ParkState.needsYou` escalation from `ai-background-autonomy`.

**7. ai-background-autonomy** (cap `ai-background-autonomy`)
- MUST EXPOSE: `WritePolicyTier` (3.7); the `AuditRecord`/`AuditLog` (3.7); the user whitelist + effective-tier resolution; the auto-when-parked vs escalate-dangerous decision.
- MUST CONSUME: `ToolDescriptor.writePolicy` (3.3); `ParkScheduler.escalate` (3.5) to raise `.needsYou`; `AgentSessionID` (3.1); `AIError`/`AIPresentedError` for clean headlines in audit + escalation.

**8. ai-claude-handoff** (cap `ai-claude-handoff`)
- MUST EXPOSE: `ClaudeHandoffConfig` (3.8); the `launch_claude` `ToolDescriptor`; fire-and-forget process launch; the budget/rate-cap enforcement; a `HandoffError` if needed.
- MUST CONSUME: `ToolDescriptor`/route loop (3.3); `WritePolicyTier` (default `.confirm`, per-skill `.auto`); `AuditRecord` (3.7); the per-skill block on the skill file (3.4). Reuse the existing open-claude-here launch path.

**9. ai-batched-runtime-and-context** (cap `on-device-ai-runtime`)
- MUST EXPOSE: `BatchedLLMRuntime` (3.6); KV-quant + K-stream batching; `ModelDescriptor.maxContextTokens` + the user-adjustable `agentContextTokens` (RAM/speed cost surfaced in UI); plug-in via `ModelProvisioner`.
- MUST CONSUME: `LLMChatRequest` (3.2); `ParkScheduler.runnableSessions` (3.5) to fill batch slots; `AgentSessionID` (3.1) to key streams; existing `ModelManager` residency seam.

---

## 6. Cross-cutting user decisions (adopted — every architect honors)

1. **Hardware:** Apple-Silicon M5/M4 ONLY (this machine: M5 Pro, 16-core GPU, 48GB unified). No
   Intel/low-end fallbacks, no defensive degraded paths. The batched runtime + growable context are in
   scope precisely because the hardware can serve them.
2. **Errors:** ONE taxonomy (`RuntimeError`/`TaskError` + at most one `<Slice>Error`), ONE translator
   (`AIError.message(for:)` → `AIPresentedError`), mapped at the layer boundary, surfaced BOUNDED +
   NON-BLOCKING. Never `NSAlert.runModal`. Never raw error text in a headline (logs/opt-in details
   only). A failure is an observable `.failed`/`.declined` state with a clean headline; a side effect
   that did not land is `.failed`, never a false "Done."
3. **Overlays:** non-activating panels, SYNCHRONOUS `orderOut` teardown (ghost-on-Space-switch bug).
   The notch rail + any cursor-reveal surface reuse the `DockPreviewOverlay` pattern (edge-gated
   `GlobalCursorMonitor`, orientation-aware anchor, mouse-interactive non-key panel).
4. **Canonical gesture compass** (two-finger, post-activation, in the AI canvas):
   **DOWN = affirm** (extract latest answer / approve a step) — fires only when `canvasAtTop`.
   **UP = scroll**, and **overscroll-past-bottom = PARK** to the notch home zone.
   **RIGHT = discard.** **LEFT = reserved** (free for now). **Enter (keyboard) = send the turn.**
   Honor `canvasResolveThreshold` (above incidental two-finger scroll). Spatial mnemonic: TOP of canvas
   = act on it, BOTTOM = stash it. Tool-step approval reuses DOWN=approve / RIGHT=skip. The recognizer
   keeps emitting raw `±1`; interpretation lives at the consumer seam.
5. **Reuse, do not reinvent:** `LLMRuntime`, `AICommandExecutor` + its `State`, `TaskDispatching` /
   `TaskReview` / `PreparedAction` / `ParsedActions` / `TaskSinks`, `SelectionProviding` /
   `SelectionService`, `ModelManager`, `PromptTemplate`, `BubbleMorph`, `GlobalCursorMonitor`,
   `DockHoverModel` anchoring, `ClipboardBandLayout` metrics.
6. **Background autonomy:** background memory writes + whitelisted writes are AUTO even when parked
   (still audited); dangerous writes escalate to foreground via the needs-you badge.
7. **Claude handoff:** defaults to CONFIRM per call; per-skill AUTO opt-in; budget/rate cap; v1 is
   FIRE-AND-FORGET (round-trip is a documented future).
8. **Batched runtime is in scope NOW** (this is V2). **Context is growable to the model max AND
   user-adjustable, with RAM/speed cost surfaced in the UI.**

---

## 7. OpenSpec authoring rules (every slice)

- Mirror the structure of `openspec/changes/add-gesture-previews-and-bindings/` EXACTLY:
  `proposal.md` (Why / What Changes / Capabilities [New + Modified] / Impact), `design.md`
  (Context / Goals-Non-Goals / Decisions [numbered] / target-split + verification per component),
  `tasks.md` (numbered `## N.` sections, `- [ ]` checkboxes with verification notes), and
  `specs/<capability>/spec.md` deltas using `## ADDED/MODIFIED/REMOVED Requirements` with
  `### Requirement:` + `#### Scenario:` WHEN/THEN phrasing.
- Read the relevant existing spec under `openspec/specs/<capability>/` first so your delta is a TRUE
  delta (ADDED/MODIFIED), not a rewrite.
- Add a `.openspec.yaml` (`schema: spec-driven`, `created:` date) to your change dir.
- Do NOT write Swift / application code in the planning run — OpenSpec artifacts only.
