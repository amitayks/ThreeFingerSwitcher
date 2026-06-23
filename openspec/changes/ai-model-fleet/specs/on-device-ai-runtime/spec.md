## ADDED Requirements

### Requirement: Model fleet descriptor with role, lane, provider, and residency cost

The system SHALL describe every known model with a fleet `ModelDescriptor` that carries, in addition to its existing identity, size, integrity hash, download source, and capability set: a **role** (`chat`, `ternaryChat`, `image`, `video`, or `cloudEscalation`), an optional **compute lane** (`gpu` or `cpuTernary`, nil for cloud models), a **provider** (`onDevice` or `cloud`), a **residency cost in bytes** (the resident footprint used by the eviction budget; 0 for cloud models), and an optional **maxContextTokens** (chat/ternary models only). The added fields SHALL be additive: a descriptor constructed without them SHALL default to an on-device GPU chat model, so existing single-model registry entries and the model-loading pipeline are unchanged.

#### Scenario: A bare chat descriptor defaults to the single-model shape
- **WHEN** a `ModelDescriptor` is constructed without specifying role, lane, or provider
- **THEN** it reads as a `chat` model on the `gpu` lane with provider `onDevice`, identical to the pre-fleet descriptor

#### Scenario: A descriptor carries its fleet attributes
- **WHEN** an image, video, ternary, or cloud model is registered
- **THEN** its descriptor exposes its role, its lane (nil for cloud), its provider, and its residency cost in bytes (0 for cloud), and these are available to selection, residency planning, and the configuration UI

### Requirement: Model registry exposes the fleet, residency, and admission

The system SHALL access the fleet through a `ModelRegistry` that can enumerate **all** known descriptors, enumerate the **currently resident** descriptors, and **ensure a model is resident** by identifier (admitting it, evicting other models as required by the residency budget). A `cloud`-provider model SHALL appear in the full enumeration (so it can be selected and shown in the UI) but SHALL NEVER appear in the resident enumeration and ensuring it resident SHALL be a residency no-op (it is not loaded locally). A registry containing only the single chat descriptor (a fleet-of-one) SHALL behave exactly as today's single-model lifecycle.

#### Scenario: The fleet is enumerable but cloud is never resident
- **WHEN** the registry is queried for all descriptors and for resident descriptors
- **THEN** every fleet member (including the cloud members) appears in the full list, and no `cloud`-provider member ever appears in the resident list

#### Scenario: A fleet-of-one behaves as today
- **WHEN** the registry holds only the chat descriptor and the chat model is ensured resident
- **THEN** the model is lazy-loaded and kept resident exactly as the pre-fleet single-model lifecycle, with no eviction step

### Requirement: 48 GB residency and eviction is computed by a pure planner

The system SHALL decide which models can co-reside and which must be evicted with a **pure residency planner** that, given the fleet descriptors, the unified-memory budget, the currently free memory, and a target model, produces a plan naming exactly which models to **admit**, which to **evict**, and which **co-reside** — before any weights move. The chat model (GPU lane), the ternary model (CPU lane), a quantized (Q4) image model, and the live KV reservation SHALL be able to co-reside within the budget. Admitting a **video** model or a full-precision (FP16) image model that cannot fit alongside the chat model SHALL evict the chat model (the assistant goes quiet while it generates), without evicting the CPU-lane ternary model. Cloud models SHALL never be planned for residency. A target that cannot fit even after evicting every evictable on-device model SHALL be reported as a clean admission failure, not loaded silently and not left in a false "loaded" state.

#### Scenario: Q4 image co-resides with chat, ternary, and KV
- **WHEN** the planner is asked to admit a quantized (Q4) image model with chat and ternary resident and KV reserved, within the budget
- **THEN** the plan admits the image model with no eviction and the co-resident set includes chat, ternary, the image model, and the KV reservation

#### Scenario: A heavy generation evicts chat
- **WHEN** the planner is asked to admit a video model (or an FP16 image model) that does not fit alongside the resident chat model
- **THEN** the plan evicts the chat model so the heavy model fits, leaves the CPU-lane ternary model resident, and the eviction is surfaced honestly to the user ("the assistant is busy painting"; chat reloads when generation finishes)

#### Scenario: A cloud target requires no residency
- **WHEN** the planner is asked to admit a `cloud`-provider model
- **THEN** the plan admits and evicts nothing (the cloud model is never resident locally)

#### Scenario: An infeasible admission fails cleanly
- **WHEN** a target cannot fit even after evicting every evictable on-device model
- **THEN** the admission reports a clean, bounded failure through the single error translator and the target is not loaded, rather than leaving a false "loaded" state

### Requirement: Cloud fleet members ride escalation and are off by default

The system SHALL register **Claude** and **GLM-5.2** as `cloud`-provider, `cloudEscalation`-role fleet members that are never resident locally (GLM-5.2's 753B-parameter / 1M-context scale does not fit the local budget; local is not an option). Selecting a cloud member SHALL route the turn through the existing Claude-handoff escalation path (confirm-by-default, per-day budget-capped, audited, fire-and-forget) rather than loading any local weights. The cloud tier SHALL be **off by default**: while cloud escalation is disabled, cloud members SHALL NOT be offered for selection and selecting one SHALL yield a clean "cloud disabled" failure rather than any network call or spend.

#### Scenario: Cloud members are never resident
- **WHEN** a cloud member is selected and the escalation tier is enabled
- **THEN** no local weights are loaded for it and the turn is routed through the existing Claude-handoff escalation path with its confirm/budget/audit gating

#### Scenario: Cloud is off by default with no silent spend
- **WHEN** cloud escalation is disabled and a cloud member is selected
- **THEN** the selection yields a clean "cloud disabled" failure, no network call is made, and no spend occurs

### Requirement: Fleet residency reuses the existing provisioner seam

The system SHALL apply a residency plan (evict then load) through the **existing** model-provisioner / runtime-factory seam — no new provisioning mechanism. The fleet planner SHALL decide *which* models to evict and admit; the existing lifecycle SHALL perform the eviction, the integrity-verified load, the keep-resident, and the per-model status update unchanged. A failure mapped at the layer boundary into the model-error taxonomy SHALL surface through the single error translator as a bounded, non-blocking message (never a modal alert, never raw error text in a headline), and a model that did not become resident SHALL be an observable failed state, never a false "loaded."

#### Scenario: Admission loads through the existing seam
- **WHEN** a plan names a target to admit and models to evict
- **THEN** the named models are evicted and the target is loaded through the existing provisioner / runtime-factory path, with the existing integrity-verify, keep-resident, and per-model status behavior intact

#### Scenario: A failed admission is observable, not silent
- **WHEN** an admission fails (infeasible residency, integrity failure, or unavailable hardware)
- **THEN** the model is reported as a failed state through the single error translator as a bounded, non-blocking message, and is never shown as a false "loaded"
