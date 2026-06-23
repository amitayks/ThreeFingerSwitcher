## ADDED Requirements

> These are BACKEND-only deltas to the `ai-generative-media` capability. The seam itself — the `MediaRuntime` protocol, the `MediaKind`/`MediaParameters`/`MediaRequest`/`MediaProgress`/`MediaAsset` value types, the `generate_image` tool, the `MediaGenSink` executor, the Files-band gallery + canvas player output, the swipe-DOWN extract compass, and the `MediaError` taxonomy + its `AIError.message(for:)` mapping — is defined by `ai-media-runtime` and is REFERENCED here, never redefined. Residency/eviction and the `ModelRegistry`/`ModelDescriptor`/`ensureResident` mechanics are defined by `ai-model-fleet` and CONSUMED here.

### Requirement: Local image MediaRuntime backend (mflux/FLUX-class, MLX-native, in-process)

The system SHALL provide a concrete `MediaRuntime` conformer for **local image generation** via an mflux/FLUX-class, MLX-native diffusion model running **in-process**. It SHALL conform to the `MediaRuntime` seam exactly as defined by `ai-media-runtime` (it SHALL NOT redefine the seam): `capabilities` SHALL contain `.image`, and `generate(_:)` SHALL return an `AsyncThrowingStream<MediaProgress, Error>` that emits ordered `.step(index:total:preview:)` diffusion-progress values terminating in `.finished(MediaAsset)`. The model SHALL run on Apple-Silicon M5 (M4 minimum) with NO degraded/low-end path. The backend SHALL be gated by `mediaGenEnabled` under the `fullPotentialEnabled` master toggle.

#### Scenario: text-to-image generation streams progress then finishes

- **WHEN** a `MediaRequest` with `kind == .image` and no `seed` is generated against the local image backend
- **THEN** the returned stream emits `.step(index:total:preview:)` values in ascending `index` order up to `total`, and terminates with a single `.finished(MediaAsset)` whose `kind == .image` and whose `width`/`height` match the requested `MediaParameters.size`
- **AND** the `MediaAsset.url` points at a written PNG that `ai-media-runtime`'s sink turns into a Files-band entry

#### Scenario: capabilities advertise image only

- **WHEN** the backend's `capabilities` are read
- **THEN** the set contains `.image` and does NOT contain `.video` (video is `ai-video-animation-generation`'s backend)

#### Scenario: gated behind the master toggle

- **WHEN** `mediaGenEnabled` is false (or `fullPotentialEnabled` is false)
- **THEN** the local image capability is NOT offered and no image descriptor is selectable
- **WHEN** both flags are true
- **THEN** the capability is offered and a `generate_image` request routes the diffusion work to the `.gpu` compute lane (the `mediaDiffusion` role→lane policy owned by `ai-compute-tiers`)

### Requirement: Quant model descriptors with honest residency bytes

The system SHALL supply image-role `ModelDescriptor`s (the `ai-model-fleet` §C1 type, used verbatim) for the local image backend: a default **Q4** variant with `residencyBytes` of approximately 7 GB, and an opt-in **FP16** variant with `residencyBytes` of approximately 24 GB. Each SHALL have `role: .image`, `lane: .gpu`, `provider: .onDevice`, and `capabilities` tags reflecting what it supports (`"image"`, plus `"img2img"`/`"inpaint"` where supported). The persisted `imageModelID` SHALL select which variant is used; the default SHALL be the Q4 variant. The fleet's `ModelRegistry` SHALL register these descriptors and own the actual residency/eviction via `ensureResident(_:)`.

#### Scenario: Q4 default and FP16 opt-in descriptors

- **WHEN** the image descriptors are enumerated
- **THEN** a Q4 descriptor with `residencyBytes ≈ 7 GB`, `role == .image`, `lane == .gpu`, `provider == .onDevice` is present
- **AND** an FP16 descriptor with `residencyBytes ≈ 24 GB` and the same role/lane/provider is present
- **AND** with no `imageModelID` set the Q4 descriptor is the selected one

#### Scenario: imageModelID selects the variant

- **WHEN** `imageModelID` is set to the FP16 descriptor's id
- **THEN** the FP16 descriptor is the selected image backend
- **WHEN** `imageModelID` is set to an id that matches no image descriptor
- **THEN** selection is rejected (it is NOT silently coerced to a default)

### Requirement: Residency classification — co-resident vs evicts-chat

The system SHALL provide a pure, testable residency classification (`ImageResidencyClass`) that, given the chosen image descriptor's `residencyBytes`, the fleet's current resident model set, and the unified-memory ceiling (consumed from `ai-model-fleet`, not re-derived), classifies the outcome of making that image model resident as either **co-resident** (it fits alongside the resident chat + ternary models + KV) or **evicts-chat** (it forces the chat model out). The classification SHALL be free of real memory probing (the resident set and ceiling are injected), so it is unit-testable with fixed inputs. The classification — NOT a fresh eviction decision — SHALL be the single input to both the pre-fire cost disclosure and the "busy painting" runtime state. The actual eviction DECISION remains `ai-model-fleet`'s `ensureResident(_:)`.

#### Scenario: Q4 co-resides with chat

- **WHEN** the Q4 image descriptor (~7 GB) is classified against a resident set of {chat, ternary} + KV under the 48 GB ceiling
- **THEN** the classification is `.coResident`

#### Scenario: FP16 evicts chat

- **WHEN** the FP16 image descriptor (~24 GB) is classified against that same resident set under the 48 GB ceiling
- **THEN** the classification is `.evictsChat`

#### Scenario: classification is pure (no real probe)

- **WHEN** the classifier runs in a Core unit test with an injected resident set and ceiling
- **THEN** it produces a deterministic result with no Metal / real-weight / live-memory dependency

### Requirement: Seed-driven img2img and inpaint

When a `MediaRequest` carries a non-nil `seed` (the optional PNG first frame the seam defines — a screen-region or clipboard-image capture), the local image backend SHALL run image-to-image generation from that seed (and inpaint, where the seed PNG's alpha channel masks the region to repaint). The backend SHALL use ONLY the seam fields defined by `ai-media-runtime` (`MediaRequest.seed: Data?`) — it SHALL NOT introduce a mask field on `MediaRequest`/`MediaParameters`; a first-class mask channel, if ever required, is a seam extension owned by `ai-media-runtime`, consumed here. A seed-bearing or inpaint request SHALL statically require a seed-capable image descriptor; a mismatch SHALL be converted to a `MediaError` at the backend boundary and surfaced as a bounded, non-blocking failure — it SHALL NOT silently fall back to text-to-image. The `MediaParameters.seedNumber` SHALL drive reproducible RNG.

#### Scenario: img2img from a seed

- **WHEN** a `MediaRequest` with `kind == .image` and a non-nil `seed` is generated against a seed-capable descriptor
- **THEN** the backend generates from that PNG first frame (image-to-image) and finishes with a `MediaAsset`

#### Scenario: seed against a non-seed-capable descriptor is an error, not a degrade

- **WHEN** a seed-bearing request targets an image descriptor whose capabilities do not include `"img2img"`
- **THEN** the request is converted to a `MediaError` at the backend boundary and surfaced as a bounded, non-blocking failure
- **AND** the backend does NOT silently drop the seed and run text-to-image

#### Scenario: seedNumber is reproducible

- **WHEN** two generations use the same prompt, parameters, and `MediaParameters.seedNumber`
- **THEN** they are reproducible (the seam's reproducibility contract holds; verified in the user's stable-signed build)

### Requirement: Honest cost disclosure and busy-painting state

The local image backend SHALL disclose its cost — RAM (Q4 ~7 GB co-resident vs FP16 ~24 GB evicts-chat, derived from `ImageResidencyClass`), heat/compute (sustained M5 GPU diffusion), and latency (seconds to tens of seconds at default steps) — at the point the image model is chosen and before a generation fires, in the same breath the capability is offered. When `ImageResidencyClass` is `.evictsChat` and an FP16 generation is in flight, the system SHALL honestly surface that chat is unavailable ("busy painting") as a bounded, non-blocking observable state — never via `NSAlert.runModal`, never with raw error text in a headline. A generation that fails SHALL become a `.failed` state carrying a clean `MediaError` headline (mapped through `AIError.message(for:)`), never a false "Done"; cancellation SHALL NOT be treated as a failure.

#### Scenario: cost is disclosed before firing

- **WHEN** the user selects an image model and is about to fire a generation
- **THEN** the RAM cost (with the co-resident-vs-evicts-chat consequence), a heat/compute note, and a latency note are presented before the generation starts

#### Scenario: FP16 in flight surfaces busy-painting honestly

- **WHEN** an FP16 image generation is in flight and its classification is `.evictsChat`
- **THEN** the agent surfaces that chat is unavailable ("busy painting") as a bounded, non-blocking state
- **AND** it does NOT appear to answer chat as though the chat model were still resident
- **AND** the surface is NOT an `NSAlert.runModal`

#### Scenario: a failed generation is observable, never a false done

- **WHEN** a generation fails (model load, OOM, denoise, or PNG write)
- **THEN** the vendor/OS error is mapped to a `MediaError` at the backend boundary and the state becomes `.failed` with a clean headline routed through `AIError.message(for:)`
- **AND** raw vendor text appears only in logs or opt-in copyable details, never in the headline
- **WHEN** the user cancels a generation
- **THEN** the result is a cancellation, NOT a `.failed` state
