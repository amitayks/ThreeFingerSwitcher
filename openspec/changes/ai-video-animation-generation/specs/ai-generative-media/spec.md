## ADDED Requirements

> These requirements ADD the **video backend** behavior behind the `MediaRuntime` seam. The seam, the
> `MediaKind`/`MediaParameters`/`MediaRequest`/`MediaProgress`/`MediaAsset` value types, the
> `generate_video` tool descriptor, the `MediaGenSink`, and the Files-band / canvas output are ADDED by
> `ai-media-runtime` and are CONSUMED (not redefined) here. Every requirement below is video-backend
> behavior layered onto that seam.

### Requirement: Video generation is a MediaRuntime backend with a cloud-escalation default

The system SHALL provide video/animation generation as a concrete `MediaRuntime` backend advertising the `video` capability, selected by a persisted **video provider** setting. The default provider SHALL be **cloud escalation** (a hosted video API) and SHALL NOT download or run a local video model by default. The backend SHALL NOT introduce a second runtime seam, a second media tool, or a second output path: it SHALL plug into the existing `MediaRuntime` seam and the existing `generate_video` tool, and a later video backend (a different hosted provider, or a local one) SHALL join the SAME seam selected by the same provider setting, with no change to the tool, the executor/sink, the Files-band output, the canvas output, the gating, or the budget code.

#### Scenario: Default provider is cloud, nothing downloaded

- **WHEN** media generation is enabled and the user has not chosen a video provider
- **THEN** the active video backend is the cloud-escalation provider, and no local video weights are downloaded or made resident

#### Scenario: A second backend joins the same seam

- **WHEN** a later video backend is added and selected via the video provider setting
- **THEN** it conforms to the same `MediaRuntime` seam and advertises the `video` capability, and the `generate_video` tool, the sink, the Files-band and canvas output, the gating, and the budget code are unchanged

### Requirement: Cloud video is a dangerous-tier, budget-capped action mirroring the Claude handoff

When the video provider is the cloud escalation, the effective gate for `generate_video` SHALL be the **dangerous** write-policy tier — confirm-by-default per call — because real money is spent and bytes leave the device. The effective gate SHALL be the descriptor's dangerous tier intersected with the user's whitelist; the system SHALL enforce a **per-rolling-24-hour** call cap and a **maximum concurrent in-flight** cap over an append-only spend ledger that survives a relaunch within the window, keyed off an injected current time (NOT a calendar-day reset). A per-clip cap MAY tighten the global cap; a per-skill cap of zero SHALL fall back to the global default. A cloud video whose launch fails after a spend was recorded SHALL refund that spend so the cap stays honest. An over-budget call SHALL NEVER be silently dropped.

#### Scenario: Cloud video defaults to confirm at the dangerous tier

- **WHEN** `generate_video` is selected with the cloud provider and no explicit auto opt-in
- **THEN** the call requires a foreground per-call approval before any upload or spend occurs, at the dangerous tier

#### Scenario: Under the cap a cloud video is allowed

- **WHEN** the number of cloud videos in the last 24 hours is below the cap and concurrency is below its limit
- **THEN** the generation is allowed to proceed (subject to its confirm/auto gate)

#### Scenario: Rolling window cannot be gamed across midnight

- **WHEN** cloud videos are spread across a calendar-day boundary but fall within the same rolling 24-hour window
- **THEN** they are counted together against the cap, with no midnight reset

#### Scenario: Cap survives a relaunch

- **WHEN** the process restarts within the rolling window
- **THEN** prior cloud videos inside the window still count against the cap and the budget is not reset

#### Scenario: A failed cloud launch refunds its spend

- **WHEN** a cloud video records a spend but its upload/launch then fails
- **THEN** the spend is refunded and the in-flight count is decremented, leaving the cap unchanged

### Requirement: Over-budget cloud video degrades, never runs unprompted

When a cloud video is over the budget cap, it SHALL degrade to a foreground per-call confirmation (in an active session) rather than running unprompted, and SHALL escalate to the needs-you badge (in a parked session) — it SHALL NOT auto-run over budget and SHALL NOT be silently dropped. The user, never the loop, SHALL be the only authority that can spend over the cap, and the approval surface SHALL indicate that the budget cap has been reached.

#### Scenario: Over budget in an active session degrades to confirm

- **WHEN** a cloud video is requested but the daily cap has been reached and the session is active
- **THEN** the request degrades to a foreground confirmation that states the budget cap was reached, and it does not auto-run

#### Scenario: Over budget in a parked session escalates

- **WHEN** a cloud video is over budget and the session is parked
- **THEN** the request escalates to a needs-you badge for the user to decide, and no upload or spend occurs until the user returns and approves

### Requirement: Cloud video discloses that bytes leave the device and the cost

Because cloud video sends the prompt and any seed frame to a remote service, the confirmation surface SHALL state that the bytes leave the device and the per-clip cost order, before any upload occurs. The disclosure SHALL be derived from a pure value (does-bytes-leave plus a redacted summary) so it is testable without network. A local video backend SHALL set the does-bytes-leave flag false (nothing is uploaded).

#### Scenario: Cloud confirm states the upload and cost

- **WHEN** a cloud video awaits confirmation
- **THEN** the confirmation surface states that the prompt and any seed image will be sent to the remote service and indicates the per-clip cost order

#### Scenario: Local video does not claim an upload

- **WHEN** the active video provider is local
- **THEN** the does-bytes-leave flag is false and no upload disclosure is presented

### Requirement: Every video attempt is audited with a redacted summary

Every video attempt — confirmed, auto, declined, failed, or over-budget, for the cloud OR the local provider — SHALL emit exactly one append-only audit record naming the tool, the policy tier, a redacted/short argument summary (the provider, a truncated prompt, and a flag for whether a seed image was sent — NEVER the full prompt verbatim, NEVER the raw seed bytes), the outcome, whether it ran in the background, and a timestamp. The audit SHALL route into the single shared audit log rather than a separate video-only log. Raw prompt text and raw seed bytes SHALL appear only in logs or behind an opt-in details disclosure, never in the audit summary or any headline.

#### Scenario: One audit record per video attempt

- **WHEN** any `generate_video` attempt resolves (done, declined, failed, or over-budget)
- **THEN** exactly one audit record is appended naming the tool, the tier, the redacted argument summary, the outcome, the background flag, and a timestamp

#### Scenario: The audit summary never carries the full prompt or raw seed

- **WHEN** an audit record for a video attempt is inspected
- **THEN** its argument summary contains the provider, at most a truncated prompt, and a seed-present flag, and neither the full prompt text nor the raw seed bytes are present

### Requirement: Local LTXV video is a frontier backend behind the master full-potential toggle

The local LTXV video backend SHALL be selectable ONLY when the master full-potential toggle AND media generation are both enabled. It SHALL NOT be downloaded, made resident, or selectable by default. Selecting it SHALL disclose, in the same breath it is offered, its residency cost (tens of gigabytes), its minutes-per-clip latency, that a video generation EVICTS the chat model (the assistant goes quiet while it paints, per the fleet residency decision), and its thermal cost. Local video SHALL NOT consume the cloud spend ledger or the cloud budget cap (no money is spent), but it SHALL still be audited and SHALL still park because it is slow.

#### Scenario: Local LTXV requires the master toggle

- **WHEN** the master full-potential toggle is off
- **THEN** the local LTXV provider is not selectable and is not downloaded, and the cloud provider remains the only video backend

#### Scenario: Selecting local LTXV discloses its cost

- **WHEN** the user selects the local LTXV provider with the master toggle on
- **THEN** the selection discloses the tens-of-gigabytes residency, the minutes-per-clip latency, that chat is evicted while it generates, and the thermal cost

#### Scenario: Local video is audited and parks but spends no budget

- **WHEN** a local LTXV video is generated
- **THEN** it emits one audit record and parks while it runs, and it consumes no cloud spend ledger entry and no cloud budget cap

### Requirement: img2video from the seed, fire-and-forget with step progress

A video generation SHALL consume the optional seed image carried on the request (a PNG — the screen-region or clipboard capture) as the first frame for image-to-video, and SHALL also support a prompt-only generation when no seed is provided. Because the job is minutes-long, it SHALL be fire-and-forget with progress: it SHALL stream diffusion/render step progress (optionally with a preview frame) and SHALL end in a finished media asset whose kind is video and whose duration is set. The slow job SHALL park via the park scheduler so it runs in the background, and the completion (or a needs-you state) SHALL surface on the notch. The finished clip SHALL land as a Files-band asset and a canvas player, and a swipe-down SHALL extract it per the canonical two-finger compass.

#### Scenario: A seed image becomes the first frame

- **WHEN** `generate_video` is run with a seed PNG
- **THEN** the seed is used as the first frame for image-to-video and the upload disclosure flags that a seed image was sent

#### Scenario: Progress streams then finishes as a video asset

- **WHEN** a video generation runs
- **THEN** it streams step progress (optionally with a preview) and ends in a finished media asset whose kind is video and whose duration is set, which lands as a Files-band asset and a canvas player

#### Scenario: A slow video parks and glows on completion

- **WHEN** a video generation is dispatched
- **THEN** it parks so it runs in the background, and on completion (or when it needs the user) the notch surfaces it

#### Scenario: Swipe-down extracts the finished clip

- **WHEN** a finished video is shown in the canvas player and the canvas is at the top
- **THEN** a two-finger swipe-down extracts the clip (save / paste / set-as), per the canonical compass

### Requirement: Video failures surface bounded and non-blocking through the one translator

Video backend failures SHALL map at the layer boundary into the shared media error taxonomy (vendor/OS errors — the hosted API's network errors, the local ComfyUI/process errors, over-budget, provider-disabled, upload-declined — converted where they cross into app code) and SHALL surface through the single media error→message translator, bounded and non-blocking. A failure SHALL NEVER be presented via an app-modal alert and SHALL NEVER place raw OS or vendor error text in a headline (raw text is allowed only in logs or behind an opt-in details disclosure). A video that did not produce a written clip SHALL become an observable failed state carrying a clean headline — never a false "Done" — and, for the cloud provider, its spend SHALL be refunded. A user discard during approval SHALL end the loop quietly with no upload, no spend, and SHALL NOT be reported as a failure.

#### Scenario: A failed upload surfaces a clean failed state

- **WHEN** a cloud video upload or poll fails
- **THEN** the generation is reported failed with a clean headline, the spend is refunded, and no app-modal alert appears

#### Scenario: A failed local render surfaces a clean failed state

- **WHEN** the local LTXV process fails to produce a clip
- **THEN** the generation is reported failed with a clean headline (not a false Done), and no app-modal alert appears

#### Scenario: No raw error text in a headline

- **WHEN** any video failure is presented
- **THEN** the headline is a clean, human-readable message and any raw OS/vendor error text appears only in logs or behind an opt-in details disclosure

#### Scenario: Discard during approval is quiet, not a failure

- **WHEN** the user discards the canvas while a video generation awaits approval
- **THEN** the loop ends quietly, nothing is uploaded, no spend occurs, and it is not reported as a failure
