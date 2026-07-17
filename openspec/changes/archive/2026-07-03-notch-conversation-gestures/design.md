## Context

The recognizer already implements the fast-vs-soft discrimination this change needs (D4 of the canvas grammar): `trackCanvasResolution` accumulates per-axis peak centroid velocity and the timestamp of the last fast frame, and `resolveCanvasFlickOnLift` emits a resolve only when (a) dominant-axis travel crossed `canvasResolveThreshold`, (b) the dominant-axis peak crossed `settings.flickVelocityThreshold`, and (c) the lift arrived within `settings.flickLiftWindow` of the last fast frame. A soft scrub fails (b) or (c) and emits nothing. That machinery is gated by `launcherCanvasResolutionActive`, which **swallows every frame** while on (correct for a foreground modal canvas, wrong for the ambient notch — the switcher/launcher must keep working while a chat is open).

The notch conversation (from `notch-native-conversations`) is expanded/collapsed via `ParkController.expand/collapse`, deleted via the authoritative `discard(_:)`. The audit ledger (`ai-background-autonomy`) is spec-pinned **append-only**; records carry `sessionID`, live in an in-memory ring, and persist as JSON-lines (`DiskAuditLog`, atomic rewrite on every record, off-main writer queue).

Constraints: the concurrent fleet/media wave holds uncommitted edits in shared files; edits stay surgical. Core stays MLX-free; everything verifies under `swift test` except the live-feel flick tuning (user run-verify).

## Goals / Non-Goals

**Goals:**

- One flick classifier, two consumers — the canvas path's behavior is preserved bit-for-bit (existing tests keep passing).
- While a conversation is expanded: fast-flick-up = collapse-to-dock; fast-flick-right = purge-delete with no trace (store, row, engine, audit records, no log lines); soft two-finger motion = untouched native scroll; 3/4-finger gestures unaffected.
- The audit purge is a first-class, tested operation on all `AuditLog` implementations — not a file hack.

**Non-Goals:**

- No rail-mode gestures, no bindings/remap UI, no change to the canvas grammar or its thresholds, no new haptics, no changes to expiry/eviction, no media-artifact cleanup (that wave owns its store).

## Decisions

### D1 — Extract `FlickExcursionClassifier` (pure), don't duplicate the D4 math

A small value type owning the per-excursion state (`start`, per-axis peak velocity, last-fast time, last-contact time, last dx/dy, sawFastFrame) with two operations: `track(centroid:velocity:time:startIfNeeded:)` and `classifyOnLift(travelFloor:velocityThreshold:liftWindow:axisLockRatio:) -> Flick?` where `Flick` is `(dx: Int, dy: Int)` axis-locked (exactly one non-zero). `GestureRecognizer` keeps the routing policies; the canvas path and the notch path hold one classifier instance each. Alternative rejected: a parallel `notchRes*` state block (~60 duplicated lines whose constants would inevitably drift from the canvas's — the exact disease the one-translator error rule exists to prevent, applied to gesture feel).

Extraction fidelity is the risk; the guard is the existing `GestureRecognizerTests`/`CanvasResolveBindingTests` plus new classifier-direct unit tests (fast flick both axes, sub-threshold scrub, decelerated lift outside the window, travel under the floor).

### D2 — The notch mode routes two-finger frames only, and falls through otherwise

New `GestureRecognizer.notchConversationActive` flag (set by the coordinator from the expanded state). Routing in `feed(_:)`, in precedence order: `launcherCanvasResolutionActive` first (a foreground modal — unchanged), then `filesDrillActive` (unchanged), then the notch rule:

```
notchConversationActive?
  ├─ tracker already started, count == 0  → classify-on-lift → maybe emit; reset; return
  ├─ tracker already started, count >= 3  → reset tracker; FALL THROUGH (same frame may begin the switcher latch)
  ├─ count == 2                           → track (start if needed); return
  └─ otherwise                            → FALL THROUGH (0/1/3/4-finger frames belong to the normal machine)
```

So a two-finger excursion is watched (and, being watch-only, never consumed — the panel scrolls natively underneath), while a three/four-finger contact behaves exactly as with no conversation open. Emission is a new delegate method `notchConversationResolve(dx:dy:)` (mirroring `launcherCanvasResolve`), one-shot per excursion.

Edge worth pinning: a 2→3 finger morph mid-excursion resets the flick tracker and hands the frame to the normal latch — the user growing a switcher gesture out of a scroll must win.

### D3 — Grammar mapping lives at the coordinator seam (the recognizer stays dumb)

`AppCoordinator.notchConversationResolve(dx:dy:)`: `dy > 0` (fast UP) → `parkController.collapse()`; `dx > 0` (fast RIGHT) → `parkController.purge(expandedID)`; `dy < 0` and `dx < 0` → reserved no-ops. No at-top/at-bottom gates — the thread scrolls independently of the flick read, and collapse/purge are position-independent verbs.

The flag is driven by a new `ParkController.onExpandedChanged: ((Bool) -> Void)?`, fired on every `expandedID` nil↔value transition (newSession, expand, collapse, discard-of-expanded, feature-off) — the single choke point, so the recognizer can never be left stuck in notch mode after a collapse from any path.

### D4 — Purge = authoritative discard + audit erase; plain delete keeps the ledger

`ParkController.purge(_ id:)` = existing `discard(_:)` (cancel pending via engine + lifecycle, remove durable conversation + row, republish) **plus** `auditLog.purge(sessionID: id)`. The trash button and card context menu stay plain `discard` — the ledger's "what did my agents do" value survives normal deletes; only the explicit purge gesture erases history. The purge path adds **no logging of its own** (no os_log breadcrumb naming the session).

`AuditLog` gains `purge(sessionID:)`: `InMemoryAuditLog` filters the ring under its lock; `DiskAuditLog` filters the ring synchronously (viewers instantly consistent) and rewrites the JSON-lines file on the existing off-main writer queue via the existing atomic `persist` (a persist failure surfaces on `lastPersistError` exactly like a write — bounded, non-blocking, and the ring is already clean); `FailableInMemoryAuditLog` mirrors. `AppCoordinator` already owns a shared `auditLog` instance and injects it into `ParkController` (new init parameter, defaulted so existing tests stay source-compatible).

### D5 — Spec honesty about append-only

`ai-background-autonomy`'s "Append-only audit log" requirement is MODIFIED to name the single carve-out: an explicit user-initiated per-session purge removes that session's records from the ring and the durable file; nothing else ever removes or edits records (cap-trimming aside, which it already implies). This keeps the trust story crisp: the model can never erase its own tracks — only the user's deliberate gesture can.

## Risks / Trade-offs

- **[Extraction drift]** Rewiring the canvas path through the shared classifier could subtly change resolve feel. → The classifier is a mechanical lift of the existing math; existing recognizer/canvas tests must pass unchanged, plus direct classifier tests pin each D4 clause.
- **[Accidental purge]** A fast right flick is destructive with no confirm. → It's deliberate friction-free by request ("no logs"); mitigations kept: it only works while the conversation is expanded (a conscious surface), horizontal flicks require dominant-axis velocity (hard to do accidentally while scrolling vertically), and fast LEFT stays a no-op so a sloppy horizontal has a 50% dead side. Documented in the spec scenario.
- **[Concurrent-wave collisions]** `AppCoordinator`/`ParkController` carry other-wave edits. → Additive seams only (`onExpandedChanged`, `purge`), no reshaping of existing methods.
- **[Cursor-under-panel scroll during a flick]** A fast up-flick over the panel also scrolls the thread momentarily before collapse. → Invisible in practice (the panel recedes); accepted, matches the canvas precedent.

## Migration Plan

Code-only; no data migration. The audit purge is strictly user-initiated; existing ledgers are untouched until the gesture is used. Rollback = revert; purged records are gone by design (that is the feature's contract, stated in the spec).

## Open Questions

_None blocking._
