## Context

The V2 agent's whole side-effect machinery is a **token-stream** model: `LLMRuntime` emits `Token`s, the
route loop turns a turn into a `ToolRoute`, and `TaskDispatching`/`TaskSinks` apply a *quick* side effect
(write an event, append a note, send a payload). Generative media does not fit that shape. A diffusion
run is **minutes**, emits **diffusion-step progress** (not language tokens), saturates the GPU (it
**evicts chat** under the 48 GB budget — the fleet's call), and its product is a **file** the user keeps.
Forcing it through `LLMRuntime` would lie about its cost and its output.

The addendum (§B1) therefore pins a SECOND runtime seam, `MediaRuntime`, parallel to `LLMRuntime`. This
slice owns that seam plus its value types, the two tools that invoke it, the sink the route loop runs,
the seed (img2img/img2video) path, and the dual output (Files-band gallery asset + canvas
preview/player). The concrete diffusion backends are deliberately OUT of scope — they conform to the
seam in their own slices (`ai-local-image-generation`, `ai-video-animation-generation`), exactly as Gemma
conforms to `LLMRuntime` and could be swapped. The capability is gated under `mediaGenEnabled`
(itself under `fullPotentialEnabled`); default OFF, V2 ships calm.

Every blueprint/addendum invariant binds: one error taxonomy + the single `AIError.message(for:)`
translator mapped at the boundary, surfaced bounded + non-blocking (never `NSAlert`, never raw error in a
headline); a side effect that did not land is `.failed`, never a false "Saved."; non-activating overlays
with synchronous `orderOut`; the canonical two-finger compass (DOWN=affirm at canvas-top / RIGHT=discard);
reuse-don't-reinvent (`ToolRegistry`, route loop, `WritePolicyTier`, `ParkScheduler`, files band, the
`.screenRegion`/`.clipboardImage` captures, `BubbleMorph`, `DockPreviewOverlay`).

## Goals

- Define the `MediaRuntime` seam + media value types VERBATIM from addendum §B1, in MLX-free Core, with a
  `StubMediaRuntime` that makes the whole slice `swift test`-verifiable without weights.
- Register `generate_image` / `generate_video` as `ToolDescriptor`s in the `ToolRegistry` with their
  write-policy tiers (image `.confirm`; cloud video `.dangerous` + budget cap), and execute a routed
  media call via `MediaGenSink` through the EXISTING route → execute → continue loop — no new control flow.
- Resolve the **seed** (img2img/img2video) from the existing screen-region / clipboard captures, as the
  first frame; surface a missing-but-required seed as a clean `.failed`.
- Deliver the output twice: a **Files-band gallery asset** (reusing the band) and a **canvas
  preview/player** resolved by the compass (DOWN extracts save/paste/set-as; RIGHT discards).
- Park-while-generating via `ParkScheduler` (thinking badge → notch glow on done / needs-you), feeding
  the parked machinery the media job's observable state — without re-implementing it.
- Be HONEST about cost everywhere: a heavy gen evicts chat ("busy painting"); cloud video spends money
  (budget cap + dangerous tier); latency is minutes; failures are bounded `.failed` cards.

## Non-Goals

- **The concrete model backends.** No mflux/FLUX image weights and no LTX Studio / local-LTXV video here.
  Those are `ai-local-image-generation` and `ai-video-animation-generation`, conforming to this seam.
- **Lane/residency/eviction math.** `ai-compute-tiers` (lanes) and `ai-model-fleet` (registry/eviction)
  own it; this slice consumes `ModelRegistry`/`ModelDescriptor` to pick a runtime and to learn that a
  heavy gen evicts chat.
- **The master-toggle UX page** (`ai-full-potential-toggle`). This slice only reads `mediaGenEnabled`.
- **A new gesture grammar, a new overlay species, or a new error translator.** All reused.
- **Round-tripping a cloud video result into a structured agent message** beyond the finished asset —
  cloud video is fire-and-forget-with-progress (the handoff template); the asset is the result.

## Decisions

### D1. `MediaRuntime` is a SECOND seam parallel to `LLMRuntime`, not an `LLMRuntime` method
A generative job is a long async **`AsyncThrowingStream<MediaProgress, Error>`** ending in a `MediaAsset`
file — categorically unlike `LLMRuntime`'s `AsyncThrowingStream<Token, Error>`. Modeling it as the
addendum-pinned standalone protocol keeps each seam honest about its own shape and lets a media backend
be swapped without touching `LLMRuntime` conformers (and vice-versa).
- **Rationale:** the seam carries diffusion-step progress + intermediate previews + a terminal file —
  none of which a token stream expresses. Parallel seams keep the text and media worlds independently
  swappable (the blueprint's reuse-don't-reinvent ethos: one seam per shape).
- **Alternatives rejected:** *(a) add a `generateMedia` method to `LLMRuntime`* — pollutes the text seam
  with a file-producing, minutes-long job and forces every text conformer (`StubLLMRuntime`,
  `DevAIRuntime`, the batched runtime) to carry a media method it can't serve. *(b) Model media as just
  another `TaskKind`/`TaskSink`* — a `TaskSink` is a quick synchronous-ish side effect with a `TaskReview`;
  it has no notion of streamed step-progress, an intermediate preview, eviction of chat, or a minutes-long
  parked job. The media work is a tool (route+approval) WHOSE EXECUTOR is this new seam, not a `TaskSink`.

### D2. Media is a TOOL; the route loop runs `MediaGenSink` — no new control flow
`generate_image`/`generate_video` are `ToolDescriptor`s contributed to the `ToolRegistry` via the
existing `ToolContributor` seam (addendum §B1, blueprint §3.3). When the router selects one, the existing
route → execute → continue loop dispatches to `MediaGenSink` exactly as it dispatches a `TaskKind` to the
task machinery. The model "chose the menu item"; the sink does the long job.
- **Rationale:** the tool-routing slice already owns the loop, the registry, candidate retrieval, the
  bounded step cap, and the per-step write-policy gate. Reusing them means media inherits approval,
  auditing, no-progress guarding, and the compass-driven approval (DOWN=approve / RIGHT=skip) for free.
- **Alternatives rejected:** *a bespoke "media run" control path* — duplicates the loop's approval/audit/
  cap machinery and forks the agent's single execution model. The addendum is explicit: "Media generation
  is a tool … `MediaGenSink` executes via the existing route→execute→continue loop. No new control flow."

### D3. Write-policy: image `.confirm`, cloud video `.dangerous` + budget cap (the handoff template)
The `generate_image` descriptor ships `WritePolicyTier.confirm`; the `generate_video` descriptor ships
`.dangerous` when its provider is cloud, plus a per-day budget/rate cap (`mediaVideoBudgetPerDay`,
mirroring `ClaudeHandoffConfig`). The sink's approval/spend gate sits BEFORE any compute or network spend.
- **Rationale:** image gen is local but expensive (heat, eviction) → confirm-by-default. Cloud video
  spends real money and leaves the device → dangerous, escalates to foreground via needs-you even when
  parked, and is rate-capped, exactly like Claude handoff (addendum §B3/§3.8). Budget is enforced before
  the call so an exhausted budget is a clean `.failed`/`.declined`, never a silent spend.
- **Alternatives rejected:** *(a) image `.auto`* — a minutes-long GPU-saturating job that evicts chat is
  not something to fire without a beat of confirmation. *(b) cloud video `.confirm`* — understates a
  money-spending off-device call; the addendum pins it `.dangerous` + budget-capped. *(c) a separate
  budget mechanism* — reuse the handoff per-day cap pattern + the audit log, don't invent a parallel one.

### D4. Effective tier comes from the injected `WritePolicyResolving` seam (background-autonomy owns it)
The sink/descriptor declare the **shipped** tier (D3); the EFFECTIVE tier per step is resolved by the
`WritePolicyResolving` seam the route loop already injects (default = descriptor tier so this slice stands
alone; `ai-background-autonomy` supplies the real resolver + whitelist + audit). A `.dangerous` cloud-video
tier is NEVER lowered; a `.confirm` image tier may be lowered to `.auto` only by an explicit user
whitelist (background-autonomy's call, not this slice's).
- **Rationale:** one resolution path for all tools; media doesn't fork the security boundary. Every media
  step writes one `AuditRecord` (auto/confirmed/declined/escalated/failed) through the shared `AuditLog`.
- **Alternatives rejected:** *media-local tier resolution* — duplicates and could diverge from the
  whitelist/audit boundary that background-autonomy owns. *Never lowering image* — denies the user the
  documented whitelist affordance; we defer the lowering decision to the resolver, not hard-code it.

### D5. The seed (img2img / img2video) reuses the existing `.screenRegion` / `.clipboardImage` captures
`MediaRequest.seed: Data?` (PNG) is the first frame. The sink resolves it from the EXISTING capture
seams — the interactive screen-region picker (`.screenRegion`) and the live clipboard image
(`.clipboardImage`, on-demand, normalized to PNG) — the same inputs the vision path already uses. A tool
authored as img2img with no resolvable seed is a clean `.failed(MediaError.seedRequired)`, never a
fabricated blank frame.
- **Rationale:** the project already has a tested region picker and clipboard-image normalization; the
  blueprint mandates reuse. The seed *is* one of those captures promoted to a generation input.
- **Alternatives rejected:** *a new media-only image picker* — reinvents the region picker. *Auto-firing
  on a clipboard image* — violates the on-demand rule (copying an image must never auto-fire a gen). *A
  blank fallback frame* — would fabricate a result; a missing required seed is observably `.failed`.

### D6. Output #1 — a Files-band gallery asset (reuse the band, don't build a browser)
The finished `MediaAsset.url` is written under a dedicated **generated-media gallery** root and surfaces
as an ordinary `.fileEntry` in the Files band — inheriting its on-demand listing, lift-to-deliver /
Open / Open-With, contextual delivery, and non-destructive scope. The gallery root is local-only and
recoverable (it sits under the band's local-only, trash-not-delete rules).
- **Rationale:** the addendum is explicit ("Generated assets land as Files-band entries (the gallery).
  Reuse, do not build a new browser"). The band already lists, previews, opens, and delivers files.
- **Alternatives rejected:** *a standalone media gallery UI* — duplicates the band. *A non-file in-memory
  gallery* — loses durability; the asset must survive relaunch and discard (D7). *Writing into an
  arbitrary user folder* — a dedicated gallery root keeps the output bounded and recoverable.

### D7. Output #2 — a canvas preview/player resolved by the compass; the asset is already durable
While generating, the canvas shows live `MediaProgress.step` + the intermediate preview; on
`.finished` it shows the image, or a **player** for video (a `DockPreviewOverlay`-pattern non-activating
panel, synchronous `orderOut`). Resolution is the canonical compass: **DOWN (at canvas-top) extracts** —
**save / paste / set-as** — **RIGHT discards**. Because the asset is ALREADY in the gallery (D6) before
the canvas resolves, a discard never loses the result; it only dismisses the preview.
- **Rationale:** the compass is canonical (DOWN=affirm-at-top, RIGHT=discard); the addendum pins
  "swipe-DOWN extracts (save/paste/set-as)". Persisting to the gallery first makes discard non-destructive
  and matches the parked lifecycle (the result outlives the canvas).
- **Alternatives rejected:** *a continuous screen-recording / live SCStream player* — the switcher/dock
  work already rejected per-frame pumps; a finished clip is played from its file, an in-progress preview
  is the runtime's last `.step` preview frame. *Lift-to-commit* — the canvas grammar is swipe-to-resolve,
  not lift-to-commit (that's the files band's grammar; do not cross them). *Discard deletes the file* —
  the gallery is the durable record; discard is a UI dismiss, the file stays (the user can still find it).

### D8. Parked-while-generating: feed `ParkScheduler`, don't re-implement it
A media job is slow, so the session **parks** (canvas overscroll-park → notch home zone). This slice
FEEDS the existing parked machinery the job's observable state: a **thinking** badge while painting, a
**done** badge (+ unseen count) + notch **glow** on `.finished`, and a **needs-you** escalation + glow for
a `.dangerous` cloud-video step (via `ParkScheduler.escalate`). The scheduler decides scheduling; this
slice only reports `didAdvance` / `escalate`.
- **Rationale:** `ai-parked-sessions` owns the scheduler, rail, badges, and glow; the addendum says media
  "parks via `ParkScheduler`; the notch glows on completion / on needs-you." Reuse, don't reinvent.
- **Alternatives rejected:** *a media-only background queue + progress HUD* — forks the parked lifecycle
  and the notch surface. *Blocking the canvas during a gen* — denies the user other work for minutes; the
  whole point of parking is to let the GPU paint while the user moves on.

### D9. Honest residency — a heavy gen evicts chat ("busy painting"), surfaced not hidden
The sink consults the `ModelRegistry` (`ensureResident` for the image/video runtime). When residency math
(owned by `ai-model-fleet`) decides the gen must EVICT chat, the canvas/rail surface a calm "the assistant
is busy painting" state rather than pretending co-residency; chat resumes when the gen finishes/parks.
- **Rationale:** addendum decision 5 ("A heavy gen EVICTS chat … state it honestly … surface 'the
  assistant is busy painting' rather than pretend co-residency"). The project's surface-the-cost ethos.
- **Alternatives rejected:** *silently queueing chat behind the gen with no signal* — looks like a hang.
  *Refusing the gen to keep chat resident* — denies the capability the hardware can serve; the honest
  answer is to evict + tell the user.

### D10. `MediaError` is the one new taxonomy, mapped at the boundary, one translator
A single `enum MediaError: Error, Equatable` (`LocalizedError`) carries the media-specific cases the
shared `RuntimeError`/`TaskError` cannot: `noCapableBackend(kind)`, `seedRequired`, `seedInvalid`,
`generationFailed(headline)`, `outputWriteFailed`, `cloudBudgetExhausted`, `cloudUnavailable`. Vendor/OS
errors (mflux/LTXV/ComfyUI, `Process`, `NSURLError`, `FileManager`) map into it at the layer boundary
(the sink / backend conformer). Every surface routes through `AIError.message(for:)` → `AIPresentedError`
and is bounded + non-blocking. **Cancellation is NOT a failure** — a discarded/parked-then-discarded gen
ends `.cancelled`, never a `.failed` badge.
- **Rationale:** the blueprint's one-taxonomy / one-translator / map-at-boundary / bounded-non-blocking
  law. A distinct cancellation outcome avoids a false failure badge (mirrors the parked-discard rule).
- **Alternatives rejected:** *raw vendor errors into headlines* — banned. *Reusing `TaskError` for
  everything* — it cannot carry "no capable backend" / "seed required" / "budget exhausted" cleanly; one
  small `MediaError` is the addendum-sanctioned single new enum.

### D11. Unavailable tools are omitted from candidates (the router never routes to dead ends)
The `MediaToolContributor` advertises `generate_image` only if a `MediaRuntime` advertises `.image`, and
`generate_video` only if a video provider is configured AND `fleetCloudEscalationEnabled` (for cloud) AND
budget remains. Under `mediaGenEnabled == false` (or `fullPotentialEnabled == false`), the contributor
contributes nothing. So the router's candidate set never includes a tool that cannot run.
- **Rationale:** routing to an unavailable tool wastes a loop step and produces a confusing decline. The
  capability is gated; gating at the contributor keeps the loop unaware of media's availability rules.
- **Alternatives rejected:** *always advertise, fail at execute* — burns a step + emits a `.failed` the
  user reads as a bug; better to never offer what can't run.

## Target-split & verification (per component)

| Component | Target | Verification |
|---|---|---|
| `MediaKind` / `MediaSize` / `MediaParameters` / `MediaRequest` / `MediaProgress` / `MediaAsset` value types (addendum §B1) | MLX-free Core | `swift test` — Codable round-trip, `MediaAsset` ↔ `.fileEntry` mapping, seed-present/absent shapes |
| `MediaRuntime` protocol (the seam, §B1) | MLX-free Core | `swift build` (protocol compiles); driven in tests via the stub |
| `StubMediaRuntime` (scripted progress: success, intermediate previews, mid-flight fail, cancel, missing-seed, budget-out) | MLX-free Core (test support) | `swift test` — drives the sink deterministically without weights |
| `MediaToolContributor` (the two `ToolDescriptor`s + `argsSchema` + `WritePolicyTier` + availability gating) | MLX-free Core | `swift test` — descriptors present/omitted by capability/availability; tiers correct (image `.confirm`, cloud video `.dangerous`); args schema validates |
| `MediaGenSink` (route-loop executor: resolve seed → pick runtime → drive `generate` → write asset → `ToolStepResult`) | MLX-free Core | `swift test` — `.done` carries gallery path; `.failed` clean headline on each error; `.awaitingApproval` before compute; cancellation ≠ failure; missing-seed `.failed`; budget gate before spend |
| Seed resolution (reuse `.screenRegion` / `.clipboardImage` capture seams) | MLX-free Core (orchestration) | `swift test` — seed wired into `MediaRequest`; missing-required-seed → `.failed(seedRequired)` |
| Gallery writer + `.fileEntry` surfacing (Files-band entry) | MLX-free Core | `swift test` — asset written under the gallery root; surfaces as `.fileEntry`; local-only/recoverable scope honored |
| Parked-while-generating feed (thinking/done/needs-you → `ParkScheduler` `didAdvance`/`escalate`) | MLX-free Core | `swift test` — progress → thinking; finished → done + unseen count; dangerous cloud video → `escalate`; cancellation → no failed badge |
| `WritePolicyResolving` consumption (effective tier; never lower `.dangerous`) | MLX-free Core | `swift test` — image `.confirm` may lower to `.auto` only on whitelist; cloud video `.dangerous` never lowered |
| `MediaError` taxonomy + boundary mapping + `AIError.message(for:)` routing | MLX-free Core | `swift test` — each case → a clean `AIPresentedError.headline`; no raw text in headline; cancellation distinct from failure |
| Canvas media preview/player overlay (`DockPreviewOverlay` species, non-activating, synchronous `orderOut`; DOWN extract / RIGHT discard) | Native-linked (app target) | `xcodebuild` COMPILE-VERIFY only; real non-activating/synchronous-teardown/compass behavior needs the user's stable-signed build |
| `ModelRegistry` residency consumption ("busy painting" eviction surface) | MLX-free Core (orchestration) | `swift test` against a stub registry — eviction → "busy painting" state; chat resumes after finish/park |

Agents NEVER build/sign/install the `.app` (ad-hoc signing breaks TCC; the `*.bundle` metallib copy in
`build-app.sh` must not regress). The concrete diffusion backends — and any real GPU/cloud latency, heat,
RAM, eviction, and spend — are verified only in their own slices and only by the user's stable-signed
build; this slice's Core seam/tools/sink/output are fully `swift test`-verified against the stub.
