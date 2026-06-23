## Context

The generative-media seam already exists by the time this slice lands. `ai-media-runtime` owns the `MediaRuntime` protocol, the `MediaKind`/`MediaParameters`/`MediaRequest`/`MediaProgress`/`MediaAsset` value types (addendum §B1, verbatim), the `generate_image`/`generate_video` `ToolDescriptor`s, the `MediaGenSink` route-loop executor, the Files-band gallery + canvas player output, the swipe-DOWN extract compass, and the `MediaError` taxonomy + its `AIError.message(for:)` mapping. This slice does **not** touch any of that. It plugs ONE concrete backend in behind the seam.

The fleet already exists too. `ai-model-fleet` (addendum §C1) evolved `ModelManager` into a `ModelRegistry` of `ModelDescriptor`s with residency/eviction under the 48 GB unified-memory budget; `ComputeLane` (§A1) and the `mediaDiffusion → .gpu` role→lane policy come from `ai-compute-tiers`. This slice **consumes** those: it supplies the image-role `ModelDescriptor`s, asks `ensureResident`, and classifies the resulting co-reside-vs-evict reality for the UI. The eviction *decision* is the fleet's; the *honest surfacing* of it is shared between the fleet spec and this backend's "busy painting" state.

The hardware fact that justifies *local* image (vs the cloud-default video, §B3): **diffusion is compute-bound on M5**, the opposite of token decode. Token decode re-reads the whole weight set per token (bandwidth-bound at ~153 GB/s, which is why the GPU lane batches). A denoise step is dense matmul over a small latent against a once-resident UNet/transformer — arithmetic-bound, so it rides the M5 neural accelerators (~3.8× vs M4 for this workload class). An image is small enough to fit and fast enough to run on-device; round-tripping it to a datacenter would be the worse trade. Video stays cloud-default because LTXV-class local is 35 GB+ and minutes/clip (§B3) — a different cost regime.

The seed contract is already the seam's: `MediaRequest.seed: Data?` is an optional PNG first frame — the screen-region or clipboard-image capture (the existing `.screenRegion`/`.clipboardImage` capture surfaces). This slice reads it for **img2img / inpaint**; absent, it is text-to-image.

## Goals / Non-Goals

**Goals:**
- A concrete `MediaRuntime` conformer for **local image** via mflux/FLUX-class **MLX-native in-process** diffusion (`MFluxImageRuntime`), conforming to the seam *as written* — no seam changes.
- Quant `ModelDescriptor` variants with **honest `residencyBytes`**: Q4 (~7 GB, co-resident) default, FP16 (~24 GB, evicts chat) opt-in.
- A **pure, testable** residency classifier (co-reside vs evict-chat) consumed by the cost disclosure and the "busy painting" state — the eviction *decision* stays the fleet's.
- **Seed-driven img2img / inpaint** from `MediaRequest.seed`, statically requiring a seed-capable descriptor.
- **Honest cost disclosure** (RAM / heat / latency / eviction) where the image model is picked and before a gen fires.
- The pure majority (descriptors, classifier, param/seed validation, a stub backend) is `swift test`-verified; the MLX diffusion conformer is `xcodebuild` compile-verified by an agent and run-verified by the user.

**Non-Goals:**
- The seam, the tools, the sink, the Files/canvas output, the extract compass, the `MediaError` taxonomy (all `ai-media-runtime`). Referenced, never re-specified.
- The residency *decision* / eviction mechanics / the registry itself / the 48 GB budget math (all `ai-model-fleet`). Consumed.
- The `ComputeLane` enum + the role→lane policy (`ai-compute-tiers`). Consumed (`mediaDiffusion → .gpu`).
- The master / sub-capability toggles (`ai-full-potential-toggle`). Consumed (`mediaGenEnabled` under `fullPotentialEnabled`).
- **All video** (`ai-video-animation-generation`). A remote/cloud image provider (local-only here).
- A degraded/low-end path (M5 floor, M4 min; addendum decision 1).

## Decisions

### D1. The backend is a `MediaRuntime` conformer, not a new seam.
`MFluxImageRuntime` conforms to `MediaRuntime` (§B1) exactly: `capabilities: Set<MediaKind> = [.image]`; `generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error>`. The denoise loop emits `.step(index:total:preview:)` once per diffusion step (the optional `preview: Data?` is a low-res latent decode for the canvas's live progress, gated so it never dominates step time), terminating in `.finished(MediaAsset)` after writing the PNG to disk (which `MediaGenSink` then turns into a Files-band entry).
- **Rationale:** the blueprint's reuse-don't-reinvent rule and §B1's explicit "owns the seam, NOT the backends." A second image seam would fork the sink and the output path.
- **Alternatives rejected:** a bespoke `ImageRuntime` protocol (forks the seam; the whole point of `MediaRuntime` is backend-swappability, exactly as `LLMRuntime` lets Gemma be swapped). Returning bytes synchronously instead of a progress stream (loses the canvas live-preview + cancellation the seam already carries).

### D2. mflux/FLUX-class, MLX-native, **in-process** — not a subprocess/ComfyUI.
The image backend links MLX and runs the diffusion graph **in the app process**, like `GemmaMLXRuntime`. This is the §B2 mandate and the reason image is in scope now: it shares the one resident-weights / unified-memory model with chat, so residency math is *one* budget, not two processes fighting for RAM.
- **Rationale:** in-process MLX means the fleet's single 48 GB residency budget governs everything; a Q4 image model genuinely co-resides with chat in the same address space. It also reuses the metallib `*.bundle` path `build-app.sh` already ships.
- **Alternatives rejected:** a ComfyUI/MPS subprocess (that is explicitly the *video* frontier model, §B3 — 35 GB+, minutes/clip, out-of-process; wrong cost regime for image and would double-count RAM outside the fleet budget). Calling a cloud image API (local is feasible now; cloud image would be a silent-spend surprise the addendum's decision 6 forbids by default).

### D3. Quant variants are `ModelDescriptor`s with honest `residencyBytes`; the fleet registers + selects.
This slice supplies two image descriptors (§C1 shape, verbatim): Q4 `residencyBytes ≈ 7 GB` (default, co-resident) and FP16 `residencyBytes ≈ 24 GB` (opt-in, evicts chat), each `role: .image`, `lane: .gpu`, `provider: .onDevice`, `capabilities: ["image", "img2img", "inpaint"]` as supported. `imageModelID` (persisted, addendum §1 key) selects which. The fleet's `ensureResident(_ id:)` does the actual residency/eviction.
- **Rationale:** `residencyBytes` is the eviction-budget input the fleet already consumes; supplying it honestly per quant is how "Q4 co-resides, FP16 evicts chat" becomes *math*, not a guess. `ModelDescriptor` is the §C1 contract — consumed as written.
- **Alternatives rejected:** a single fixed model (denies the user the co-reside-vs-quality trade the hardware affords). Hiding the quant choice (violates the disclosure ethos — the RAM/quality trade is the whole honest story). Inventing a backend-local descriptor type (conflicts with §C1; consumers must use `ModelDescriptor` verbatim).

### D4. `ImageResidencyClass` — a pure classifier this slice OWNS; the eviction DECISION stays the fleet's.
A small pure value/function in Core: given a chosen image `ModelDescriptor` (its `residencyBytes`) and the fleet's current `resident()` set + the 48 GB ceiling, classify the outcome as **`.coResident`** (fits alongside the resident chat + ternary + KV) or **`.evictsChat`** (forces the chat model out). This is `swift test`-verified with fixed inputs (no Metal, no real weights). It is the input to (a) the **pre-fire cost disclosure** and (b) the runtime's honest **"busy painting"** state when FP16 is in flight.
- **Rationale:** the fleet owns *whether/how* to evict (`ensureResident`); this slice owns *telling the truth about it* at the image surface. Classification is pure math over the §C1 descriptors → unit-testable without GPU, satisfying the "majority is Core" target-split. Mirrors the batched slice's pure `ConcurrencyBudget` (residency math is testable; real probing is injected at the boundary).
- **Alternatives rejected:** letting the runtime silently decide eviction (double-owns the fleet's job and hides it). Surfacing eviction only *after* it happens (the disclosure ethos requires stating cost *in the same breath* the capability is offered — classification must run pre-fire). Re-deriving the 48 GB budget here (the fleet owns it; this consumes `resident()` + a ceiling the fleet exposes, it does not re-specify the budget).

### D5. "Busy painting" is an honest observable state, never a pretended co-residency.
When the classifier says `.evictsChat` and an FP16 generation is in flight, the agent honestly surfaces that chat is unavailable ("busy painting") rather than appearing to answer while the chat weights are gone. This rides the existing bounded, non-blocking surface (a state, not an `NSAlert`); a generation that fails to land becomes `.failed` with a clean `MediaError` headline (never a false "Done"). Cancellation is not a failure.
- **Rationale:** addendum decision 5 ("surface 'busy painting' honestly") + blueprint invariant ("a side effect that did not land is `.failed`, never a false Done"; bounded + non-blocking).
- **Alternatives rejected:** queueing chat turns silently behind the paint (looks hung; no honest signal). Reloading chat per chat-turn mid-paint (thrashes weights, blows the budget). An `NSAlert.runModal` "busy" dialog (banned — freezes the window).

### D6. Seed → img2img / inpaint; a seed/inpaint request statically requires a seed-capable descriptor.
When `MediaRequest.seed` is non-nil, the runtime runs image-to-image (and inpaint, where the seed PNG's alpha channel masks the region to repaint) from that PNG first frame. NB: the pinned seam (§B1) carries ONLY `MediaRequest.seed: Data?` — there is **no** mask field on `MediaRequest`/`MediaParameters`. This slice does **not** invent one; inpaint is driven by the seed PNG (alpha as mask). Any first-class mask channel, if it is ever needed, is a SEAM extension owned by `ai-media-runtime` — this backend consumes whatever the seam provides and must not assume a `MediaParameters`/`MediaRequest` field the pinned sketch lacks. The capability is advertised in the descriptor (`"img2img"`/`"inpaint"` tags) and the runtime's `capabilities`; a seed-bearing request against a non-seed-capable selection maps to `MediaError` **at this backend's boundary** — never a silent text-only fallback (mirrors the vision-required static rule for the chat runtime).
- **Rationale:** the seed contract is already the seam's first-frame field; honoring it for img2img/inpaint is the §B2 mandate. Static capability-gating matches the existing vision-required pattern (no silent degrade).
- **Alternatives rejected:** ignoring the seed and always doing text-to-image (drops a declared seam capability). A runtime-time fallback to text-only on mismatch (silent degrade — the house bans it; map to `MediaError` and surface it).

### D7. Vendor/OS errors map to `MediaError` at THIS backend's boundary; Core stays MLX-free.
mflux/MLX failures (model load, OOM at residency, Metal/GPU faults, denoise failure), `Process`/file-IO failures (PNG write), and capability mismatches are converted into `MediaError` (owned by `ai-media-runtime`) **inside `MFluxImageRuntime`** (the layer boundary), exactly where vendor types cross into app code. Core never sees mflux/MLX types. Everything surfaces through the single `AIError.message(for:) → AIPresentedError` translator: bounded, non-blocking, clean headline, raw vendor text only in logs / opt-in copyable details.
- **Rationale:** blueprint "map at the layer boundary" + "one taxonomy, one translator." Core's `swift test` target must stay MLX-free, so the mapping lives in the native-linked conformer.
- **Alternatives rejected:** a new image-specific error enum (the addendum says reuse `MediaError`; a backend does not own a taxonomy). Raw `"\(error)"` in a headline (banned).

### D8. The image stub makes the whole pure path test-verified without GPU.
A `StubMediaRuntime`-class image stub (Core, no weights) emits deterministic `.step(index:total:preview:)` progress then a `.finished(MediaAsset)` pointing at a tiny written/placeholder PNG, so the route → progress → asset → Files-entry → disclosure path is `swift test`-verified end to end. Vision/seed mismatch, param validation, and `ImageResidencyClass` are all exercised against the stub.
- **Rationale:** the §B1/§2 target-split mandates a stub so the seam-consuming logic is tested without real weights; mirrors `StubLLMRuntime`/`StubMediaRuntime`.
- **Alternatives rejected:** testing only against the real MLX runtime (can't — `swift test` is MLX-free; an agent never builds the `.app`).

## Target-split & verification (per component)

| Component | Target | Verified by |
|---|---|---|
| Image `ModelDescriptor` variant table (Q4/FP16, honest `residencyBytes`, role/lane/provider/capabilities) | **Core (MLX-free)** | `swift test` — Q4 ≈ 7 GB & FP16 ≈ 24 GB; `role == .image`, `lane == .gpu`, `provider == .onDevice`; capability tags present; `imageModelID` selects the right descriptor |
| `ImageResidencyClass` pure classifier (co-reside vs evict-chat) | **Core (MLX-free)** | `swift test` — Q4 + resident{chat,ternary,KV} → `.coResident`; FP16 → `.evictsChat`; boundary at the ceiling; classifier consumes injected `resident()` + ceiling (no real probe) |
| Seed/param/capability validation (img2img/inpaint requires seed-capable descriptor; param bounds) | **Core (MLX-free)** | `swift test` — seed-bearing request vs non-seed descriptor → mismatch error; valid img2img passes; out-of-range steps/size rejected |
| Image stub (`StubMediaRuntime`-class, deterministic progress) | **Core (MLX-free)** | `swift test` — emits ordered `.step` then `.finished(MediaAsset)` with a valid written PNG URL; cancellation ends the stream without a `.finished` |
| `MFluxImageRuntime` — mflux/FLUX-class MLX diffusion conformer (real denoise loop, seed img2img/inpaint, PNG write) | **Native-linked (`GemmaRuntime`/sibling framework)** | `xcodebuild` **compile-verify only** for an agent; **real image output, step preview, latency, and the metallib `*.bundle` path need the USER's stable-signed build** |
| Vendor→`MediaError` boundary mapping (mflux/MLX/`Process`/file-IO → `MediaError`) | **Native-linked** | `xcodebuild` compile-verify; **user** run-verify that a forced load/OOM/write failure surfaces a clean bounded card (not `NSAlert`, not raw text) |
| Real residency/eviction with real weights (Q4 co-reside; FP16 evict-chat → "busy painting") | **User stable-signed build** | **user** run-verify only — co-residency + the eviction reality + the "busy painting" state can only be observed with real weights resident under the real 48 GB budget; an agent never builds/signs the `.app` |
| Honest cost disclosure surface (RAM/heat/latency where `imageModelID` is chosen + pre-fire) | **Core values + app UI** | `xcodebuild` compile-verify the UI; `swift test` the underlying classifier/values; **user** run-verify the displayed RAM/eviction note tracks the chosen quant |

## Risks / honest costs

- **The MLX diffusion conformer is the only place real correctness can't be agent-verified.** No cross-step latent corruption, correct sampler/scheduler, seed reproducibility (`seedNumber`), and the metallib bundle path are all `xcodebuild`-compile-only for an agent and need the user's stable-signed build. Mitigation: keep every *schedulable/classifiable* thing (descriptors, residency class, validation, stub) pure in Core and tested; the spec scenarios make the user run-verify unambiguous.
- **FP16 evicts chat — this is a real cost, surfaced, not a bug.** ~24 GB FP16 forces the chat weights out; the companion genuinely cannot talk while it paints. Disclosed before firing and surfaced as "busy painting." Q4 (~7 GB) is the default precisely so the common case keeps chat alive.
- **Sustained GPU diffusion is heat + latency.** Even at the M5 neural-accelerator sweet spot, default-step image gen is seconds-to-tens-of-seconds of sustained GPU burn. Surfaced in the same breath the capability is offered (disclosure ethos); the gen parks via `ParkScheduler` (the seam's, `ai-media-runtime`) so it never blocks the foreground.
- **M5 floor, no degraded path.** No Intel/low-end fallback; gated behind `mediaGenEnabled` under `fullPotentialEnabled`. An unsupported host simply does not offer the capability rather than offering a degraded one.
