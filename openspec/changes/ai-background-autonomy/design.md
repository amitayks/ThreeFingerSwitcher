## Context

This slice is **Wave 4** of the V2 AI agent (see `docs/ai-agent-v2-blueprint.md` §3.7). It is the **policy layer**: it owns the user **whitelist**, **effective-tier resolution**, the append-only **audit log**, and the parked **auto-vs-escalate** decision. It consumes types from earlier waves verbatim and never redefines them.

Read these before the design — they are the ground truth this slice plugs into, not forks:

- **`ai-tool-routing` (Wave 2, on disk at `openspec/changes/ai-tool-routing/`)** — OWNS the bare `WritePolicyTier` enum (`auto`/`confirm`/`dangerous`) on every `ToolDescriptor`, integration fix **C1**. It already gates each step through an **injected `WritePolicyResolving`** seam with a stand-alone `DescriptorWritePolicy` default that returns `descriptor.writePolicy` unchanged. Its loop (`AgentLoop`, Decision 7) calls `registry.run(call, gate:)`; the contributor reads the effective tier and either runs `.auto` immediately or pauses `.confirm`/`.dangerous` for the `ApprovalGate` (DOWN=approve / RIGHT=skip). **This slice ships the real `WritePolicyResolving` conformer** that replaces `DescriptorWritePolicy` in production, plus the audit + escalation wiring around `registry.run`. No routing type is redefined here.
- **`ai-parked-sessions` (Wave 3, on disk)** — OWNS `ParkState` (`active`/`parked`/`needsYou`/`idle`), `ParkedSession`, and `ParkScheduler` with `escalate(_ id: AgentSessionID, reason: String)` (→ `.needsYou` + badge + ambient notch glow). It explicitly defers "what makes a step `needs-you`" to **this** slice. This slice never renders the badge or glow — it **calls `escalate`**; the rail renders.
- **`ai-conversation-runtime` (Wave 1)** — OWNS `AgentSessionID` (used to attribute every `AuditRecord` and every escalation).
- **`AI/Tasks/TaskSinks.swift` / `TaskDispatcher.swift` / `AICommandExecutor.swift`** — the existing side-effect machinery. The sinks (`CalendarSink`, `ReminderSink`, `ContactSink`, `ProjectStore`, `ToolOpener`, `DestinationSender`) are what the tiers map onto. `TaskError`/`AIError.message(for:)` already enforce "no raw error text in a headline; a side effect that did not land is `.failed`, never a false Done." This slice inherits that contract — an audited outcome is a `ToolStepStatus`, never a fabricated success.
- **`AI/AIError.swift`** — the SINGLE translator `AIError.message(for:) -> AIPresentedError`. Every headline this slice surfaces (a failed audit-store write, an escalation reason) routes through it.

The blueprint §3.7 pins `AuditRecord`/`AuditLog` and the user decisions; this slice OWNS them.

## Goals / Non-Goals

**Goals:**
- A crisp **blast-radius tier model** (CONTAINED / WHITELISTED / DANGEROUS) with every existing and planned tool/sink mapped to a default `WritePolicyTier`, and the rule for lowering a tier to `.auto` (CONTAINED or whitelist match) — pure, `swift test`-able.
- A **user-visible, user-editable whitelist**: path prefixes + command-pattern globs, default-empty for arbitrary entries, memory + project stores **pre-trusted** as CONTAINED (not whitelist rows). Pure matching rules.
- The concrete **`WritePolicyResolving`** conformer the routing loop already injects, so resolution is a drop-in (no routing API change).
- An **append-only audit log** (`AuditRecord`/`AuditLog`) with a redacted args summary, persisted + capped, viewable in the notch rail drop-down and the Hub.
- A pure **`BackgroundGate`** auto-vs-escalate decision: `.auto` runs + audits even when parked; `.dangerous` while parked → `escalate` → `.needsYou`; `.confirm` while parked waits.
- One `AuditError` only where `RuntimeError`/`TaskError`/`ParkError` cannot carry a store failure; mapped at the boundary; surfaced bounded + non-blocking.

**Non-Goals:**
- Defining `WritePolicyTier` (OWNED by `ai-tool-routing`, C1) — consumed verbatim.
- The per-step **approval gesture** + `ApprovalGate` (OWNED by `ai-tool-routing` / `ai-conversational-canvas`); this slice decides *which tier a parked step is*, not how the user resolves it.
- The needs-you **badge + notch glow rendering** and the `ParkState` machine (OWNED by `ai-parked-sessions`); this slice only calls `escalate`.
- The Claude-handoff **budget/rate cap** (OWNED by `ai-claude-handoff`); it consumes `AuditRecord` and the `.confirm`-default/`.auto`-per-skill resolution from here.
- **Rollback/undo** of a completed side effect — explicitly impossible (`ai-parked-sessions` Decision 7); the audit log records what happened, it does not reverse it.
- Any Intel/low-end fallback. Apple-Silicon M5/M4 only.

## Decisions

### 1. The blast-radius tier model — three tiers, mapped onto `WritePolicyTier`

The three blast-radius tiers are the **conceptual** classification; they collapse onto the existing `WritePolicyTier` (`auto`/`confirm`/`dangerous`) so no new enum is born:

| Blast radius | Meaning | Parked behavior | `WritePolicyTier` |
|---|---|---|---|
| **CONTAINED** | The app's own stores — agent memory + project notes. Bounded, reversible-in-spirit, never touches the user's wider filesystem. | **AUTO, even parked** (still audited). | descriptor ships `.auto` |
| **WHITELISTED** | A write/command whose **target matches a user whitelist entry** (a path under a trusted prefix, or a command matching a trusted pattern). | **AUTO if matched** (still audited). | descriptor ships `.confirm`; resolution **lowers to `.auto`** on a match |
| **DANGEROUS** | Delete, overwrite an existing file, arbitrary shell, anything **off-list**, and the Claude-handoff cost. | **FOREGROUND-ONLY**: park → `needsYou` badge + notch glow; resolved by pulling the session back and DOWN=approve. | descriptor ships `.dangerous` (or `.confirm` that did NOT match the whitelist) |

The key asymmetry, encoded once: **the whitelist may only LOWER `.confirm` → `.auto`; it may NEVER lower `.dangerous`.** A delete or overwrite-existing is dangerous regardless of where it lands — a trusted folder does not make `rm` safe. CONTAINED is intrinsic to the descriptor (the memory/project store tools ship `.auto`), not a whitelist row, so it is auto even with an empty whitelist.

**Tool/sink → default tier map** (each is the `writePolicy` the `ToolDescriptor` ships with, set by the owning slice; this slice asserts the mapping and classifies CONTAINED-ness):

| Tool / sink (current or planned) | Owning slice | Blast radius | Default `WritePolicyTier` | Notes |
|---|---|---|---|---|
| `memory.read` | ai-agent-memory | CONTAINED (read) | `.auto` | read-only; always auto |
| `memory.write` (core / subfile) | ai-agent-memory | **CONTAINED** | `.auto` | the app's own store → auto even parked, audited |
| `save_to_project:<project>` (`ProjectStore`) | ai-command-tasks | **CONTAINED** | `.auto` | append-only into the app's project note store |
| `retrieve` / `widen_candidates` (skills+memory index) | ai-tool-routing / skills | CONTAINED (read) | `.auto` | read-only retrieval |
| `add_to_calendar` (`CalendarSink`) | ai-command-tasks | external write | `.confirm` | creates an event in the user's calendar; whitelist does not apply (no path/command) → stays `.confirm` |
| `add_to_reminders` (`ReminderSink`) | ai-command-tasks | external write | `.confirm` | as above |
| `new_contact` (`ContactSink`) | ai-command-tasks | external write | `.confirm` | as above |
| `open_tool_with_payload:<tool>` (`ToolOpener`) | ai-command-tasks | launch / shell | `.confirm` → maybe `.auto` | a **command pattern** match (the tool/Shortcut name) can lower to `.auto`; a free-form shell tool that matches no pattern stays `.confirm` |
| `send_to:<destination>` (`DestinationSender`) | ai-command-tasks | shortcut / URL / **shell** | `.confirm` (shell variant **`.dangerous`**) | the `.shell(command)` destination is arbitrary shell → DANGEROUS unless its command matches a whitelist pattern; `.shortcut`/`.urlScheme` are `.confirm`, lowerable by a command-pattern match |
| `launch_claude` (`ClaudeHandoffContributor`) | ai-claude-handoff | spawns a Claude process (cost) | `.confirm` (per-skill `.auto` opt-in) | the handoff cost is DANGEROUS-by-spend; default `.confirm`, a skill may opt `.auto`, still budget-capped + audited (owned there) |
| a future **file delete / move / overwrite-existing** tool | future | **DANGEROUS** | `.dangerous` | never lowered by the whitelist; always foreground |

This table is the **classification authority**: the slice ships a `BlastRadius` view over a descriptor (`contained` / `external` / `dangerous`) derived from the descriptor's name + tier, and unit-tests the whole map.

### 2. `BlastRadius` + the CONTAINED predicate (pure Core)

```swift
public enum BlastRadius: Equatable, Sendable {
    case contained      // app's own stores; descriptor ships .auto
    case external       // touches the user's world but bounded (calendar/contacts/launch/send)
    case dangerous      // delete/overwrite-existing/arbitrary-shell/off-list/handoff-cost
}
```

A pure classifier reads a `ToolDescriptor` (its stable `name` + `writePolicy`):
- `descriptor.writePolicy == .dangerous` → `.dangerous` (unconditional).
- the descriptor name is a CONTAINED tool (memory.* / save_to_project / read-only retrieval) → `.contained`.
- otherwise → `.external`.

CONTAINED-ness is matched on a **stable name prefix set** owned here (`["memory.", "save_to_project", "retrieve", "widen_candidates"]`) so the policy layer recognizes the app's own stores without importing the memory slice. (A descriptor whose owning slice flags itself CONTAINED via its shipped `.auto` tier AND a name in this set is contained; a `.auto` descriptor NOT in the set is a defensive `.external` — a non-contained tool should never ship `.auto`, asserted in debug.)

### 3. The whitelist — a pure, persisted, user-editable security boundary

```swift
public struct Whitelist: Codable, Equatable, Sendable {
    public var trustedPathPrefixes: [String]    // standardized absolute path prefixes the user trusts for writes
    public var trustedCommandPatterns: [String] // glob patterns matched against a command/tool/shortcut name
    public static let empty = Whitelist(trustedPathPrefixes: [], trustedCommandPatterns: [])
}
```

- **Default-empty** for arbitrary entries — a fresh install trusts nothing on the wider filesystem. The memory + project stores are CONTAINED (Decision 2), so they are auto **without** any whitelist row; the user never has to whitelist the app's own stores.
- **Matching rules (pure, unit-tested):**
  - A **path target** matches iff its standardized absolute path has one of `trustedPathPrefixes` as a path-component prefix (prefix is `/Users/me/Notes` ⇒ `/Users/me/Notes/x.md` matches, `/Users/me/Notes2` does NOT — component-boundary match, never a bare string prefix). Symlinks/`..` are resolved (`standardizedFileURL`) **before** matching so `/Users/me/Notes/../etc` cannot sneak past.
  - A **command target** (the tool/Shortcut name, or a shell command's argv[0]) matches iff it matches one of `trustedCommandPatterns` as an `fnmatch`-style glob (`*`/`?`), anchored full-string.
  - A target that is **both** (a shell command writing to a path) must match BOTH a command pattern AND, if it names a path, a path prefix — the stricter rule wins (a whitelisted command pointed at an un-trusted path stays `.confirm`).
- **The whitelist never lowers `.dangerous`** (Decision 1). It is consulted ONLY for an `external`/`.confirm` descriptor.
- Persisted in `AppSettings` (new keys `agentWhitelistPaths`, `agentWhitelistCommands`); included in the Hub AI page's reset semantics like other opt-ins. The model is pure (the *editing* UI is App-target, Decision 8).

### 4. Effective-tier resolution — the concrete `WritePolicyResolving` (the drop-in)

`ai-tool-routing` defines and injects:
```swift
public protocol WritePolicyResolving: Sendable {
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier
}
```
and ships `DescriptorWritePolicy` (identity) as the stand-alone default so its slice tests in isolation. **This slice ships the production conformer** — but it needs the *call's arguments* (the path/command target) to consult the whitelist, which `effectiveTier(for descriptor:)` alone does not carry. Two clean options:

- **Adopted:** extend the resolution at the call site, not the protocol. This slice provides a `BackgroundPolicyResolver` that conforms to `WritePolicyResolving` for the descriptor-only fast path (CONTAINED→`.auto`, `.dangerous`→`.dangerous`, else the descriptor tier), **plus** a richer `effectiveTier(for descriptor:, target:)` overload that the contributor/loop calls when it has the routed call's target string. The protocol method stays satisfied (descriptor-only); the overload adds the whitelist lowering. No routing protocol change — the loop already holds the `RoutedCall` and can pass its target.

```swift
public struct BackgroundPolicyResolver: WritePolicyResolving, Sendable {
    public let whitelist: Whitelist
    // Protocol requirement (descriptor-only): used when no target is available.
    public func effectiveTier(for d: ToolDescriptor) -> WritePolicyTier
    // Richer overload: lowers .confirm → .auto when target matches the whitelist; never lowers .dangerous.
    public func effectiveTier(for d: ToolDescriptor, target: PolicyTarget?) -> WritePolicyTier
}

public enum PolicyTarget: Equatable, Sendable {
    case path(String)            // a write destination
    case command(String)         // a tool / shortcut / shell command name
    case both(command: String, path: String)
    case none                    // calendar/contacts: no path/command → never whitelist-lowerable
}
```

Resolution table (pure, the unit-test heart of the slice):

| descriptor.writePolicy | BlastRadius | target matches whitelist | → effective tier |
|---|---|---|---|
| `.auto` | contained | (n/a) | `.auto` |
| `.dangerous` | dangerous | (ignored) | **`.dangerous`** |
| `.confirm` | external | yes | **`.auto`** |
| `.confirm` | external | no / `.none` | `.confirm` |

The contributor extracts the `PolicyTarget` from the routed call (a `save_to_project` has no user-path target → it is CONTAINED anyway; an `open_tool`/`send_to` exposes its tool/command; a future delete/move exposes its path). The extraction lives next to the descriptor that owns the args shape; this slice supplies the resolver + the matching, not the per-tool arg parsing.

### 5. The audit log — append-only, redacted, capped, persisted

```swift
public struct AuditRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: AgentSessionID    // attribution (3.1)
    public let tool: String                 // the descriptor name
    public let policy: WritePolicyTier       // the EFFECTIVE tier this step ran at
    public let argumentsSummary: String      // redacted/short — NEVER raw secrets or full bodies
    public let outcome: ToolStepStatus       // reuses 3.3 (.done/.declined/.failed(headline)…)
    public let wasBackground: Bool           // true if applied while parked
    public let timestamp: Date
}

public protocol AuditLog: Sendable {
    func record(_ r: AuditRecord)
    func recent(limit: Int) -> [AuditRecord]
}
```

- **Every tool step writes one record** — auto, confirmed, declined, escalated, or failed — so the ledger is a complete "what did my agents do." A `.declined`/skipped step is recorded too (it is part of the story). An *escalated* step records `outcome = .awaitingApproval` at escalation time and a follow-up record on resolution (approve→`.done`/`.failed`, skip→`.declined`).
- **`argumentsSummary` redaction (pure, unit-tested):** a short, bounded, single-line summary built from the routed args — the path's last component(s), the command name (never the full shell line with embedded secrets), a truncated content preview (`.lineLimit`-style cap, `…` middle-truncation). The blueprint's "redacted/short, NOT raw secrets" — raw args go nowhere near the record. (Full raw args, if ever needed for debugging, live only in the os.Logger breadcrumb at the sink boundary, exactly as `TaskSinks` already logs.)
- **Outcome carries a clean headline only.** A `.failed(headline)` stores `AIPresentedError.headline` — never raw OS text. The audit viewer shows the headline; raw text (if any) stays behind the existing "Show details" disclosure pattern.
- **Append-only + capped:** `DiskAuditLog` appends to a JSON-lines file under Application Support (mirroring `ClipboardStore`/`ParkedSessionStore` on-disk patterns), retaining the most recent N (e.g. 500) with oldest-trimmed-on-write. `record(_:)` is non-blocking — it enqueues to a serialized off-main writer (the Files-band sync-model + async-cache pattern: a pure in-memory ring the viewers read synchronously, disk IO bridged off-main). A write failure maps to `AuditError` at the boundary and is itself surfaced bounded (a one-line "couldn't persist the audit log" banner on the Hub viewer) — it NEVER throws into the route loop (auditing must not break the agent), and the in-memory ring still has the record.
- **Two readers, one log:** the notch rail drop-down shows the recent slice for a parked session (or all sessions); the Hub AI page shows the full recent ledger. Both call `recent(limit:)`. `wasBackground` lets the UI distinguish "while you were away" from foreground actions.

### 6. The gating decision — `BackgroundGate` (pure, the auto-vs-escalate brain)

```swift
public enum BackgroundDecision: Equatable, Sendable {
    case auto              // run now, in the background, then audit
    case waitParked        // .confirm while parked: stay parked, resolve on restore (no escalation)
    case escalate(reason: String)  // .dangerous while parked: → ParkScheduler.escalate → .needsYou + glow
    case foreground        // session is active: the existing ApprovalGate handles it (this slice no-ops)
}

public enum BackgroundGate {
    static func decide(effectiveTier: WritePolicyTier, parkState: ParkState) -> BackgroundDecision
}
```

Decision table (pure; `ParkState` from `ai-parked-sessions`):

| effectiveTier | parkState | → BackgroundDecision |
|---|---|---|
| `.auto` | `.parked` / `.idle` | `.auto` (run + audit) |
| `.auto` | `.active` | `.auto` (foreground auto still runs + audits) |
| `.confirm` | `.parked` / `.idle` | `.waitParked` (resolved on restore via the routing approval gate) |
| `.confirm` | `.active` | `.foreground` (the canvas approval gate owns it) |
| `.dangerous` | `.parked` / `.idle` | `.escalate(reason)` (→ `.needsYou`) |
| `.dangerous` | `.active` | `.foreground` (already in front; the approval gate owns it, no glow needed) |
| any | `.needsYou` | `.waitParked` (already escalated; do not double-escalate) |

The **wiring** (App/integration, the routing loop's contributor host): for each routed call, compute `effectiveTier` (Decision 4), call `BackgroundGate.decide(...)`, then:
- `.auto` → run the step, write an `AuditRecord(wasBackground: parked, policy: .auto)`.
- `.escalate(reason)` → call `scheduler.escalate(sessionID, reason:)` (the `ai-parked-sessions` seam → `.needsYou` + badge + glow), write an `AuditRecord(outcome: .awaitingApproval, wasBackground: true)`, and **suspend** the step (it resumes when the user pulls the session back and approves, exactly the routing `ApprovalGate` flow — the step is now foreground).
- `.waitParked` → leave the step paused on the routing `ApprovalGate`; no escalation, no glow (a `.confirm` is not urgent).
- `.foreground` → no-op for this slice; the routing approval gate + canvas drive it as today.

`reason` for escalation is a clean one-liner (`"<tool> needs your approval (\(blast))"`) — short, headline-grade, routed through `AIError.message(for:)` if it ever wraps an error. The glow itself is `ai-parked-sessions`'.

### 7. Errors — one `AuditError`, mapped at the boundary, bounded + non-blocking

`enum AuditError: Error, Equatable, LocalizedError` carries ONLY what `RuntimeError`/`TaskError`/`ParkError` cannot: the **audit store** persistence failure (`.persistFailed`, `.storeUnavailable`). `FileManager`/JSON errors map into `AuditError` at the `DiskAuditLog` boundary so Core stays MLX-free and no OS error text leaks. It routes through `AIError.message(for:)` → `AIPresentedError` for a clean headline. A store failure surfaces as a **bounded, non-blocking** banner on the Hub audit viewer (headline only; raw text behind "Show details"), **never** `NSAlert.runModal`, and crucially **never throws into the route loop** — `AuditLog.record(_:)` is infallible from the caller's view (it enqueues; a persistence failure is observed on the viewer, the in-memory ring is unaffected). The whitelist matching and the gate are pure value logic and cannot fail.

No other taxonomy is introduced: policy resolution produces a `WritePolicyTier` (never an error); a denied side effect is already a `TaskError`→`.failed` recorded as the audit outcome.

## Type & file touch list (all Core, MLX-free, verified by `swift test` unless noted)

| File (new unless noted) | Target | Contents | Verification |
|---|---|---|---|
| `AI/Audit/BlastRadius.swift` | Core | `BlastRadius` enum + the pure descriptor→radius classifier; the CONTAINED name-prefix set | `swift test` (every mapped tool → expected radius; `.dangerous` is unconditional) |
| `AI/Audit/Whitelist.swift` | Core | `Whitelist` (Codable) + pure path-prefix (component-boundary, standardized) and command-glob (`fnmatch`) matching + the both-rule | `swift test` (prefix component boundary; `..`/symlink resolved before match; glob anchored; both-rule) |
| `AI/Audit/WritePolicyResolution.swift` | Core | `BackgroundPolicyResolver: WritePolicyResolving` (descriptor-only) + the `effectiveTier(for:target:)` overload + `PolicyTarget` | `swift test` (full resolution table; `.dangerous` never lowered; `.confirm`+match→`.auto`) |
| `AI/Audit/BackgroundGate.swift` | Core | `BackgroundDecision` + pure `BackgroundGate.decide(effectiveTier:parkState:)` | `swift test` (full decision table; `.needsYou` never double-escalates) |
| `AI/Audit/AuditRecord.swift` | Core | `AuditRecord` (Codable/Identifiable) + the pure `argumentsSummary` redaction builder | `swift test` (Codable round-trip; redaction truncates + strips raw secrets; headline-only failed outcome) |
| `AI/Audit/AuditLog.swift` | Core (IO bridged off-main) | `AuditLog` protocol + in-memory ring `InMemoryAuditLog` + persisted append-only `DiskAuditLog` (cap/trim, off-main writer) | `swift test` (in-memory: append/recent/cap; `DiskAuditLog` via temp dir: round-trip, trim, `AuditError` mapping) |
| `AI/Audit/AuditError.swift` | Core | `AuditError` (`LocalizedError`) + `AIError.message(for:)` routing case | `swift test` (each case → clean headline; no raw OS text) |
| `App/AppSettings.swift` (modify) | Core | persisted `agentWhitelistPaths` / `agentWhitelistCommands` keys + defaults + reset inclusion | `swift test` (default empty; persistence; reset preserves like other opt-ins) |
| `Hub/HubAIPage.swift` (modify) or `Hub/HubBackgroundAutonomySection.swift` | App | the whitelist editor (add/remove paths via `NSOpenPanel` folder pick; add/remove command patterns) + the audit log viewer (recent list, "while you were away") | `xcodebuild` compile-verify; **user run-verifies** the editor + viewer |
| `AppCoordinator`/route-loop host wiring (modify) | App | inject `BackgroundPolicyResolver` (replacing `DescriptorWritePolicy`), compute `PolicyTarget`, call `BackgroundGate.decide`, wire `escalate` + `AuditLog.record` around `registry.run` | `xcodebuild` compile-verify; **user run-verifies** the parked auto/escalate behavior |
| `Tests/.../BackgroundAutonomyTests.swift` etc. | Core (test) | resolution table, whitelist matching, gate table, redaction, audit ring/disk | `swift test` |

No file in this slice links MLX. The resolver/whitelist/gate/audit are pure value types + protocols; tests drive them directly with fabricated `ToolDescriptor`s and `RoutedCall`s. **No `.app` build, no signing, no permission change** — the slice never touches the build/sign path. To compile-check in isolation without sibling slices' uncommitted files, use a throwaway `git worktree` + `swift build`.

## Edge cases

- **Empty whitelist (default):** every `external`/`.confirm` step stays `.confirm`; only CONTAINED tools are auto. A fresh install runs nothing dangerous in the background and confirms every external write — the safe default. The user opts into autonomy by adding entries.
- **Whitelisted path vs `.dangerous` delete inside it:** a delete/overwrite tool ships `.dangerous`; the whitelist match is **ignored** (Decision 1) — it still escalates. A trusted folder never makes destruction auto.
- **`..` / symlink escape in a path target:** standardized (`standardizedFileURL`/`resolvingSymlinksInPath`) BEFORE the prefix match, so `/trusted/../etc/passwd` does NOT match `/trusted`. Unit-tested.
- **Shell command writing to an un-trusted path:** the both-rule requires command-pattern AND path-prefix; a whitelisted command (`git`) aimed at an off-list path stays `.confirm`/escalates.
- **A `.auto` descriptor that is NOT in the CONTAINED set:** defensive — treated as `.external` for radius (so an accidental `.auto` on a non-contained tool is not silently trusted); a debug assertion flags the misconfiguration. The CONTAINED set is the authority.
- **Audit store write fails while parked:** the in-memory ring still records the step; the disk write failure surfaces as a bounded banner on the Hub viewer (next reveal), never throws into the loop, never loses the running step. Auditing failing must not stop the agent.
- **Session goes from parked → active mid-step (user pulls it back during an `.auto` background run):** the `.auto` step keeps running (it was already safe); `wasBackground` is set from the state **at decision time**, so the record honestly says it started in the background.
- **`.needsYou` already set, another dangerous step queues:** `BackgroundGate` returns `.waitParked` (no double-escalate); the badge count increments via the rail's own `badgeCount` (owned by `ai-parked-sessions`), the glow stays lit. The audit log still records each `.awaitingApproval`.
- **Escalation reason references an error:** routed through `AIError.message(for:)` so the `needsYou` reason is always a clean headline, never raw text.
- **Per-skill `.auto` Claude handoff:** `launch_claude` ships `.confirm`; a skill opting `.auto` makes its descriptor `.auto` (owned by `ai-claude-handoff`), which this slice then treats as CONTAINED-style auto for the gate **but still audits** and is budget-capped (the cap is the handoff slice's). The whitelist does not gate the handoff (no path); the skill opt-in is the trust mechanism there.

## Rejected alternatives

1. **Defining `WritePolicyTier` here.** Rejected per integration fix **C1**: the bare enum lives with `ToolDescriptor` in `ai-tool-routing` (the earlier wave) so every descriptor is self-describing with no DAG back-edge. This slice owns resolution/whitelist/audit/escalation only.
2. **Extending the `WritePolicyResolving` protocol to take a target.** Rejected: it would force a routing-slice API change for a Wave-4 need. Instead this slice satisfies the descriptor-only protocol AND adds a richer overload the loop calls when it has the `RoutedCall` — zero routing change.
3. **A fourth `WritePolicyTier` case for WHITELISTED.** Rejected: WHITELISTED is not a *descriptor* property, it is a *resolution outcome* (a `.confirm` lowered to `.auto` by a match). Adding a case would leak resolution state into the descriptor and every consumer's switch. The blast-radius model is a *view*, the tier stays three cases.
4. **The whitelist lowering `.dangerous`.** Rejected as a security hole: a trusted folder does not make `rm`/overwrite safe. The whitelist only lowers `.confirm` → `.auto`; danger is intrinsic to the operation.
5. **Auditing only background actions.** Rejected: the ledger is "what did my agents do" — foreground auto-runs and skips are part of the story. Every step writes one record; `wasBackground` distinguishes them.
6. **A throwing `AuditLog.record`.** Rejected: auditing must never break the agent. `record` enqueues to an in-memory ring + off-main writer; a persistence failure is observed bounded on the viewer, the step is unaffected.
7. **A separate `BackgroundError` for escalation.** Rejected: escalation produces an observable `.needsYou` + a clean reason string, never an error; the only failure this slice can have is the store write, carried by `AuditError`. Honors "at most one `<Slice>Error`."
8. **Rendering the needs-you badge/glow here.** Rejected: `ai-parked-sessions` owns the rail/badge/glow; this slice calls `escalate` and renders nothing. One owner per surface.

## Target split & verification (per component)

| Component | Target | Verified by |
|---|---|---|
| `BlastRadius` + classifier | Core | `swift test` (tool→radius map; `.dangerous` unconditional; CONTAINED set) |
| `Whitelist` + matching | Core | `swift test` (component-boundary prefix; standardized `..`; glob; both-rule) |
| `BackgroundPolicyResolver` (`WritePolicyResolving`) | Core | `swift test` (full resolution table; `.dangerous` never lowered) |
| `BackgroundGate.decide` | Core | `swift test` (full decision table; `.needsYou` no double-escalate) |
| `AuditRecord` + redaction | Core | `swift test` (Codable; redaction truncates/strips; headline-only failed) |
| `AuditLog` (in-memory + disk) | Core (IO off-main) | `swift test` (ring cap/recent; disk round-trip/trim/`AuditError`) |
| `AuditError` + `AIError` routing | Core | `swift test` (each case → clean headline) |
| `AppSettings` whitelist keys | Core | `swift test` (defaults/persistence/reset) |
| Hub Background-autonomy section (editor + viewer) | App | `xcodebuild` compile-verify; **user run-verifies** |
| Route-loop host wiring (resolver/gate/escalate/record) | App | `xcodebuild` compile-verify; **user run-verifies** parked auto/escalate |

Per the house rule, an agent **never** builds/signs/installs the `.app` (ad-hoc signing breaks TCC). Pure Core is `swift build`/`swift test`; the App-target wiring + Hub views are `xcodebuild` compile-verify only; behavior (a parked agent auto-running a whitelisted write, a dangerous step lighting the glow, the audit viewer) is the user's run-verify in a stable-signed build.

## Open Questions

- **Q1 (target extraction ownership):** the `PolicyTarget` for a routed call must be derived from the call's args. I propose the resolver supplies the matching and the gate, while the per-tool arg→target extraction lives next to each `ToolContributor` (it owns the args shape). Confirm `ai-tool-routing` is happy to pass the extracted `PolicyTarget` into `effectiveTier(for:target:)` at the call site (no protocol change, an additive overload).
- **Q2 (audit retention cap):** 500 recent records is a guess for the "while you were away" ledger. Confirm a count or a time window (e.g. last 7 days) — a small, tunable policy.
- **Q3 (whitelist command-pattern surface):** I scope command patterns to the tool/Shortcut name and a shell command's `argv[0]` (anchored glob). A full shell-command-line pattern is rejected as too sharp an edge to get right safely. Confirm `argv[0]`-only is the right grain for v1.
- **Q4 (escalation-resolution audit follow-up):** an escalated step writes `.awaitingApproval` then a follow-up record on resolution. Confirm two records is preferred over mutating one (append-only argues for two; a viewer collapses them by `id`-lineage). I default to two append-only records.
