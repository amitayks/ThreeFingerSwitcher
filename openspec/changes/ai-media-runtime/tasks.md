> The seam + value types (§1) are the substrate. The tools + sink (§2–§3) are the route-loop integration.
> The seed (§4) and output (§5–§6) are the I/O. §7 is the parked feed, §8 the errors, §9 verifies.
> All of §1–§8 are MLX-free Core verified by `swift test` against `StubMediaRuntime`; only the canvas
> player overlay is native-linked (xcodebuild compile-verify; real behavior needs the user's build).

## 1. The `MediaRuntime` seam + media value types (Core, addendum §B1 verbatim)

- [ ] 1.1 Add `MediaKind` (`.image`/`.video`), `MediaSize` (width×height), `MediaParameters`
      (size/steps/seedNumber/guidance/durationMs), `MediaRequest` (prompt + optional `seed: Data?` PNG +
      kind + parameters), `MediaProgress` (`.step(index:total:preview:)` / `.finished(MediaAsset)`),
      `MediaAsset` (id/url/kind/width/height/durationMs, `Codable`) under `AI/Media/`, VERBATIM from
      addendum §B1. _Verify: `swift test` — Codable round-trip; seed-present/absent; durationMs video-only._
- [ ] 1.2 Add the `MediaRuntime` protocol (`capabilities: Set<MediaKind>`,
      `generate(_:) -> AsyncThrowingStream<MediaProgress, Error>`) — pinned §B1; no extra methods.
      _Verify: `swift build` compiles the protocol; exercised via the stub in §1.3._
- [ ] 1.3 Add `StubMediaRuntime` (test support): scripted progress sequences — success-with-final-asset,
      success-with-intermediate-previews, mid-flight failure, cancellation, and a per-kind capability set.
      _Verify: `swift test` — each script drives a deterministic `AsyncThrowingStream`._

## 2. The two tools in the `ToolRegistry` (Core; reuse `ToolContributor`)

- [ ] 2.1 Add `MediaToolContributor` exposing `generate_image` and `generate_video` as `ToolDescriptor`s
      (name + summary + `argsSchema`: prompt, size, steps, optional seed-image handle, video durationMs)
      with `WritePolicyTier` — image `.confirm`, cloud video `.dangerous`. _Verify: `swift test` —
      descriptors present with correct names/tiers; `argsSchema` validates a well-formed args object._
- [ ] 2.2 Gate availability: contribute nothing under `mediaGenEnabled == false` /
      `fullPotentialEnabled == false`; advertise `generate_image` only if a `MediaRuntime` advertises
      `.image`; advertise `generate_video` only if a video provider + `fleetCloudEscalationEnabled`
      (cloud) + remaining budget. _Verify: `swift test` — tools omitted from candidates when unavailable;
      present when available (the router never routes to a dead end)._

## 3. `MediaGenSink` — the route-loop executor (Core; reuse the route → execute → continue loop)

- [ ] 3.1 Add `MediaGenSink` invoked by the existing loop when the router selects a media tool: resolve
      effective tier via the injected `WritePolicyResolving`; surface a `TaskReview`-backed
      **awaiting-approval** step (DOWN=approve / RIGHT=skip) for `.confirm`/`.dangerous` BEFORE any compute
      or spend. _Verify: `swift test` — `.awaitingApproval` precedes compute; a RIGHT skip applies nothing
      and feeds back; a DOWN approval proceeds._
- [ ] 3.2 On approval: pick the `MediaRuntime` for the kind, drive `generate(_:)`, thread `MediaProgress`
      into the live UI/parked feed, write the finished asset (§5), and return a `ToolStepResult` —
      `.done` carrying the gallery path, `.failed` with a clean headline, or `.declined`. _Verify:
      `swift test` — `.done` path carries the gallery URL; the result is fed back as a `.tool` turn._
- [ ] 3.3 Enforce the cloud-video **budget cap** before the call (a media-side mirror of the handoff
      per-day cap); an exhausted budget resolves `.declined`/`.failed(cloudBudgetExhausted)` with NO spend.
      _Verify: `swift test` — budget-out resolves before any runtime call; never a silent spend._
- [ ] 3.4 Consume `ModelRegistry`/`ensureResident`; when residency math says a heavy gen must EVICT chat,
      surface a calm "busy painting" state (chat resumes on finish/park). _Verify: `swift test` against a
      stub registry — eviction → busy-painting state; not hidden, not a hang._

## 4. The seed (img2img / img2video) path (Core; reuse existing captures)

- [ ] 4.1 Resolve `MediaRequest.seed` from the EXISTING `.screenRegion` (region picker) and
      `.clipboardImage` (live pasteboard → PNG) capture seams; wire it as the first frame. No new picker;
      no auto-fire on a clipboard image. _Verify: `swift test` — a captured/clipboard image becomes the
      request seed; no auto-fire path exists._
- [ ] 4.2 A tool authored as img2img/img2video with no resolvable seed resolves
      `.failed(MediaError.seedRequired)` — never a fabricated blank frame; an undecodable seed →
      `.failed(seedInvalid)`. _Verify: `swift test` — missing/invalid seed → clean `.failed`, no compute._

## 5. Output #1 — the Files-band gallery asset (Core; reuse the band)

- [ ] 5.1 Write the finished `MediaAsset.url` under a dedicated **generated-media gallery** root (local-only,
      recoverable, honoring the band's non-destructive scope). _Verify: `swift test` — asset persists under
      the gallery root; survives a simulated relaunch read._
- [ ] 5.2 Surface the asset as an ordinary `.fileEntry` in the Files band (reuse on-demand listing,
      lift-to-deliver / Open / Open-With / contextual delivery — no new browser). _Verify: `swift test` —
      a gallery asset maps to a `.fileEntry` the band lists; identity is path-stable (no strobe)._

## 6. Output #2 — the canvas preview/player resolved by the compass

- [ ] 6.1 Model the canvas media state: generating (live `.step` + intermediate preview) → finished
      (image, or a player for video). _Verify: `swift test` — the pure state model advances on progress and
      terminates on `.finished`/`.failed`/`.cancelled`._
- [ ] 6.2 Build the player overlay as a `DockPreviewOverlay`-pattern panel: **non-activating**, never
      key/main, **synchronous `orderOut`**; bud in with `BubbleMorph`. _Verify: `xcodebuild` compile-verify
      only; non-activating + synchronous-teardown behavior needs the user's stable-signed build (§9.3)._
- [ ] 6.3 Resolve by the canonical compass: **DOWN (at canvas-top) extracts** — save / paste / set-as;
      **RIGHT discards** (the asset is already in the gallery, so discard never loses it). _Verify:
      `swift test` — the pure resolve model: DOWN-at-top → extract intent; RIGHT → discard with the file
      intact; sub-threshold scroll never resolves._

## 7. Parked-while-generating (Core; feed `ParkScheduler`, don't reinvent)

- [ ] 7.1 Feed the parked machinery the job's observable state: **thinking** badge while painting, **done**
      badge (+ unseen count) + notch **glow** on `.finished`. _Verify: `swift test` — progress → thinking;
      finished → done + unseen count; reported via `ParkScheduler.didAdvance`._
- [ ] 7.2 A `.dangerous` cloud-video step on a parked session calls `ParkScheduler.escalate` → needs-you +
      ambient glow (a clean one-line reason); a cancellation is NOT a failure (no failed badge). _Verify:
      `swift test` — dangerous-video parked → escalate; cancellation → cancelled, never a failed badge._

## 8. `MediaError` taxonomy + boundary mapping (Core; one translator)

- [ ] 8.1 Add `enum MediaError: Error, Equatable` (`LocalizedError`): `noCapableBackend(kind)`,
      `seedRequired`, `seedInvalid`, `generationFailed(headline)`, `outputWriteFailed`,
      `cloudBudgetExhausted`, `cloudUnavailable`; each a clean per-case `errorDescription`. _Verify:
      `swift test` — every case has a clean non-empty description._
- [ ] 8.2 Map vendor/OS errors (mflux/LTXV/ComfyUI, `Process`, `NSURLError`, `FileManager`) into
      `MediaError` at the layer boundary (sink/backend conformer); route every surface through
      `AIError.message(for:)` → `AIPresentedError`; bounded + non-blocking (never `NSAlert`, never raw in a
      headline). _Verify: `swift test` — a vendor error maps to a `MediaError` then a clean headline; raw
      text only in details/logs._
- [ ] 8.3 Write one `AuditRecord` per media step (auto/confirmed/declined/escalated/failed) through the
      shared `AuditLog` (redacted args summary; failure carries only the clean headline). _Verify:
      `swift test` — each terminal outcome appends exactly one record with the effective tier + redacted
      args._

## 9. Verify

- [ ] 9.1 `swift build` + `swift test` green: the seam, value types, contributor, sink, seed, gallery,
      canvas resolve model, parked feed, and `MediaError` are all Core and covered against
      `StubMediaRuntime`/stub registry. No piece links MLX.
- [ ] 9.2 `openspec validate ai-media-runtime --strict` passes; the `ai-generative-media` ADDED
      requirements and the `ai-command-tasks` MODIFIED delta match the implemented seam/tools/sink/output.
- [ ] 9.3 **User run-verify** in a stable-signed build (an agent never builds/signs the `.app`): the model
      can route to `generate_image`, the `.confirm` approval shows (DOWN approves), the canvas shows live
      step-progress, the finished image lands as a Files-band gallery asset AND a non-activating
      compass-resolved canvas preview (DOWN saves/pastes, RIGHT discards leaving the file), the session
      parks while painting (thinking → done glow), a cloud-video tool escalates needs-you under the budget
      cap, and a heavy gen surfaces "busy painting" rather than a hang. Real latency/heat/RAM/eviction/$ are
      observed only here and in the backend slices.
