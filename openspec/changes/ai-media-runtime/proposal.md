## Why

The V2 agent can route to **side-effecting tasks** (calendar/reminder/save/send) through the structured
route → execute → continue loop, and it can *read* a screen-region or clipboard image as **vision input**.
What it cannot yet do is **make** an image or a clip. That is a fundamentally different shape of work:
not a token stream that ends in a sentence, but a **long async job with step-progress that ends in a
file**. A diffusion run is minutes-not-seconds, GPU-saturating (it **evicts chat** under the 48 GB
budget — the fleet's decision, surfaced honestly here), and its result is a *thing on disk* the user
will want to keep, paste, or set somewhere — exactly the lifecycle the Files band already owns.

So generative media needs its **own runtime seam**, parallel to `LLMRuntime`, not bolted onto it. This
slice is `ai-media-runtime` (the new capability `ai-generative-media`). It owns that seam (`MediaRuntime`
+ the media value types from addendum §B1), the two **tools** that let the model invoke it
(`generate_image` / `generate_video` as `ToolDescriptor`s with their write-policy tiers), the
side-effecting **executor** (`MediaGenSink`) that the existing route loop runs, the **seed** path that
turns a captured screen-region / clipboard image into the first frame for img2img / img2video, and the
**output**: a Files-band gallery asset PLUS a canvas preview/player resolved by the canonical compass.
It does NOT own the concrete model backends — local image (mflux/FLUX) is `ai-local-image-generation`
and video (cloud-default / local-LTXV-frontier) is `ai-video-animation-generation`. Like `LLMRuntime`
lets Gemma be swapped, `MediaRuntime` is the swappable seam those backends drop into.

Honesty is a first-class requirement (the project's surface-the-cost ethos): media is **slow → it
parks** (via `ParkScheduler`, the notch glows on completion / needs-you); image generation is **`.confirm`**
and cloud video is **`.dangerous` + per-day budget-capped** (the Claude-handoff gating template); a heavy
gen says "the assistant is busy painting" rather than pretending co-residency; every failure is a clean,
bounded `.failed` card, never a false "Saved." and never an `NSAlert`.

## What Changes

- **A second runtime seam (`MediaRuntime`, addendum §B1, Core).** A protocol parallel to `LLMRuntime`:
  `capabilities: Set<MediaKind>` and `generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error>`.
  The progress stream emits `.step(index:total:preview:)` (streamed diffusion progress + an optional
  intermediate preview frame) and terminates in `.finished(MediaAsset)`. Defined VERBATIM from §B1; a
  `StubMediaRuntime` makes the whole slice `swift test`-verifiable without weights. The concrete backends
  conform to this seam in their own slices.
- **The media value types (addendum §B1, Core), owned here:** `MediaKind` (`.image`/`.video`),
  `MediaParameters` (size/steps/seed-number/guidance/durationMs), `MediaRequest` (prompt + optional
  **seed image** `Data?` for img2img/img2video + kind + parameters), `MediaProgress`
  (`.step`/`.finished`), `MediaAsset` (id/url/kind/width/height/durationMs — `Codable`, becomes a
  Files-band entry). A `MediaSize` width×height value type.
- **`generate_image` + `generate_video` as `ToolDescriptor`s registered in the `ToolRegistry`** (the
  tool-routing seam, blueprint §3.3 / addendum §B1). Each advertises its name + summary + an
  `argsSchema` (prompt, size, steps, optional seed-image-handle, video duration) and its
  `WritePolicyTier`: **image `.confirm`**, **cloud video `.dangerous`** (+ budget cap). Contributed via the
  existing `ToolContributor` seam — no route-loop change. A descriptor whose backing `MediaRuntime` does
  not advertise the kind (or, for video, has no provider/budget left) is **omitted from candidates**, so
  the router never routes to an unavailable tool.
- **`MediaGenSink` — the side-effecting executor run by the route → execute → continue loop.** When the
  router selects `generate_image`/`generate_video`, the loop dispatches to `MediaGenSink`, which: resolves
  the seed (below), picks the `MediaRuntime` for the kind, drives `generate(_:)`, threads
  `MediaProgress` into the live UI, writes the finished `MediaAsset` to the gallery folder, and returns a
  `ToolStepResult` (`.done` carrying the asset's gallery path, or `.failed` with a clean headline). It
  obeys write-policy: `.confirm`/`.dangerous` steps surface a `TaskReview`-backed **awaiting-approval**
  step (DOWN = approve / RIGHT = skip) BEFORE any compute or spend.
- **The seed (img2img / img2video) path.** A `MediaRequest.seed: Data?` (PNG). The capture sources are
  the EXISTING `.screenRegion` (interactive region picker) and `.clipboardImage` (live pasteboard,
  normalized to PNG) inputs — reused, not reinvented. The sink wires the captured/clipboard image as the
  request's seed/first frame; a missing-but-required seed (a tool authored as img2img) is a clean
  `.failed`, not a fabricated blank frame.
- **Output #1 — a Files-band gallery asset.** The finished `MediaAsset.url` is written under a dedicated
  **generated-media gallery** root and surfaces as an ordinary `.fileEntry` in the Files band (reuse the
  band's on-demand listing + lift-to-open + Open-With + contextual-delivery — no new browser). The
  gallery root is local-only and recoverable, honoring the band's non-destructive scope.
- **Output #2 — a canvas preview/player resolved by the compass.** While generating, the canvas shows
  live step-progress + the intermediate preview; on finish it shows the image / a **player** for video
  (the `DockPreviewOverlay` non-activating, synchronous-`orderOut` overlay species). A two-finger
  **DOWN** extract (only at canvas top) resolves it — **save / paste / set-as** — per the canonical
  compass; **RIGHT** discards; the result is already durably in the gallery so discard never loses it.
- **Parked-while-generating.** Because a gen is slow, the session **parks** via the existing
  `ParkScheduler`: the canvas overscroll-park stashes it to the notch home zone, the card shows a
  **thinking** badge while it paints, the notch **glows** on completion (a done badge) or on `needsYou`
  (a `.dangerous` cloud-video escalation). The scheduler/rail/glow are reused from `ai-parked-sessions`;
  this slice only feeds them the media job's observable state.
- **`MediaError` taxonomy, mapped at the boundary.** One new `enum MediaError: Error, Equatable`
  (`LocalizedError`) for media-specific failures the shared `RuntimeError`/`TaskError` cannot carry
  (no capable backend, seed required/invalid, generation failed/cancelled-distinct, output-write failed,
  cloud budget exhausted). Vendor/OS errors (mflux/LTXV/ComfyUI, `Process`, `NSURLError`, `FileManager`)
  map into it at the layer boundary; everything routes through the single `AIError.message(for:)`
  translator and surfaces **bounded + non-blocking** — never `NSAlert`, never raw error in a headline.

## Capabilities

### New Capabilities

- `ai-generative-media`: the on-device (image) / escalated (video) generative-media capability — the
  `MediaRuntime` seam parallel to `LLMRuntime`, the `generate_image`/`generate_video` tools and their
  write-policy tiers, the `MediaGenSink` executor driven by the route loop, the seed (img2img/img2video)
  path fed by the screen-region / clipboard capture, the output as a Files-band gallery asset plus a
  compass-resolved canvas preview/player, the parked-while-generating lifecycle, and the `MediaError`
  taxonomy. This capability OWNS the seam, tools, sink, and output; the concrete backends are separate
  capabilities (`ai-local-image-generation`, `ai-video-animation-generation`).

### Modified Capabilities

- `ai-command-tasks`: the `ToolRegistry` now additionally aggregates **media** tools
  (`generate_image`/`generate_video`) through the SAME `ToolContributor` seam, and the route →
  execute → continue loop additionally dispatches a routed media call to `MediaGenSink` (a long async
  job ending in a file, not a token stream), reusing the existing per-step write-policy gate
  (DOWN=approve / RIGHT=skip) and the `.done`/`.failed`/`.declined` mapping. No new control flow — media
  is just another contributor + sink. (Delta authored against `ai-command-tasks`.)

## Impact

- **Code (MLX-free Core, `AI/Media/`):** new `MediaRuntime` protocol; `MediaKind`, `MediaSize`,
  `MediaParameters`, `MediaRequest`, `MediaProgress`, `MediaAsset` value types (addendum §B1 verbatim);
  `StubMediaRuntime` (scripted progress, for `swift test`); the `MediaToolContributor` exposing the two
  `ToolDescriptor`s with their `WritePolicyTier`; `MediaGenSink` (the route-loop executor — pure
  orchestration over an injected `MediaRuntime`, a seed provider, and a gallery writer); the seed
  resolution (reusing the existing `.screenRegion`/`.clipboardImage` capture seams); the gallery-asset
  writer + the `.fileEntry` surfacing; the canvas preview-state model; the parked-session feed; the
  `MediaError` enum + its boundary mapping. All verified by `swift build` + `swift test` against
  `StubMediaRuntime` with scripted progress (success, intermediate previews, mid-flight failure,
  cancellation, missing seed, budget-exhausted).
- **Native-linked (`xcodebuild` COMPILE-VERIFY ONLY for an agent; real correctness needs the user's
  stable-signed build):** the **canvas media player overlay** (the non-activating `DockPreviewOverlay`-
  pattern panel rendering the image / playing the clip). The concrete diffusion backends are NOT in this
  slice. An agent never builds/signs/installs the `.app` (ad-hoc signing breaks TCC; the `*.bundle`
  metallib copy in `build-app.sh` must not regress).
- **Reuse, not rebuild:** the `ToolRegistry`/`ToolContributor`/route loop + `WritePolicyTier`
  (`ai-tool-routing`); `TaskReview`/`PreparedAction` for the approval step; `WritePolicyResolving` +
  `AuditLog` (`ai-background-autonomy`); `ParkScheduler`/notch rail/glow (`ai-parked-sessions`); the
  files band's listing + open + Open-With + delivery (`files-band` / `files-contextual-delivery`); the
  `.screenRegion`/`.clipboardImage` capture seams (`screen-region-picker`); `BubbleMorph`; the
  `DockPreviewOverlay` overlay species; `AIError.message(for:)`/`AIPresentedError`.
- **Consumes from siblings (addendum):** `ModelRegistry`/`ModelDescriptor` (`ai-model-fleet`) to pick the
  resident image/video runtime and to learn that **a heavy gen evicts chat**; `fullPotentialEnabled` +
  `mediaGenEnabled` (`ai-full-potential-toggle`) gate the tools' registration and the capability's
  activation. This slice depends on the **addendum's pinned contracts**, not on sibling change files.
- **Out of scope (non-goals):** the concrete image backend (mflux/FLUX — `ai-local-image-generation`)
  and the concrete video backend (cloud LTX Studio default / local LTXV frontier —
  `ai-video-animation-generation`); the lane/residency/eviction math itself (`ai-compute-tiers`,
  `ai-model-fleet` — consumed, not owned); the master toggle UX page (`ai-full-potential-toggle`). This
  slice defines only the seam, tools, sink, and output those plug into.
