## Context

This slice is the **escalation valve**: when the small local agent (Gemma 4, batched, via MLX) judges a task beyond it, it reaches for real Claude Code. Read these before the design:

- **`Launcher/ClaudeLaunch.swift`** — the open-claude-here launch path this slice REUSES wholesale. `ClaudeLauncher.commandScript(folder:command:claudePath:)` builds a self-deleting `.command` script that `cd`s into a folder and `exec`s an interactive **login** shell (so PATH from nvm/fnm/homebrew applies); `writeCommandFile(...)` writes it executable to a temp file; `resolveClaudePath()` finds the `claude` binary (login shell + known-install backstop). The handoff opens via `NSWorkspace.shared.open(url)` — **no Apple Events, no new permission**. `ClaudeLaunchError` is the existing clean `LocalizedError` taxonomy (`claudeNotFound`/`terminalOpenFailed`/`scriptWriteFailed`) with opt-in `copyableDetails`.
- **`Launcher/LaunchService.swift` → `launchClaude(folder:command:claudePath:title:)`** — the fire-and-forget production flow: resolution + write **off the main thread**, the `NSWorkspace` open + any failure notification on the main actor, **success needs no notification** (the terminal window is its own feedback), failure is bounded + non-blocking (never an alert). This is the exact shape the v1 handoff wants.
- **`openspec/specs/open-claude-here/spec.md`** — the capability spec: folder-bound launch, configurable command, no-new-permission handoff, robust `claude` resolution, bounded failure surfacing. The handoff tool is "open-claude-here, but the *model* fires it, the *folder+prompt* come from the conversation, and a *cost gate* sits in front."
- **`openspec/changes/ai-tool-routing/design.md`** — OWNS `ToolDescriptor`/`ToolRoute`/`ToolStepResult`/`ToolStepStatus`/`WritePolicyTier`/`ToolContributor`/`ToolRegistry`/`ApprovalGate`/`WritePolicyResolving`. This slice registers ONE more `ToolContributor`; the route→execute→continue loop is **untouched** (the tool-routing design explicitly notes "`launch_claude` arrives as one more `ToolContributor` with no loop change").
- **`openspec/changes/ai-skills-as-files/design.md`** — `SkillManifest` carries an optional `claudeHandoff: ClaudeHandoffConfig?` block parsed from the skill file's front-matter; skills-as-files OWNS the carrier (the file format + manifest field) and CONSUMES the type, which THIS slice OWNS.

The shared blueprint (`docs/ai-agent-v2-blueprint.md` §3.8) pins `ClaudeHandoffConfig`/`HandoffConfirmMode`; this slice OWNS those types.

**Dependency note (honest):** `ai-background-autonomy` (which OWNS `AuditRecord`/`AuditLog`/`WritePolicyResolving`-as-whitelist-resolver/`ParkScheduler.escalate`) is NOT yet on disk (it is Wave 4, the same wave as this slice). `ai-tool-routing` already defines the bare `WritePolicyTier` enum WITH `ToolDescriptor` (integration fix C1) and a stand-alone `WritePolicyResolving`/`DescriptorWritePolicy` default, so this slice compiles + `swift test`-passes against those today and binds to autonomy's whitelist resolver + audit log when they land. Where a consumed autonomy type is not yet committed, this design declares a narrow Core seam this slice owns (`HandoffAuditing`, `HandoffEscalating`) with a no-op default, re-pointed at the real `AuditLog`/`ParkScheduler` when autonomy lands. See Open Questions.

## Goals / Non-Goals

**Goals:**
- A **model-callable `launch_claude` tool** the router can pick like any capability — `ToolDescriptor{name: "launch_claude", argsSchema: {folder, prompt}, writePolicy: .dangerous}` — that opens Claude Code in the right folder with a starting prompt, reusing the open-claude-here `.command` handoff (NO new launch mechanism, NO new permission).
- **Cost gating per skill:** `confirmMode` defaults to **`confirm`** (per call, money); a skill opts into **`auto`** explicitly in its `claudeHandoff:` block. The effective gate is `auto` ONLY when the skill says so AND the budget allows.
- A **budget/rate cap** (`maxCallsPerDay`, `maxConcurrent`) over an append-only spend ledger, `now:`-injected (deterministic), so an autonomous loop physically cannot rack up real spend. **Every** handoff (auto or confirmed) is audited.
- **DANGEROUS-tier behavior:** foreground unless the skill is `auto` AND under budget; a `confirm`/over-budget call escalates to the foreground approval step (active session) or the **needs-you** badge (parked session) — never runs silently.
- **V1 fire-and-forget:** open Claude, return `.done`, the local agent continues. The **round-trip** (consume Claude's output, resume the conversation) is documented as a future with a `HandoffOutcome` seam left.
- Entire slice MLX-free Core, verified by `swift test` with a fake `HandoffLauncher` + scripted `ApprovalGate` + fake `HandoffAuditing`.

**Non-Goals:**
- The route→execute→continue loop, `ToolRegistry` aggregation, the `ApprovalGate` itself — OWNED by `ai-tool-routing`; this slice registers a contributor and reads the gate.
- The skill-file format + parsing of the `claudeHandoff:` block — OWNED by `ai-skills-as-files`; this slice OWNS only the `ClaudeHandoffConfig` type it parses into and the manifest field's semantics.
- The user whitelist, the append-only `AuditLog` storage, and `ParkState.needsYou` escalation plumbing — OWNED by `ai-background-autonomy`; consumed here via narrow seams.
- Capturing / parsing Claude Code's output, and resuming the local conversation from it (the **round-trip** — explicitly a documented future; the seam is left, the behavior is not built).
- Choosing the Claude model, passing arbitrary Claude CLI flags, or any non-Claude escalation backend.
- A full Hub UI for the global budget (the persisted `claudeHandoffBudgetPerDay` key is defined; surfacing it is a small follow-up, noted not built).

## Decisions

### 1. Type contracts (blueprint §3.8, OWNED here)

```swift
public enum HandoffConfirmMode: String, Codable, Equatable, Sendable {
    case confirm   // DEFAULT — foreground approval per call (money is on the line)
    case auto      // per-skill opt-in: runs without per-call approval, STILL budget-capped + audited
}

public struct ClaudeHandoffConfig: Codable, Equatable, Sendable {
    public var enabled: Bool                       // a skill may carry handoff but keep it off
    public var confirmMode: HandoffConfirmMode      // defaults to .confirm
    public var maxCallsPerDay: Int                  // per-skill rate cap (0 = use the global default)
    public var maxConcurrent: Int                   // at-most-N in-flight (v1: in-flight = "opened, not yet reaped"; see §6)
    public var defaultWorkingDirectory: URL?        // fallback folder when the route omits one

    public static let `default` = ClaudeHandoffConfig(
        enabled: true, confirmMode: .confirm, maxCallsPerDay: 0, maxConcurrent: 1,
        defaultWorkingDirectory: nil)
}
```

- `confirmMode` defaults to **`.confirm`** — the cost decision. A skill file opts into `auto` only by writing `confirmMode: auto` (or a `claudeHandoff: { auto: true }` shorthand) in its front-matter; `ai-skills-as-files` parses it into this struct, so the default-confirm rule holds for any skill that omits the block.
- `maxCallsPerDay == 0` means "fall back to the **global** persisted default" (`claudeHandoffBudgetPerDay`, a camelCase agent-scoped settings key per the naming convention). A skill may pin a tighter per-skill cap.
- This struct is the SAME type carried on `SkillManifest.claudeHandoff` (§ ai-skills-as-files); skills-as-files owns the carrier, this slice owns the type. There is exactly one definition.

### 2. `launch_claude` is a `ToolDescriptor` (writePolicy `.dangerous`)

```swift
// argsSchema (a StructuredSchema, the same shape ai-command-tasks uses for ParsedActions):
{
  "type": "object",
  "required": ["prompt"],
  "properties": {
    "folder":  { "type": "string", "description": "absolute path to open Claude in; omit to use the skill's default working directory" },
    "prompt":  { "type": "string", "description": "the starting prompt Claude opens with" }
  }
}
```

`ClaudeHandoffContributor.descriptors()` returns a single `ToolDescriptor{name: "launch_claude", summary: "Hand the task to Claude Code in a folder with a starting prompt — use when the task exceeds the local model.", argsSchema: aboveSchema, writePolicy: .dangerous, keywords: ["claude","handoff","escalate","code","refactor","big task"]}`. `writePolicy` is **always `.dangerous`** on the descriptor — the `auto` opt-in is a *per-skill effective-tier downgrade* (Decision 4), NOT a descriptor change, so the registry/router never sees a non-dangerous handoff descriptor and a skill cannot accidentally publish a globally-auto handoff. A skill that wants the handoff also lists `launch_claude` in its `tools:` allow-list (§ ai-tool-routing candidate inclusion).

### 3. The contributor — `run` reuses the open-claude-here launch path

```swift
public protocol HandoffLauncher: Sendable {            // the side-effecting spawn seam (headless-fakeable)
    // Fire-and-forget: write the .command + NSWorkspace.open; throws a mapped failure if it can't.
    func launch(folder: URL, prompt: String) async throws
}

public struct ClaudeHandoffContributor: ToolContributor {
    let config: ClaudeHandoffConfig            // the active skill's config (or .default for a free handoff)
    let budget: HandoffBudget                  // pure rate/budget gate (Decision 5)
    let launcher: HandoffLauncher              // production = OpenClaudeHandoffLauncher (Decision 7)
    let audit: HandoffAuditing                 // → ai-background-autonomy AuditLog (Decision 6)
    let resolver: WritePolicyResolving         // effective-tier resolution (Decision 4)
    let escalation: HandoffEscalating          // parked → needs-you (Decision 8)

    public func descriptors() -> [ToolDescriptor]      // [launch_claude]
    public func canHandle(_ tool: String) -> Bool      // tool == "launch_claude"
    public func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult
}
```

`run` is the heart (Decision 4's state machine). The production `HandoffLauncher` (`OpenClaudeHandoffLauncher`) is a thin adapter over the existing `ClaudeLauncher`: it builds the inner command as **`claude <shell-quoted prompt>`** (the starting prompt is passed as Claude's argument, exactly how a custom `command` is passed through `ClaudeLauncher.commandScript`'s inner-command slot — so a non-empty prompt runs `claude "<prompt>"`, an empty prompt opens a bare `claude` session), resolves the path via `resolveClaudePath()`, writes the `.command` via `writeCommandFile`, and opens it with `NSWorkspace.shared.open(url)` — **byte-for-byte the open-claude-here handoff**, off-main, success-needs-no-notification. No new launch mechanism, no new permission.

### 4. Effective-tier resolution — the cost gate (the heart of the slice)

`launch_claude`'s descriptor is always `.dangerous`. The **effective** gate for a given call is resolved at `run` time:

```
effectiveGate(config, budget, now) -> HandoffGate
  if !config.enabled                          -> .disabled            // .declined("Claude handoff is off for this skill")
  if !budget.allows(now)                      -> .overBudget          // degrade per below
  switch config.confirmMode:
    .auto    -> .autoRun        // run now, no per-call approval (still audited)
    .confirm -> .needsApproval  // foreground DOWN=approve / RIGHT=skip
```

The mapping of `effectiveGate` → behavior in `run`:
- **`.autoRun`** (skill opted `auto` AND under budget): record the spend, emit an `AuditRecord(wasBackground: session-parked)`, `launcher.launch(folder, prompt)`, return `ToolStepResult(.done, "Opened Claude Code in <folder>.")`. If `launch` throws → `.failed(headline)` (never a false "Done") AND the spend is **refunded** to the ledger (a launch that didn't land didn't spend).
- **`.needsApproval`** (default-confirm, OR an `auto` skill the user chose to keep confirming): emit `ToolStepResult(.awaitingApproval, "Hand this to Claude Code in <folder>?")` and surface the call as observable approval state; await the `ApprovalGate`:
  - **approve (DOWN)** → record + audit + `launch` → `.done` (or `.failed` + refund).
  - **skip (RIGHT)** → `ToolStepResult(.declined(reason: "skipped"))`, audited as declined, **no spend**.
  - **cancel** (whole canvas discarded) → ends the loop quietly (`RuntimeError.cancelled` semantics), no spend, no launch.
- **`.overBudget`**: this is the runaway-spend guard. An **`auto` skill over budget DEGRADES to `.needsApproval`** (a foreground confirm) rather than running unprompted OR silently dropping — the user can still choose to approve the one extra call; an autonomous loop cannot self-approve. A **`confirm` skill over budget** is already foreground; it shows the budget state in the approval card so the user knows they are over the daily cap. Either way the call is **never silently dropped** — over-budget without a user present (a parked session) escalates to needs-you (Decision 8).
- **`.disabled`**: `ToolStepResult(.declined(reason))` with a clean headline; no spend, no launch.

`resolver` (`WritePolicyResolving`, owned by `ai-tool-routing` / refined by `ai-background-autonomy`) intersects the descriptor's `.dangerous` with the user whitelist FIRST — a user who has not whitelisted handoff keeps it `.dangerous` → always `.needsApproval`/needs-you regardless of the skill's `auto`. The skill `auto` can only *downgrade within* what the whitelist permits; it can never *override* a user who declined to trust handoff. This is the autonomy contract: **effective tier = descriptor default ∩ user whitelist**, then the per-skill `confirmMode` chooses within the permitted range.

### 5. The budget/rate cap — pure, `now:`-injected, refundable

```swift
public struct HandoffSpend: Codable, Equatable, Sendable { public let at: Date; public let skillID: String? }

public struct HandoffBudget: Equatable, Sendable {
    public let maxCallsPerDay: Int                     // resolved (skill cap or global default)
    public let maxConcurrent: Int
    public private(set) var ledger: [HandoffSpend]     // append-only spend records; in-flight tracked separately
    public private(set) var inFlight: Int

    // Pure predicate — `now` is an INPUT (deterministic, DockHoverModel-style).
    public func allows(now: Date) -> Bool {
        callsInLast24h(now) < maxCallsPerDay && inFlight < maxConcurrent
    }
    public mutating func record(at: Date, skillID: String?)   // spend a call (append + inFlight += 1)
    public mutating func reap()                               // a fire-and-forget launch is "done" → inFlight -= 1 (v1: immediately after open, see §6)
    public mutating func refund(at: Date)                     // a launch that threw didn't spend → remove + inFlight -= 1
    func callsInLast24h(_ now: Date) -> Bool                  // rolling window, deterministic
}
```

- The **rolling-24h** call count (`maxCallsPerDay`) is a sliding window over `now`, not a calendar-day reset — so a loop cannot dump N calls at 23:59 and N more at 00:01. `now:` is injected so the window is unit-testable without a clock.
- The ledger is **append-only** and persisted (mirroring the audit log's durability) so the cap survives a relaunch within the window — a process restart cannot reset the daily budget. (v1 persists the ledger alongside settings under Application Support, like `ClipboardStore`.)
- `maxConcurrent` bounds simultaneous in-flight handoffs (v1 default 1). Because v1 is fire-and-forget with no reaping signal from Claude, **`reap()` runs immediately after a successful `open`** — concurrency is effectively "don't fire two handoffs from the same loop step." The seam is left so the future round-trip reaps on *Claude exit* instead (Decision 9). This is an explicit v1 simplification, documented, not a bug.

### 6. Audit — every handoff is recorded (append-only, consumed from autonomy)

```swift
public protocol HandoffAuditing: Sendable {                 // → ai-background-autonomy AuditLog.record(_:)
    func record(_ record: AuditRecord) async
}
```

Every `run` outcome emits exactly one `AuditRecord{sessionID, tool: "launch_claude", policy: .dangerous, argumentsSummary: "<folder> · <prompt redacted/short>", outcome: ToolStepStatus, wasBackground: session-parked, timestamp}` (blueprint §3.7). `argumentsSummary` is **redacted/short** — the folder path + a truncated prompt, NEVER the full prompt verbatim (a prompt can carry secrets; raw text rides only in logs / opt-in details, never the audit headline). The audit fires for `.done`, `.declined`, `.failed`, AND `.overBudget`-degraded — so the spend ledger and the audit log agree, and a user can see "the agent wanted to escalate 4 times today, 1 ran." Until `ai-background-autonomy` lands, `HandoffAuditing` has a no-op default (`NoopHandoffAudit`) and a recording test double; it re-points at the real `AuditLog` when autonomy commits.

### 7. Production launcher — the open-claude-here adapter (Core, side-effecting)

```swift
public struct OpenClaudeHandoffLauncher: HandoffLauncher {
    public func launch(folder: URL, prompt: String) async throws {
        // Off-main resolution + write, NSWorkspace open on the main actor — the launchClaude() shape.
        let inner = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil                                    // empty prompt → bare claude session
            : "claude \(ClaudeLauncher.shellQuote(prompt))"   // starting prompt as claude's argument
        let claudePath = inner == nil ? ClaudeLauncher.resolveClaudePath() : nil
        let url = try ClaudeLauncher.writeCommandFile(folder: folder, command: inner, claudePath: claudePath)
        // open via NSWorkspace.shared.open(url) on the main actor; throw HandoffError on failure
    }
}
```

This is the ONLY side-effecting code in the slice, and it adds **no new launch primitive** — it composes `ClaudeLauncher`'s existing pure script builder + write + the `.command`/`NSWorkspace` handoff. It lives in Core (the open-claude-here code already does) but its real side effect is exercised by the **user's** stable-signed build; `swift test` drives the contributor against a **fake** `HandoffLauncher` that records `(folder, prompt)` without spawning anything. Failures map at this boundary into `HandoffError` (Decision 10).

### 8. Parked-session escalation — dangerous always escalates, even when parked

Adopting the autonomy rule (do not relitigate): a **dangerous** handoff in a **parked** session does NOT auto-run and does NOT silently wait — it raises `ParkState.needsYou` + a badge via `ParkScheduler.escalate`, so the user is pulled back to approve the spend. This applies to BOTH a `.needsApproval` handoff (default-confirm) AND an `.overBudget`-degraded `auto` handoff that has no foreground user to confirm it. An `.autoRun` handoff (skill `auto`, under budget, in a parked session) DOES run in the background (it is the explicitly-trusted, budget-capped, audited path the user opted into) — mirroring "whitelisted writes are auto even when parked, still audited." The contributor reads whether the session is parked from the `RoutedCall`/context (`wasBackground`) and routes to `escalation.escalate(...)` instead of the synchronous `ApprovalGate` when parked-and-needs-approval.

```swift
public protocol HandoffEscalating: Sendable {              // → ai-parked-sessions ParkScheduler.escalate
    func escalate(_ sessionID: AgentSessionID, reason: String) async
}
```

Until `ai-parked-sessions`/`ai-background-autonomy` land, a no-op default + a recording double; re-pointed at `ParkScheduler.escalate` when they commit. When parked-and-escalated, `run` returns `ToolStepResult(.awaitingApproval, ...)` so the parked-session UI shows the pending handoff behind the needs-you badge; no spend until the user returns and approves.

### 9. V1 fire-and-forget — and the round-trip seam left for the future

V1 contract: `launch` opens Claude with the prompt; the contributor returns `.done` and the loop continues. The local agent does **not** wait for Claude, does **not** read Claude's output. This is deliberate — a synchronous round-trip would block the local loop on a long Claude session and tangle two agent loops. The future round-trip is documented and **seamed**:

```swift
// FUTURE (not built in v1): the launcher returns a handle a later slice can poll/await.
public struct HandoffOutcome: Sendable { public let handle: UUID /* ; future: stdout, exitCode, resultText */ }
// v1 HandoffLauncher.launch returns Void (fire-and-forget). A future variant returns HandoffOutcome,
// reaps inFlight on Claude EXIT (not on open), and feeds resultText back as a .tool AgentMessage so
// the local agent continues from Claude's result. The contributor's run() already appends a .tool
// result; swapping .done for a consumed HandoffOutcome is additive.
```

The v1 `ToolStepResult.summary` ("Opened Claude Code in <folder>.") is what the model sees as the tool result — enough for it to know the handoff happened and to wind down its own loop (it should NOT keep planning around a result it won't get). No round-trip code is written; only the shape is left so the future slice is additive.

### 10. Errors — one taxonomy, mapped at the boundary, observable + bounded

A new `enum HandoffError: Error, Equatable, LocalizedError` ONLY for handoff cases `RuntimeError`/`TaskError`/`ClaudeLaunchError` cannot carry:

```swift
public enum HandoffError: Error, Equatable {
    case disabled                              // the skill carries handoff but enabled == false
    case overBudgetNoUser                      // over budget AND parked with no one to confirm (escalated)
    case missingFolder                         // no folder in the route AND no defaultWorkingDirectory
    case launchFailed(headline: String, details: String?)   // wraps a mapped ClaudeLaunchError
}
```

- Clean `errorDescription` per case; raw OS/vendor text rides ONLY in `details` / logs, never the headline. `AIError.message(for:)` is extended to translate `HandoffError` → `AIPresentedError` (THE one translator) so a handoff failure reads identically in the canvas, the audit, and any settings row.
- The production launcher maps `ClaudeLaunchError` (`claudeNotFound`/`terminalOpenFailed`/`scriptWriteFailed`) into `HandoffError.launchFailed` at the launch boundary — Core stays consistent, the existing clean headline flows through (e.g. "Couldn't find the 'claude' command. Install Claude Code, then try again.").
- A failure becomes a `ToolStepResult(.failed(headline:))` (a side effect that didn't land is `.failed`, never a false "Done") and the spend is refunded. No `NSAlert`; the canvas / parked UI render it bounded + non-blocking with Retry/Dismiss.
- `RuntimeError.cancelled` (a discard during approval) is NOT a failure — the loop ends quietly, no spend, no launch (the autonomy/routing cancel path).

## Type & file touch list (all Core, MLX-free; verified by `swift test` unless noted)

| File (new unless noted) | Target | Contents | Verification |
|---|---|---|---|
| `AI/Handoff/ClaudeHandoffConfig.swift` | Core | `HandoffConfirmMode`, `ClaudeHandoffConfig` (+ `.default`, confirm-default) | `swift test` (Codable round-trip, default == confirm) |
| `AI/Handoff/HandoffBudget.swift` | Core | `HandoffSpend`, `HandoffBudget` (`allows(now:)`, `record`/`reap`/`refund`, rolling-24h) | `swift test` (cap, rolling window, concurrency, refund) |
| `AI/Handoff/HandoffLauncher.swift` | Core | `HandoffLauncher` protocol + `OpenClaudeHandoffLauncher` (the open-claude-here adapter) | `swift test` (protocol + prompt→inner-command mapping); side effect = **user build** |
| `AI/Handoff/ClaudeHandoffContributor.swift` | Core | `ToolContributor` for `launch_claude`; `descriptors()`; the `effectiveGate` resolution; `run` state machine; audit emission; parked escalation | `swift test` w/ fake launcher + scripted gate + recording audit/escalation |
| `AI/Handoff/HandoffSeams.swift` | Core | `HandoffAuditing`/`HandoffEscalating` narrow seams + no-op defaults (re-pointed at `AuditLog`/`ParkScheduler` when autonomy/parked land) | `swift test` |
| `AI/Handoff/HandoffError.swift` | Core | `HandoffError` (`LocalizedError`) + `AIError.message(for:)` extension | `swift test` (clean headline, no raw interpolation) |
| `Tests/.../ClaudeHandoffTests.swift` etc. | Core (test) | fake `HandoffLauncher`, scripted `ApprovalGate`, recording audit/escalation; every `run` branch | `swift test` |

No file in this slice links MLX. The production `OpenClaudeHandoffLauncher` composes the existing `Launcher/ClaudeLaunch.swift` (already Core) — **no change** to that file is required; the contributor only *calls* its pure builders. **No `.app` build, no signing, no permission change — the user's stable-signed build is unaffected;** the real spawn is exercised by the user end-to-end.

## Edge cases

- **Route gives no `folder`:** fall back to `config.defaultWorkingDirectory`; if that is also nil → `ToolStepResult(.failed(HandoffError.missingFolder headline))`, no spend. The model can re-route with a folder.
- **Route gives an empty `prompt`:** allowed — opens a **bare `claude` session** in the folder (the open-claude-here default-command behavior). Audited with an empty-prompt summary.
- **`claude` not found at launch time:** the production launcher's `ClaudeLauncher.resolveClaudePath()` returns nil → the script falls back to PATH-`claude` (existing behavior); if the open itself fails, `ClaudeLaunchError` maps to `HandoffError.launchFailed` → `.failed` + refund. (Unlike open-claude-here's *setup-time* resolution, the handoff resolves at fire time, so a clean failure surfaces in the canvas, never a silent no-op.)
- **`auto` skill, over the daily cap:** degrades to a foreground `.needsApproval` (active session) or needs-you (parked) — never silently dropped, never auto-run over budget. The approval card states "daily Claude limit reached" so the user knows this is the budget speaking.
- **`confirm` skill, over the cap:** already foreground; the approval card shows the over-budget state; approving still spends (the user is the cap override, the loop is not).
- **User has NOT whitelisted handoff:** the resolver keeps the effective tier `.dangerous` → always foreground/needs-you regardless of the skill's `auto`. A skill cannot self-grant background spend.
- **`launch` throws after the spend was recorded:** refund the ledger entry + `inFlight -= 1` and return `.failed` — a handoff that didn't land didn't spend, so the cap stays honest.
- **Whole canvas discarded mid-approval:** gate resolves cancelled → loop ends quietly, no spend, no launch (`RuntimeError.cancelled` is not a failure).
- **Two `launch_claude` steps in one loop:** `maxConcurrent` (default 1) blocks the second within the same step window (it reads `inFlight`); since v1 reaps on open, a *later* step is allowed once the prior opened — bounded by the daily cap. Documented v1 concurrency semantics.
- **Skill carries `claudeHandoff` but `enabled: false`:** `.declined("Claude handoff is off for this skill")` — a skill can ship the config disabled and a user/Hub can flip it on later.
- **`maxCallsPerDay == 0` (use global):** resolves to the persisted `claudeHandoffBudgetPerDay`; if that is also 0 (a user who disabled handoff globally) → treat as disabled → `.declined`.
- **Ledger persisted across relaunch:** a process restart does NOT reset the rolling-24h window — the cap survives, so an agent cannot restart itself to dodge the budget.

## Rejected alternatives

- **`launch_claude` as a `.confirm` (not `.dangerous`) descriptor.** Rejected: money is on the line; the blueprint adopted decision pins handoff as dangerous-tier (foreground unless the skill is auto AND under budget). A `.confirm` default would let the whitelist resolver treat it like a benign write.
- **Per-skill `auto` flips the descriptor's `writePolicy` to `.auto`.** Rejected: that would publish a globally-auto handoff descriptor the router could pick from ANY context, bypassing the cost gate. The descriptor stays `.dangerous`; `auto` is a per-skill *effective-tier downgrade* resolved at `run` time, intersected with the user whitelist.
- **Synchronous round-trip in v1 (await Claude's output, feed it back).** Rejected for v1: it blocks the local loop on a long Claude session and tangles two agent loops; it also needs a way to capture Claude Code's structured output that does not exist in the `.command` handoff. Fire-and-forget is the bounded v1; the round-trip is seamed for a future slice.
- **A calendar-day budget reset (midnight).** Rejected: a loop could dump N calls at 23:59 and N more at 00:01. A rolling-24h window over an injected `now:` is the runaway-spend-safe cap.
- **A new launch mechanism / scripting Terminal.app for the handoff.** Rejected: the open-claude-here `.command` + `NSWorkspace.open` handoff already opens the user's default terminal with NO new permission (no Apple Events). Reuse it byte-for-byte.
- **Silently dropping an over-budget call.** Rejected: a side effect that didn't happen must be observable. Over-budget degrades to a foreground confirm / needs-you and is audited — never a silent no-op, never a false "Done."
- **The full prompt verbatim in the audit record.** Rejected: a prompt can carry secrets. `argumentsSummary` is redacted/short (folder + truncated prompt); raw text rides only in logs / opt-in details.
- **A dedicated `HandoffAuditLog` separate from autonomy's `AuditLog`.** Rejected: one append-only audit log (blueprint §3.7); this slice records INTO it via a narrow seam, it does not fork the log.

## Target-split & verification summary

- **Everything in this slice is MLX-free Core**, verified by `swift build` + `swift test`. The config/budget/error types are pure value types; `effectiveGate`/`HandoffBudget.allows(now:)` are pure functions (`now:`-injected, deterministic); the contributor's `run` is driven by an injected `HandoffLauncher` (fake in tests, recording `(folder, prompt)`), a scripted `ApprovalGate`, and a recording `HandoffAuditing`/`HandoffEscalating`.
- **The production spawn (`OpenClaudeHandoffLauncher`) lives in Core** (it composes the already-Core `ClaudeLauncher`), but its real side effect (writing the `.command`, `NSWorkspace.open`) is exercised by the **user's stable-signed build** end-to-end — an agent never builds/signs/installs the `.app` (ad-hoc signing breaks TCC grants).
- **No `xcodebuild`/`.app`/signing in this slice.** The MLX-linked batched runtime that ultimately answers route turns is owned downstream; this slice is agnostic to which `LLMRuntime` conformer drives the loop. To compile-check in isolation without other in-flight slices' uncommitted files, use a throwaway `git worktree` + `swift build`.

## Open Questions

- **Q1 (autonomy seams):** `ai-background-autonomy` (`AuditRecord`/`AuditLog`/whitelist `WritePolicyResolving`) and `ai-parked-sessions` (`ParkScheduler.escalate`/`AgentSessionID`) are not yet on disk (same Wave 4). I plan narrow `HandoffAuditing`/`HandoffEscalating` seams I own with no-op defaults, re-pointed at the real types when they land. Confirm the blueprint §3.7/§3.5 sketches are final enough to bind, and confirm `AuditRecord`'s `argumentsSummary` redaction contract.
- **Q2 (global budget surfacing):** I define the persisted `claudeHandoffBudgetPerDay` settings key + the ledger persistence, but a Hub UI to view/edit the global budget + the spend ledger ("the agent escalated N times today") is a small follow-up. Confirm whether it ships in this slice or as a Hub-page follow-up alongside the autonomy whitelist UI.
- **Q3 (v1 concurrency reaping):** v1 reaps `inFlight` immediately on `open` (no exit signal from a fire-and-forget `.command`). `maxConcurrent` therefore really means "one handoff per loop step." Confirm that is acceptable for v1, with true on-exit reaping deferred to the round-trip future.
- **Q4 (skill `auto` shorthand):** the skill front-matter block — `claudeHandoff: { auto: true, maxPerDay: 3, dir: "~/proj" }` vs the full `ClaudeHandoffConfig` field names. `ai-skills-as-files` owns the parse; confirm the front-matter spelling so the two slices agree.
