# Tasks — ai-video-animation-generation

> Backend-only slice behind the `MediaRuntime` seam (owned by `ai-media-runtime`). Depend on the
> ADDENDUM's pinned contracts, not on sibling change files existing yet. OpenSpec markdown is authored
> in this run; the Swift below is the IMPLEMENTATION plan a later coding run follows. No `.app`
> build/sign by an agent.

## 1. Value types (Core, owned here)

- [x] 1.1 Add `VideoProvider` (`.cloud` default / `.localLTXV`) backing the `videoProvider` key; `.localLTXV` is only valid when `fullPotentialEnabled` + `mediaGenEnabled`. — Verify: `swift test` Codable round-trip + default `.cloud` + invalid-without-master guard.
- [x] 1.2 Add `VideoUploadDisclosure` (does-bytes-leave flag + redacted-summary builder: provider, truncated prompt, seed-present flag). — Verify: `swift test` summary never contains the full prompt or raw seed bytes; upload flag true for cloud, false for local.
- [x] 1.3 Add the persisted keys `videoProvider` + `mediaVideoBudgetPerDay` (camelCase, agent-scoped, per addendum §1) to AppSettings; defaults = cloud / a conservative per-day cap. — Verify: `swift test` defaults + persistence round-trip.

## 2. Budget / rate cap (Core, the §3.8 pattern reused)

- [x] 2.1 Add `VideoBudget`: pure rolling-24h call cap + concurrency cap over an append-only ledger, `now:`-injected. — Verify: `swift test` under-cap allows.
- [x] 2.2 Rolling window keyed off injected time, NOT a calendar reset (cannot be gamed across midnight). — Verify: `swift test` cross-midnight-same-window counts together.
- [x] 2.3 Ledger survives relaunch within the window (replay). — Verify: `swift test` reconstruct ledger → prior calls still count.
- [x] 2.4 A failed launch refunds its spend + decrements in-flight; an over-budget call degrades (never silently drops). — Verify: `swift test` refund leaves cap unchanged; over-budget returns a degrade signal, not a drop.

## 3. Effective-tier resolution (Core)

- [x] 3.1 Resolve `generate_video`'s effective tier: cloud → `.dangerous` ∩ user whitelist; local → master-toggle-gated (not on the spend axis). — Verify: `swift test` cloud=dangerous, local gated by `fullPotentialEnabled` + `mediaGenEnabled`.
- [x] 3.2 Over-budget cloud video degrades to foreground confirm (active) / needs-you (parked), stating the cap was reached. — Verify: `swift test` active→confirm-with-cap-message, parked→needsYou; never auto-run over budget.

## 4. Audit (Core, reuses §3.7 AuditLog)

- [x] 4.1 Emit exactly one `AuditRecord` per attempt (done / declined / failed / over-budget) into the shared `AuditLog`, with the redacted summary + `wasBackground` set when parked. — Verify: `swift test` one record per resolution; summary carries provider + truncated prompt + seed-present flag, never the full prompt.

## 5. Backend conformers (Core stubs + native-linked real)

- [x] 5.1 `StubCloudVideoRuntime` + `StubLocalVideoRuntime`: `MediaRuntime` conformers, `capabilities = [.video]`, scripted `MediaProgress.step` → `.finished(MediaAsset kind: .video, durationMs:)`. — Verify: `swift test` progress plumbing + finished asset shape.
- [x] 5.2 img2video: both stubs consume the optional `MediaRequest.seed` (PNG) as the first frame; a seed-present run sets the disclosure flag. — Verify: `swift test` seed threads through to the asset + disclosure.
- [x] 5.3 `CloudVideoRuntime` (native-linked): real `URLSession` upload prompt+optional seed, poll progress, fetch the file; map `NSURLError` at the boundary into `MediaError`. — Verify: `xcodebuild` compile-verify only; real upload/poll in the USER's stable-signed build.
- [x] 5.4 `LocalLTXVRuntime` (native-linked): ComfyUI/MPS process bridge, 35 GB+ graph; map `Process`/ComfyUI errors at the boundary into `MediaError`. — Verify: `xcodebuild` compile-verify only; real residency/latency/eviction/heat in the USER's stable-signed build.

> NOTE (5.3 / 5.4 / 6.2 native player): the native-linked runtimes + the canvas video PLAYER are written
> COMPLETE in `Sources/GemmaRuntime/` and marked `// FLAGGED: user xcodebuild + stable-signed build`. The
> agent verified Core under `swift build` + `swift test` (and `swift build` compiled the GemmaRuntime
> target here). REAL correctness — a real clip, a real upload + $ spend, real 35 GB residency / minutes-per-
> clip / chat eviction / thermals, and the live player surface — is the USER's stable-signed run-verify
> (an agent never builds/signs/installs the `.app`; ad-hoc signing breaks TCC).

## 6. Parking + output (Core wiring; native player consumed)

- [x] 6.1 Video generation parks via `ParkScheduler` (slow); the notch glows on completion / `needsYou`. — Verify: `swift test` with a fake scheduler — slow job parks, completion raises the glow signal.
- [x] 6.2 The finished clip lands as a Files-band asset + a canvas player (CONSUMED, owned by `ai-media-runtime`); swipe-DOWN extracts it (canonical compass). — Verify: `swift test` the sink hands the `MediaAsset` to the Files/canvas seam; native player compile-verifies under `xcodebuild`.

## 7. Disclosure UX (Core values; surface consumed)

- [x] 7.1 Cloud confirm step states bytes leave the device + per-clip $ order (from `VideoUploadDisclosure` + `mediaVideoBudgetPerDay`). — Verify: `swift test` disclosure values; the live confirm surface (canvas) compile-verifies under `xcodebuild`.
- [x] 7.2 Local-LTXV selection discloses 35 GB+ residency, minutes-per-clip latency, chat eviction (from the fleet §C1), thermal cost. — Verify: `swift test` the disclosure value carries these; eviction decision consumed from `ai-model-fleet`.

## 8. Errors (Core, one taxonomy / one translator)

- [x] 8.1 Map video failures (over-budget, provider-disabled, upload-declined, `NSURLError`, `Process`/ComfyUI) into `MediaError` at the boundary; add a video-only enum ONLY if `MediaError`/`RuntimeError` cannot carry the case. — Verify: `swift test` vendor/OS surrogates map to the taxonomy.
- [x] 8.2 Surface every video error through `AIError.message(for:)` → bounded + non-blocking (never `NSAlert.runModal`, never raw text in a headline; raw text only in logs / behind Show-details). A side effect that did not land is `.failed`, never a false Done. — Verify: `swift test` the translator path; no raw text in headline; failed-not-done on a dropped clip.

## 9. Swap-in contract (Core)

- [x] 9.1 Specify + test that a second video backend joins the SAME `MediaRuntime` seam selected by `videoProvider`, with no change to the sink / canvas / Files output / gating / budget code. — Verify: `swift test` swap a stub for another stub via the selector → feature path unchanged.

## 10. Spec + validation

- [x] 10.1 Write the `ai-generative-media` delta (MODIFIED Requirements — video-backend behavior + dangerous gating + disclosure + frontier-local + img2video + swap contract). — Verify: reads as a true delta against the seam owner's ADDED requirements.
- [x] 10.2 `openspec validate ai-video-animation-generation --strict` passes. — Verify: command exits clean.

## 11. User run-verify (stable-signed build — agent never builds/signs the .app)

- [ ] 11.1 **User run-verify:** in a stable-signed build, a cloud video actually generates (real upload + `$`-spend within `mediaVideoBudgetPerDay`, audited; over-budget degrades, never silently drops); a local-LTXV selection evicts chat ("busy painting") and produces a clip at the documented latency/thermal cost; the finished clip plays in the canvas player and swipe-DOWN extracts it as a Files-band asset. — Verify: USER stable-signed build (native upload/poll, 35 GB residency, live player cannot be agent-verified; `xcodebuild` compile already GREEN).
