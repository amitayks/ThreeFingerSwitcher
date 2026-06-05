## Status (2026-06-05): corrected by diagnostic data

A `--diag` capture taken with both ghosts present (`/tmp/tfs-cross-space-diag.txt`, via the in-app
"Write Diagnostics" menu) overturned the original P2 plan and exposed a P1 regression from a
mid-change experiment. See `design.md` → "P2 (chosen, data-driven)…" and "P1 … HW-capture
experiment reverted". Net effect:

- **P2:** the negative-observation cache (§2) is **inert** for the real ghosts — they have no
  Accessibility element on any Space, so they never enter it (`negativeSwitchable set size: 0` in
  the dump). The fix is to **require a live-or-cached AX element off-Space and delete the
  metadata-only path** (plus the now-dead negative cache and empty-Space gate). See §7.
- **P1:** the `CGSHWCaptureWindowList` hardware-capture experiment returns garbage backing on Tahoe
  and is **reverted** to the ScreenCaptureKit + degraded-capture path. See §8.

Sections 1–6 are kept as the audit trail; §7–§10 are the remaining, corrected work.

## 1. Diagnostics first (gather the discriminators)

- [x] 1.1 Extend `WindowService.diagnosticReport()` so every layer-0 regular-app candidate (incl. dropped) prints owner pid/name, bounds, alpha, layer, `kCGWindowIsOnscreen`, CGS Space membership, and whether a live/cached AX element resolved.
- [x] 1.2 Add opt-in frame logging in `ThumbnailService.capture()` (env `TFS_THUMB_LOG`) recording SCK `scWindow.frame` vs the logical frame; plus a `diagnosticFrames()` dump appended to "Write Diagnostics".
- [x] 1.3 (MANUAL) **Done — findings recorded in `design.md` Open Questions.** The two ghosts (ASUS wid 16614, Terminal sheet wid 1760) are the only `live=0 cached=0` windows; every genuine window — including off-Space Chrome — resolves an element (Chrome even `live=1`). Set-aside `scWindow.frame` is a strip proxy at negative-x (`204×171@-303,259 offAllDisplays=1`). `CGSCopySpacesForWindows` returns `1` for every window on Tahoe.

## 2. P2 — negative-observation cache  ⚠️ SUPERSEDED (kept as record; removed in §7)

- [x] 2.1 Added persisted `negativeSwitchable: Set<CGWindowID>`.
- [x] 2.2 Current-Space pass records ids whose element FAILS `isSwitchable` for a stable reason.
- [x] 2.3 Metadata-only gate consults `negativeSwitchable` via `metadataListable`.
- [x] 2.4 Prune `negativeSwitchable` to currently-enumerated ids each snapshot.
- [x] 2.5 (MANUAL) **Escalation triggered.** The ghosts are NOT AX-visible on any Space, so `negativeSwitchable` stays empty for them and does not remove them — the gate is structurally inert here. Proceed to §7 (require AX element) rather than the §5 levers.

## 3. P1 — degraded-capture detection + cache-first prefetch

- [x] 3.1 Pure predicates `isOffAllDisplays` / `isDegradedCapture` added.
- [x] 3.2 `capture()` returns without `store`/`onThumbnail` on a degraded frame.
- [x] 3.3 Cache-first `prefetch()` pre-filter was **undone by the HW experiment** (prefetch now live-captures everything, relying on HW). Restore in §8.3.
- [x] 3.4 `AppCoordinator.prefetchCurrentRow` passes `[WindowInfo]` (with `frame`/`isOnCurrentSpace`) into `prefetch()`.
- [x] 3.5 On-show prefetch stores only CLEAN captures, warming the cache for later off-Space/set-aside showings.

## 4. Tests

- [x] 4.1 Unit-tested the (now-to-be-removed) `metadataListable`/negative-cache decision — update in §9.
- [x] 4.2 Unit-tested `isOffAllDisplays` / `isDegradedCapture` (clean, off-left/right, straddling, scaled-proxy) — keep.
- [x] 4.3 Full suite green (142) pre-correction; `SpaceGrouping.group()` untouched; legacy path unchanged.

## 5. ~~Fallback levers~~ → not pursued

- [x] 5.1/5.2 Narrower CGS options / extra metadata heuristic **not pursued**: the ghosts carry normal metadata (alpha 1.0, real bounds, `spaces=1`) indistinguishable from genuine off-Space windows, so no options/metadata value separates them safely. The chosen resolution is the AX-required gate (§7).

## 6. Verify (pre-correction)

- [x] 6.1 `swift build` / `swift test` passed (142, 0 failures) before the correction.
- [x] 6.4 `openspec validate robust-offspace-window-fidelity` (valid). Re-run after §7–§9 (see §10.4).

## 7. P2 fix (data-driven): require a live-or-cached AX element off-Space

- [x] 7.1 In `WindowService.snapshot()`, list an off-Space window only when an AX element resolves (remote-token brute force or `elementCache`). Remove the `else if !onCurrent { … metadataListable … }` branch so a no-element off-Space window (a ghost) is dropped; an AX-present element still passes `isSwitchable`.
- [x] 7.2 Remove the metadata-only gate `WindowService.metadataListable` and the `minOffSpaceDimension` constant.
- [x] 7.3 Remove `negativeSwitchable` and all its reads/writes/pruning (dead once 7.1 lands — `isSwitchable(element)` already rejects AX-present non-standard subroles and minimized).
- [x] 7.4 Remove the empty-Space gate (`SpaceService.spaceCount` / `CGSCopySpacesForWindows`) from `snapshot()`; drop `SpaceService.spaceCount` (in `Spaces.swift`) and, if unused elsewhere, the `CGSCopySpacesForWindows` binding in `CGSPrivate.swift` — all three parts: the `FnCopySpacesForWindows` typealias (and its doc comment), the `copySpacesForWindows` struct field, and the `loadSymbol(...)` line in `init()`. Also drop the diagnostic `spaces=` column (it has no other source once `spaceCount` is gone, and is inert on Tahoe — `spaces=1` for every window).
- [x] 7.5 Preserve `elementCache` seeding (on app activation + every current-Space pass) and its prune-to-live-ids eviction as the sole Bug-A guard. If §10.2 finds a real window at `live=0 cached=0`, add window-created AX-notification seeding (AltTab-style) before relying on the gate.
- [x] 7.6 Update `diagnosticReport()` to the AX-required model so it still compiles and remains the §10.2 validation instrument. The §7.1–§7.4 removals delete symbols the dump references today (`WindowService.swift` ~line 144 `negCache=`, ~147 `negativeSwitchable set size`, ~173 `neg=`, ~175 `spaces=`/`spaceCount`, ~181-182 `metadataListable`/`minOffSpaceDimension`), so: drop the `neg=`/`negCache=` columns and the `negativeSwitchable set size` line; drop the `spaces=` column; drop the `metadata-only ghost candidate` block (it keys on `w.axElement == nil && !w.isOnCurrentSpace`, which `snapshot()` can no longer produce after 7.1); and reduce each candidate's `decision` to `AX-path` / `drop(off-space,no-element)` / `drop(current,no-element)` without `metadataListable`/`spaceCount` — keep the current-vs-off-current distinction, since the surviving `else { listable = false }` branch still produces a current-Space no-element drop. Remove `cgsPlacesIt` (line ~176) and its `spaces`-dependent decision branches (lines ~181/183) along with `spaceCount`. Keep the per-candidate `live`/`cached` columns — they are the ghost discriminator.

## 8. P1 revert: drop the HW-capture experiment

- [x] 8.1 In `ThumbnailService.capture()`, remove the `StageManager.isEnabled → hwCaptureImage` branch so every capture goes through SCK + the `isDegradedCapture` guard. Also update the now-stale comment that frames the SCK path as a "fallback only (Stage Manager off, or HW capture unavailable)" — after the revert SCK is the sole/primary path (the degraded-capture rationale stays).
- [x] 8.2 Remove `ThumbnailService.hwCaptureImage` and the `cgs.hwCaptureWindowList` binding in `CGSPrivate.swift` — all three parts: the `FnHWCaptureWindowList` typealias (and its doc comment), the `hwCaptureWindowList` struct field, and the `loadSymbol(...)` line in `init()`. Drop the `hw=` column from `diagnosticFrames()` (the `Self.hwCaptureImage(...)` call, the `hw=\(hw)` token, and the now-stale comment) — that column has no other source once the binding is gone.
- [x] 8.3 Restore cache-first `prefetch()` (task 3.3): pre-filter windows whose logical frame is off all displays (set-aside) and do NOT live-capture them; `seed` continues to cover all ids from cache. Off-Space-but-on-screen windows still capture. (Minimized windows need no special handling here — `snapshot()`'s `isSwitchable` already excludes them, so they never reach `prefetch()`.) Also update the now-stale `prefetch()` doc-comment, which still describes the reverted HW-capture behavior ("set-aside windows are handled in `capture()` by the window-server hardware capture … it simply captures every requested window"), to the restored skip-set-aside behavior.

## 9. Test updates

- [x] 9.1 In `OffSpaceFidelityTests`, remove/replace the `metadataListable` / negative-cache assertions (deleted in §7); keep `isOffAllDisplays` / `isDegradedCapture` coverage.
- [x] 9.2 `swift build` and `swift test` green.

## 10. Verify (post-correction)

- [x] 10.1 `swift build` and `swift test` pass after §7–§9.
- [x] 10.2 (MANUAL) **Confirmed.** Ghosts gone from off-Space rows; genuine off-Space windows still list. Fresh dumps show no real listable window at `live=0 cached=0` (every genuine window resolves an element).
- [x] 10.3 (MANUAL) **Confirmed after the §11 strip-proxy follow-up.** Stage-Manager set-aside windows no longer show the tilted bitmap — they serve a clean cached preview or the app icon.
- [x] 10.4 `openspec validate robust-offspace-window-fidelity` (valid).

## 11. P1 follow-up: current-Space Stage-Manager strip proxy

Discovered during §10.3 manual validation: the §3/§8 fix only caught set-aside windows on a
**non-current** Space (parked at negative-x → `offAllDisplays=1`). When the strip is on the
**current** Space and visible, its thumbnails sit at positive x, `onScreen=1`, with CGWindowList
bounds reporting the small SCALED strip rect — so neither `isOffAllDisplays` nor the SCK-vs-CG ratio
fired, and the tilted strip bitmap was captured and shown. The `--diag` dump is decisive: strip
windows show `cg=160x184 ax=1512x949` (CGWindowList = scaled strip; AX = real size) while full-size
windows show `cg=1512x949 ax=1512x949`. CGWindowList lies under Stage Manager; AX is the truth.

- [x] 11.1 Add `realFrame: CGRect` to `WindowInfo` (the AX/real window size; `.zero` default keeps legacy/test construction sites and the legacy path untouched).
- [x] 11.2 Populate `realFrame: axFrame(element)` in `WindowService.snapshot()` (element is always present now under the AX-required gate).
- [x] 11.3 Add pure `ThumbnailService.isStripProxy(displayedFrame:realFrame:)` — true when the displayed (CGWindowList) frame is < 50% of the real (AX) frame in BOTH dimensions.
- [x] 11.4 `prefetch()` skips strip proxies (in addition to off-all-displays) and passes `realFrame` as the logical frame so `capture()`'s degraded check compares SCK against the true size (backstop).
- [x] 11.5 Diagnostics: per-listed-window dump prints `cg=`/`ax=` so the strip-proxy signal is observable.
- [x] 11.6 Unit tests for `isStripProxy` (strip proxy, normal window, zero/degenerate realFrame, modestly-smaller window); full suite green (141).
- [x] 11.7 (MANUAL) **Confirmed** on-device: strip thumbnails no longer tilt; dump shows `cg` ≪ `ax` for strip windows and `cg == ax` for full-size windows.
