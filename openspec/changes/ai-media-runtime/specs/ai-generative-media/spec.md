## ADDED Requirements

### Requirement: Generative media uses a second runtime seam parallel to the text runtime
The system SHALL generate media (images and video) through a **dedicated media runtime seam** that is
**parallel to**, not part of, the text (`LLMRuntime`) seam. The media seam SHALL model a generation as a
**long asynchronous job with step progress that ends in a file** — a progress stream that emits
diffusion-step progress (with an optional intermediate preview frame) and terminates in a finished media
asset — rather than a language-token stream. A media generation request SHALL carry a prompt, a kind
(image or video), generation parameters (size, steps, optional RNG seed number, optional guidance,
video-only duration), and an **optional seed image** for image-to-image / image-to-video. The seam SHALL
declare which kinds it can produce, so the system never requests a kind a runtime cannot serve. The
concrete generation backend SHALL be swappable behind this seam without changing any feature code (exactly
as the text runtime is swappable), so this capability owns the seam, not the weights.

#### Scenario: A generation is a progress-bearing async job ending in a file
- **WHEN** a media generation runs
- **THEN** it streams diffusion-step progress (optionally with an intermediate preview frame) and ends by
  producing a finished media asset that references a written file, not a stream of language tokens

#### Scenario: The seam advertises its kinds
- **WHEN** the system considers a media generation of a given kind
- **THEN** it checks the runtime's advertised capabilities and does not request a kind the runtime cannot
  produce

#### Scenario: A different backend drops in without feature changes
- **WHEN** a different generation backend conforms to the media seam
- **THEN** the tools, executor, and output paths use it unchanged, just as a different text model would be
  swapped behind the text seam

### Requirement: generate_image and generate_video are routed tools with write-policy tiers
The system SHALL expose media generation to the agent as **tools** — `generate_image` and
`generate_video` — registered in the tool registry through the same contributor mechanism as every other
tool, each advertising its name, a one-line summary, an arguments schema (prompt, size, steps, an optional
seed-image handle, and a video duration), and a **write-policy tier**. Image generation SHALL ship the
**confirm** tier; cloud video generation SHALL ship the **dangerous** tier and SHALL additionally be
**budget-capped** (a per-day cap mirroring the Claude-handoff cost gate). The model SHALL invoke media
generation only by routing to one of these tools, never by a separate control path. A media tool whose
backing runtime cannot serve the kind — or, for video, has no configured provider or no remaining budget —
SHALL be **omitted from the route candidates**, so the router never routes to an unavailable generator.

#### Scenario: Image generation is a confirm-tier tool
- **WHEN** the `generate_image` tool is registered
- **THEN** it carries the confirm write-policy tier and is offered to the router like any other tool

#### Scenario: Cloud video is a dangerous, budget-capped tool
- **WHEN** the `generate_video` tool backed by a cloud provider is registered
- **THEN** it carries the dangerous write-policy tier and a per-day budget cap, mirroring the Claude-handoff
  cost gate

#### Scenario: An unavailable generator is not a route candidate
- **WHEN** no runtime can produce the requested kind, or the video provider/budget is unavailable, or media
  generation is disabled
- **THEN** the corresponding media tool is omitted from the route candidates and the model cannot route to it

### Requirement: A media generation is executed by a sink driven by the route loop
The system SHALL execute a routed media generation with a **media generation sink** invoked by the existing
route → execute → continue loop (the same loop that runs every other tool), not by a bespoke control flow.
Before any compute or spend, a media step whose **effective** write-policy tier requires confirmation
SHALL pause as an **awaiting-approval** step that surfaces the action review and resolves by the canonical
two-finger compass — **DOWN = approve / RIGHT = skip**. The effective tier SHALL come from the shared
write-policy resolver (the same seam every tool uses): a **dangerous** tier (cloud video) SHALL **never**
be lowered. On approval the sink SHALL resolve the seed, select the runtime for the kind, drive the
generation, write the finished asset, and return a tool-step result — **done** carrying the asset's gallery
location, **skipped/declined** with no side effect, or **failed** with a clean headline. A side effect that
did not land (a generation that failed, or an asset that could not be written) SHALL be reported **failed**,
never a false success. **Cancellation** (a discarded generation) SHALL be a distinct outcome, **not** a
failure.

#### Scenario: A side-effecting media step waits for a DOWN approval before compute
- **WHEN** the model routes to a media tool whose effective tier requires confirmation
- **THEN** the step pauses showing the review, and no compute or spend happens until the user approves with
  a DOWN swipe (a RIGHT skip applies nothing and feeds back so the model may continue)

#### Scenario: Cloud video's dangerous tier is never lowered
- **WHEN** the write-policy resolver evaluates a cloud `generate_video` step
- **THEN** its effective tier stays dangerous and is never lowered to auto by any whitelist

#### Scenario: A finished generation returns done with the asset location
- **WHEN** an approved generation finishes
- **THEN** the sink returns a done result carrying the asset's gallery location, fed back into the loop

#### Scenario: A failed generation is reported failed, never a false success
- **WHEN** a generation fails or its asset cannot be written
- **THEN** the step is reported failed with a clean headline and no false "saved" is reported

#### Scenario: A cancelled generation is not a failure
- **WHEN** the user discards an in-flight generation
- **THEN** the step ends as cancelled, not failed, and leaves no failed indicator

### Requirement: The cloud-video budget is enforced before any spend
The system SHALL enforce the cloud-video **per-day budget/rate cap** **before** invoking the cloud
provider, so an exhausted budget produces a clean declined/failed outcome with **no network call and no
spend**. The cap SHALL reuse the Claude-handoff cost-gate pattern (confirm-by-default, per-day cap,
audited) rather than a parallel mechanism. Exceeding the cap SHALL be an observable, bounded outcome, never
a silent spend and never a silent refusal.

#### Scenario: An exhausted budget refuses before spending
- **WHEN** the cloud-video budget for the day is exhausted and the model routes to `generate_video`
- **THEN** the step resolves as budget-exhausted before any network call, with no spend, surfaced as a
  bounded, clean outcome

#### Scenario: The cap is audited like the handoff cost gate
- **WHEN** a cloud-video step runs or is refused on budget
- **THEN** it is recorded in the shared audit log with its effective tier and a redacted argument summary,
  like the Claude-handoff cost gate

### Requirement: The seed (image-to-image / image-to-video) reuses the existing screen-region and clipboard captures
The system SHALL source a generation's **seed image** (its first frame for image-to-image / image-to-video)
from the **existing** capture inputs — the interactive screen-region picker and the on-demand live
clipboard image (normalized to PNG) — and SHALL NOT introduce a separate media-only picker. Copying an
image SHALL NOT auto-fire a generation (the clipboard read stays on-demand). A media tool authored to
require a seed that has **no resolvable seed** SHALL resolve as **failed (seed required)**, and an
**undecodable** seed SHALL resolve as **failed (seed invalid)** — never a fabricated blank first frame.

#### Scenario: A captured region becomes the first frame
- **WHEN** the user supplies a screen-region or clipboard image as the seed for an image-to-image / image-to-video generation
- **THEN** that image is wired as the request's seed/first frame using the existing capture inputs, with no
  new picker

#### Scenario: Copying an image never auto-fires a generation
- **WHEN** an image is on the clipboard
- **THEN** no generation fires automatically; the clipboard image is read only on demand when used as a seed

#### Scenario: A missing or invalid required seed fails cleanly
- **WHEN** a generation requires a seed but none is resolvable, or the seed cannot be decoded
- **THEN** the step resolves as failed (seed required / seed invalid) with a clean headline and no compute,
  never a fabricated blank frame

### Requirement: A finished asset lands as a Files-band gallery entry
The system SHALL write each finished media asset to a dedicated **generated-media gallery** location and
SHALL surface it as an ordinary **Files-band entry** (the gallery), reusing the Files band's on-demand
listing, open / Open-With, and contextual delivery rather than building a new browser. The gallery location
SHALL be **local-only** and the asset SHALL be **durable** (it survives relaunch and survives discarding the
canvas preview). The asset's entry SHALL carry a **path-stable identity** so re-listing does not strobe the
selection. The gallery SHALL honor the Files band's non-destructive scope (no permanent delete, no
overwrite).

#### Scenario: A generated asset appears in the Files-band gallery
- **WHEN** a generation finishes
- **THEN** its file is written under the generated-media gallery and appears as a Files-band entry that can
  be opened, opened-with, and delivered

#### Scenario: The gallery asset is durable and local-only
- **WHEN** the app relaunches, or the canvas preview is discarded
- **THEN** the generated asset remains in the gallery (it is not lost) and the gallery reads only local
  files

#### Scenario: Re-listing the gallery does not strobe
- **WHEN** the gallery is re-listed
- **THEN** each generated asset keeps a stable identity by path and the highlight does not flicker

### Requirement: The canvas preview/player is resolved by the canonical compass
While a generation runs the system SHALL show a **live canvas preview** (step progress plus the
intermediate preview frame); on completion it SHALL show the finished image, or a **player** for video,
presented as a **non-activating** overlay (the Dock-preview overlay species) that never becomes the app's
key/main window and that tears down **synchronously**. The preview SHALL be resolved by the canonical
two-finger compass: **DOWN — only when the canvas is at its top — extracts** the result (save / paste /
set-as); **RIGHT discards** the preview. Because the asset is already durably in the gallery, a discard
SHALL only dismiss the preview and SHALL NOT lose the file. A sub-threshold two-finger scroll SHALL NOT
resolve the preview (the resolve excursion sits above incidental scroll). The preview SHALL NOT continuously
screen-record; an in-progress preview is the runtime's last step frame and a finished video plays from its
file.

#### Scenario: Generating shows live progress
- **WHEN** a generation is running
- **THEN** the canvas shows step progress and the latest intermediate preview frame

#### Scenario: DOWN at the top extracts the result
- **WHEN** the finished preview is shown, the canvas is at its top, and the user swipes two-finger down past
  the resolve threshold
- **THEN** the result is extracted (save / paste / set-as)

#### Scenario: RIGHT discards but keeps the file
- **WHEN** the user swipes two-finger right past the resolve threshold on a finished preview
- **THEN** the preview dismisses and the asset remains in the gallery (the file is not lost)

#### Scenario: The preview panel never steals focus and tears down synchronously
- **WHEN** the preview/player is shown and later dismissed
- **THEN** it never becomes the app's key/main window, the foreground app keeps focus, and the panel is
  ordered out synchronously

#### Scenario: Sub-threshold scroll does not resolve
- **WHEN** the user makes a small two-finger scroll below the resolve threshold over the preview
- **THEN** the preview is not resolved (reading it never extracts or discards it)

### Requirement: Generation is slow, so the session parks while it paints
Because a media generation is slow, the system SHALL let the session **park** (via the existing parked-
session machinery and notch home zone) while it generates, and SHALL feed the parked machinery the job's
observable state rather than re-implementing it. A parked session that is generating SHALL show the
**thinking** badge; on completion it SHALL show the **done** badge with the unseen-result count and the
notch SHALL **glow**; a **dangerous** cloud-video step on a parked session SHALL **escalate to needs-you**
(via the scheduler) with a clean one-line reason and the ambient notch glow. A **cancellation** SHALL NOT
leave a failed badge. The scheduler SHALL decide scheduling; this capability SHALL only report advance and
escalation.

#### Scenario: A generating parked session shows the thinking badge
- **WHEN** a session is parked while its generation runs in the background
- **THEN** its rail card shows the thinking badge

#### Scenario: A finished generation glows the notch with an unseen-result count
- **WHEN** a parked session's generation finishes
- **THEN** its card shows a done badge with the unseen-result count and the notch home zone glows

#### Scenario: A parked dangerous cloud-video step escalates to needs-you
- **WHEN** a parked session reaches a dangerous cloud-video step
- **THEN** it escalates to needs-you with a clean one-line reason and the ambient notch glow, rather than
  spending in the background

#### Scenario: A cancelled parked generation leaves no failed badge
- **WHEN** a parked session's generation is discarded
- **THEN** it ends as cancelled and leaves no failed badge

### Requirement: A heavy generation evicts chat and says so honestly
The system SHALL be honest that a heavy generation **evicts chat** under the device memory budget: when the
model fleet's residency decision requires evicting the chat model to run the generation, the system SHALL
surface a calm "**the assistant is busy painting**" state rather than pretending the chat and the
generator co-reside, and chat SHALL resume when the generation finishes or parks. The system SHALL NOT
silently queue chat behind the generation with no signal (which would read as a hang) and SHALL NOT refuse a
generation merely to keep chat resident.

#### Scenario: A generation that must evict chat surfaces a busy-painting state
- **WHEN** running a generation requires evicting the chat model under the memory budget
- **THEN** the system shows a calm "busy painting" state and chat resumes when the generation finishes or
  parks

#### Scenario: Chat is never silently starved
- **WHEN** a generation is occupying the GPU
- **THEN** the chat unavailability is surfaced (busy painting), never left as an unexplained hang

### Requirement: Media failures use one taxonomy, mapped at the boundary, surfaced bounded and non-blocking
All media-generation failures SHALL be classified into the shared error taxonomy — reusing the existing
runtime/task errors plus at most one media-specific error type for the cases they cannot carry (no capable
backend, seed required/invalid, generation failed, output-write failed, cloud budget exhausted, cloud
unavailable) — mapped into that taxonomy **at the layer boundary** (where vendor/OS errors from the
generation backend, process spawn, network, or filesystem cross into app code). Every media failure SHALL
be surfaced through the single error translator as a **clean headline with opt-in copyable details**, as a
**bounded, non-blocking** observable failed state — **never** an app-modal alert, **never** raw error text
in a headline. **Cancellation SHALL be distinct from failure.** Every terminal media outcome (done,
declined, escalated, failed, cancelled) SHALL be observable; a media step SHALL NEVER end silently.

#### Scenario: A backend error maps to a clean headline
- **WHEN** the generation backend, a process spawn, the network, or the filesystem throws
- **THEN** the error is mapped at the boundary into the media error taxonomy and surfaced as a clean
  headline with opt-in details, bounded and non-blocking — never an app-modal alert, never raw error text
  in the headline

#### Scenario: Cancellation is not surfaced as a failure
- **WHEN** a generation is cancelled
- **THEN** the outcome is cancelled, distinct from a failure, and no failed message is shown

#### Scenario: No media step ends silently
- **WHEN** a media step terminates for any reason
- **THEN** it produces an observable outcome (done / declined / escalated / failed / cancelled), never
  silence
