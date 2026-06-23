## Context

`ai-media-runtime` (addendum §B1) owns the **second runtime seam**, `MediaRuntime`: a long async job that streams `MediaProgress` and ends in a `MediaAsset` file — NOT a token stream. It owns the value types (`MediaKind`/`MediaParameters`/`MediaRequest`/`MediaProgress`/`MediaAsset`), the `generate_image` / `generate_video` `ToolDescriptor`s, the `MediaGenSink` that executes them through the existing route→execute→continue loop, and the output surfaces (Files-band gallery entry + canvas preview/player). It does NOT own the concrete backends.

This slice owns the **video backend behind that seam** (addendum §B3). The pinned, honest framing:

- **Local video is a frontier, not the default.** LTXV-class video is ComfyUI/MPS, 35 GB+ weights, minutes-per-clip, and it EVICTS chat under the 48 GB budget (fleet §C1, decision §5.5 of the addendum). That is real and must be disclosed, not hidden. It belongs behind the master `fullPotentialEnabled` toggle.
- **The honest default is CLOUD escalation** (LTX Studio API / hosted), and because that spends money and uploads bytes, it is gated **exactly like the Claude handoff** (§3.8): confirm-by-default, per-day budget/rate cap over a relaunch-surviving ledger, needs-you escalation when parked, one audit record per attempt, fire-and-forget with progress.
- **One seam, swappable backends.** Both `CloudVideoRuntime` (default) and `LocalLTXVRuntime` (frontier) are `MediaRuntime` conformers advertising `capabilities = [.video]`. The fleet's `videoProvider` descriptor picks which is wired. A future local LTXV (or a different cloud vendor) drops in at the same seam — exactly as `LLMRuntime` lets Gemma be swapped, so feature code (the sink, the canvas, the Files output) never changes.

This slice reuses the gating machinery of `ai-claude-handoff` and `ai-background-autonomy` rather than inventing a parallel one: cloud video IS a dangerous, money-spending, network-escalating tool, structurally identical to `launch_claude`.

## Goals

- A concrete `video`-capable `MediaRuntime` that defaults to **cloud escalation**, selected by the registry's `videoProvider`.
- Cloud video gated **`.dangerous` + budget-capped + audited + needs-you-when-parked**, reusing `WritePolicyTier` / `AuditLog` / the handoff budget pattern — NOT a new gate.
- **Honest disclosure**: the confirm step and audit summary state the bytes leave the device and the per-clip cost; the redacted summary never carries the full prompt or raw seed bytes.
- A **frontier local LTXV** backend behind `fullPotentialEnabled` + `mediaGenEnabled`, disclosing 35 GB+ residency, minutes-per-clip latency, chat eviction, and thermal cost.
- **img2video from the seed**, fire-and-forget with `MediaProgress` step previews, parking because it is slow.
- The seam-swap contract: a later backend joins the SAME `MediaRuntime` with no feature-code change.
- The **majority** of the slice (selector, budget, disclosure, tier resolution, progress plumbing, parking, error mapping) is MLX-/network-free Core, `swift test`-verified via stubs.

## Non-Goals

- Redefining the `MediaRuntime` seam, the `generate_video` descriptor, the `MediaGenSink`, or the Files-band / canvas output — all owned by `ai-media-runtime` and CONSUMED here.
- The image backend (`ai-local-image-generation`), the fleet residency/eviction MATH (`ai-model-fleet`), the master Hub toggle page (`ai-full-potential-toggle`).
- A new error taxonomy when `MediaError` / `RuntimeError` already carries the case; a new gating mechanism when the §3.8 budget pattern already fits.
- Pinning a specific hosted vendor's exact API schema beyond "upload prompt + optional seed, poll progress, fetch a file"; any non-LTXV / non-LTX-Studio backend.
- A structured round-trip beyond fire-and-forget-with-progress; video editing (trim/splice) of the result.
- Any degraded / low-end / Intel path. M5 floor (M4 min). No regressions.

## Decisions

### 1. The video backend is a `MediaRuntime` conformer, not a new seam.

`CloudVideoRuntime` and `LocalLTXVRuntime` both conform to the `MediaRuntime` protocol (owned by `ai-media-runtime`), advertise `capabilities = [.video]`, and implement `generate(_:) -> AsyncThrowingStream<MediaProgress, Error>`. The `MediaGenSink` and canvas/Files surfaces are unchanged.

- **Rationale:** the addendum pins exactly one media seam and demands "build it so a local LTXV drops into the SAME `MediaRuntime` later, exactly as `LLMRuntime` lets Gemma be swapped." A second protocol would fork the seam and break the swap contract.
- **Alternatives rejected:** (a) a dedicated `VideoRuntime` protocol — forks the seam, duplicates the progress/asset plumbing, violates the pinned reuse rule. (b) Folding video into the image runtime — different residency class, different lane behavior (evicts chat), different gating tier; conflating them hides the cost.

### 2. The default video backend is CLOUD escalation; local is the frontier exception.

`videoProvider` defaults to `.cloud` (a `CloudVideoRuntime` over a hosted API). `.localLTXV` is selectable only when `fullPotentialEnabled` AND `mediaGenEnabled` are on.

- **Rationale:** addendum §B3 + decision §5/§6 — "Honest default = CLOUD escalation … Local LTXV is a FRONTIER option behind the full-potential toggle." Cloud keeps the calm default (no 35 GB download, no eviction, no fans) and matches the project's honest-surface ethos; local is the deliberate "release full potential."
- **Alternatives rejected:** (a) local-LTXV default — dishonest: it would silently download 35 GB, evict chat on first use, and pin the GPU for minutes; the opposite of "ships calm." (b) cloud-only, no local path — abandons the frontier user and the swap contract that proves the seam is backend-agnostic.

### 3. Cloud video is `.dangerous` + budget-capped, mirroring the Claude handoff (NOT the image tool's `.confirm`).

When `videoProvider == .cloud`, the effective gate for `generate_video` is **dangerous**: confirm-by-default per call, escalates to **needs-you** when parked, runs only when the user approves. A pure `VideoBudget` enforces a **rolling-24h** call cap + a concurrency cap over an **append-only ledger that survives relaunch**, `now:`-injected (deterministic). An over-budget call **never silently drops** — it degrades to a foreground confirm (active) or needs-you (parked) and states the cap was reached. A failed launch **refunds** its spend so the cap stays honest.

- **Rationale:** cloud video spends real money AND uploads bytes — strictly more dangerous than `launch_claude`, which is "dangerous." The addendum says gate it "EXACTLY like the Claude handoff." Reusing the §3.8 budget/escalation pattern (rolling window, ledger, refund, degrade-not-drop) gives the same runaway-spend protection with one audited mechanism.
- **Alternatives rejected:** (a) `.confirm` like the image tool — image gen is free + local; cloud video is neither; a one-tap confirm with no cap is a runaway-spend hole. (b) A calendar-day reset — gameable across midnight (the handoff spec already rejected this); a rolling 24h window keyed off injected time is the adopted rule. (c) Silently dropping over-budget calls — the blueprint forbids silent side-effect loss; degrade-to-confirm keeps the user the only authority that spends over the cap.

### 4. Honest upload + cost disclosure at the confirm step and in the audit summary.

Because cloud video sends the prompt (and any seed frame) off-device, the confirm step states the bytes leave the device and the per-clip $ order; the **redacted** audit summary carries the provider, a **truncated** prompt, and a **seed-image-present flag** — never the full prompt verbatim, never the raw seed bytes. Local-LTXV discloses 35 GB+ residency, minutes-per-clip latency, chat eviction, and thermal cost at selection.

- **Rationale:** the project's honest-surface ethos (addendum §D1 disclosure UX) + the blueprint redaction rule (raw text only in logs / behind an opt-in details disclosure, never in a headline / audit summary). A remote upload is a privacy event the user must consent to knowingly.
- **Alternatives rejected:** (a) a generic "generating video…" with no upload notice — hides a privacy + spend event. (b) Putting the full prompt in the audit summary — violates the redaction rule and can leak secrets.

### 5. img2video from the seed; fire-and-forget with progress; parks because it is slow.

Both backends consume the optional `MediaRequest.seed` (PNG) as the first frame for img2video. `generate(_:)` streams `MediaProgress.step(index:total:preview:)` while the remote/local job runs and ends in `MediaProgress.finished(MediaAsset)` with `kind == .video` and `durationMs != nil`. Because the job is minutes-long, it **parks** via `ParkScheduler`; the notch glows on completion / `needsYou`. The finished clip lands as a Files-band asset + a canvas player; **swipe-DOWN** extracts it (the canonical compass).

- **Rationale:** addendum §B1/§B3 + decision §4 — "Media is a tool, parked because it's slow … Output is a Files-band asset"; the seed field exists precisely so a screen-region/clipboard capture becomes the first frame. Streaming step previews keeps the slow job observable (failure is observable state, never silence).
- **Alternatives rejected:** (a) a blocking call returning only the final file — a minutes-long block freezes the agent and gives no progress; parking + a stream is the pinned model. (b) Building a new video player overlay — reuse the canvas player + `DockPreviewOverlay` non-activating / synchronous-`orderOut` pattern (owned upstream), do not reinvent.

### 6. Local video is OFF the cloud spend/budget path but still audited and still parks.

`LocalLTXVRuntime` spends no money and uploads nothing, so it does NOT consume the `VideoBudget` ledger and is NOT `.dangerous` on the spend axis. It is still gated by the master toggle (frontier), still emits exactly one audit record per attempt, and still parks (it is slow). Its disclosure is residency/heat/eviction, not $.

- **Rationale:** the budget cap exists to bound real spend; local video has none. But "failure is observable, every attempt audited" still binds, and local video is still minutes-long so it parks. Conflating "dangerous" (spend) with "expensive" (compute) would mis-gate local video.
- **Alternatives rejected:** charging local video against the cloud budget — nonsensical; the budget is a $ cap. Skipping its audit — violates "every tool step writes one audit record."

### 7. Errors map into the shared `MediaError` at the boundary; a video enum only if needed.

Vendor/OS failures — `NSURLError` (cloud upload/poll), `Process`/ComfyUI failures (local), over-budget, provider-disabled, upload-declined — map into the `MediaError` taxonomy (owned by `ai-media-runtime`) at the layer boundary inside each runtime. A video-only `enum` is added ONLY if `MediaError` / `RuntimeError` cannot carry a case (e.g. `.videoBudgetExceeded`, `.videoProviderDisabled`). Everything surfaces through the single `AIError.message(for:)` translator, bounded + non-blocking — never `NSAlert.runModal`, never raw OS/vendor text in a headline (raw text only in logs / behind a Show-details disclosure). A side effect that did not land (no clip written, upload failed) becomes `.failed`, never a false "Done."

- **Rationale:** blueprint invariant — one taxonomy, one translator, mapped at the boundary, surfaced bounded + non-blocking. Core stays MLX-/network-free, so it cannot see `NSURLError` / `Process` types; only the taxonomy crosses into feature code.
- **Alternatives rejected:** a standalone video error surface / raw `NSURLError.localizedDescription` in the canvas — violates the one-translator + redaction rules; an `NSAlert` would freeze the Settings window (the bounded + non-blocking rule).

### 8. The swap-in contract is a first-class requirement.

The slice specifies that a later video backend (a different cloud vendor, or in-process local video when feasible) joins the SAME `MediaRuntime` seam, selected by `videoProvider`, with no change to the sink, canvas, Files output, gating, or budget code.

- **Rationale:** addendum §B3 explicitly requires "build the seam so a local LTXV backend drops into the SAME `MediaRuntime` later." Making it a spec requirement (not just prose) lets a future slice verify the seam held.
- **Alternatives rejected:** leaving it implicit — risks a future backend bolting on a parallel path and forking the seam.

## Per-component target-split & verification

| Component | Target | Verification |
|---|---|---|
| `VideoProvider` selector value (`.cloud` / `.localLTXV`) backing `videoProvider` | Core (MLX-/network-free) | `swift test` — round-trips Codable, default `.cloud`, `.localLTXV` requires master toggle |
| `VideoBudget` (pure rolling-24h rate/concurrency cap over append-only ledger, `now:`-injected) | Core | `swift test` — under-cap allows, rolling window not gamed across midnight, survives relaunch (ledger replay), failed launch refunds, over-budget degrades not drops |
| Effective-tier resolution for `generate_video` (cloud → `.dangerous`; local → master-gated) | Core | `swift test` — cloud resolves dangerous, ∩ user whitelist, local gated by `fullPotentialEnabled` + `mediaGenEnabled` |
| `VideoUploadDisclosure` (does-bytes-leave + redacted summary builder: provider + truncated prompt + seed-present flag) | Core | `swift test` — summary never contains full prompt or raw seed bytes; upload flag true for cloud, false for local |
| Audit emission (exactly one `AuditRecord` per attempt: done/declined/failed/over-budget) | Core | `swift test` — one record per resolution, redacted summary, `wasBackground` set when parked |
| Parking + `MediaProgress` plumbing (stream step previews → finished, escalate/needsYou when slow) | Core | `swift test` with `StubCloudVideoRuntime` / `StubLocalVideoRuntime` (scripted progress → finished) |
| `MediaError` boundary mapping for video (over-budget / provider-disabled / upload-declined; + any video-only enum) | Core | `swift test` — vendor/OS surrogates map to taxonomy; routes through `AIError.message(for:)`; no raw text in headline |
| `CloudVideoRuntime` (real `URLSession` upload/poll against hosted API; maps `NSURLError` at boundary) | Native-linked (`GemmaRuntime`/sibling framework) | `xcodebuild` COMPILE-VERIFY only for an agent; real upload/poll/spend/latency verifiable ONLY in the user's stable-signed build |
| `LocalLTXVRuntime` (ComfyUI/MPS process bridge; maps `Process`/ComfyUI errors at boundary) | Native-linked | `xcodebuild` COMPILE-VERIFY only; real 35 GB residency, minutes-per-clip, chat eviction, heat verifiable ONLY in the user's stable-signed build |
| Canvas video player / reveal surface (reuses `DockPreviewOverlay` non-activating + synchronous `orderOut`; owned upstream) | Native-linked (consumed) | `xcodebuild` compile-verify; live player behavior in the user's stable-signed build |

An agent NEVER builds/signs/installs the `.app` (ad-hoc signing breaks TCC; the `*.bundle` metallib copy in `build-app.sh` must not regress). Real video — a real clip, real $ spend, real eviction, real thermals — is the user's stable-signed build's job.
