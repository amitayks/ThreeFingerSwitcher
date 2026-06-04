## Context

This design was produced and adversarially verified by a multi-agent research workflow (confidence: high), cross-checked against AltTab's current GPL-3 source and this codebase. The naive hypothesis ("`CGWindowList(.optionAll)` + on-demand AX") was refuted: `.optionAll` is on-screen + off-screen windows on the current realized list — still Space-scoped (AltTab issue #447). All-Spaces enumeration and off-Space raise require private CoreGraphicsServices (CGS) / SkyLight (SLS) APIs.

Current state: `WindowService.snapshot()` enumerates via `AXUIElementCreateApplication(pid)` + `kAXWindowsAttribute` (Space-scoped → current Space only); `raise()` does a bare `kAXRaiseAction` + `activate()` on a non-optional `axElement` (fragile/ineffective for off-Space windows). The header comment claiming "AX returns windows regardless of Space" is factually wrong.

## Goals / Non-Goals

**Goals:**
- List normal windows from all Spaces (other desktops + native-fullscreen), including those existing before launch; exclude minimized; current-Space behavior unchanged.
- Raise an off-Space window with real keyboard focus and exactly one Space switch, only at commit.
- Never regress below today's behavior; never crash if a private symbol is missing.

**Non-Goals:**
- The 2D-grid up/down = switch-Space-row interaction (separate follow-up change).
- A long-lived `AXObserver` registry (deferred performance optimization; brute force per snapshot suffices).
- Mac App Store, multi-monitor scrub semantics.

## Decisions

### D1 — dlsym, not @_silgen_name, for crash-safety (the critical decision)
A `@_silgen_name` reference to a symbol absent from every linked dylib **aborts at process launch**, before any Swift `guard`/`do-catch` runs. The CGS/SLS symbols live in `SkyLight.framework`, which is **not** auto-linked. So resolve every private symbol once at startup via `dlsym(RTLD_DEFAULT, ...)` into optional function pointers (`CGSPrivate.swift`). A preflight sets `offSpaceSupported = false` if **any** symbol is missing; when false, `snapshot()`/`raise()` use the legacy current-Space path. This makes "never regress / never crash" real even if Apple renames a symbol on a macOS 26 point release.
- *Alternative*: explicit SwiftPM link with `-framework SkyLight` + `weak_import` flags. Rejected as primary — more fragile across SDKs; dlsym gives a guaranteed runtime degrade.

### D2 — All-Spaces source = CGS per-Space enumeration
`cid = CGSMainConnectionID()`; ordered Space model + `currentSpaceIDs` from `CGSCopyManagedDisplaySpaces` (per-display `"Spaces"` `id64`, `"Current Space"`, confirmed by `CGSManagedDisplayGetCurrentSpace`). All-Spaces window IDs from per-Space `CGSCopyWindowsWithOptionsAndTags(cid, 0, [spaceID], 2, …)`, inverted to `[CGWindowID:[CGSSpaceID]]` (AltTab `buildWindowToSpacesMap`). Use this one API; drop `CGSCopySpacesForWindows` (one fewer private symbol). `CGWindowListCopyWindowInfo` is kept only for current-Space layer/alpha/bounds/title metadata.

### D3 — Off-Space AX elements via brute-force remote token (no AXObserver)
`kAXWindowsAttribute` cannot see off-Space windows, so an off-Space window has no AX element from the normal path. Acquire one via `_AXUIElementCreateWithRemoteToken`: 20-byte token = `pid + Int32(0) + Int32(0x636f636f) + Int64(axUiElementId)`, iterate `axUiElementId` `0..<1000` (100 ms budget/app, cached per pid per snapshot), keep `kAXStandardWindowSubrole`/`kAXDialogSubrole`, match `axWindowID(el) == wid`. This is the only reliable way to get a valid element for an off-Space window, and it also reaches windows created **before** our process launched (AltTab #431) — which is why an `AXObserver` registry is unnecessary for correctness (D-deferred).

### D4 — Off-Space raise sequence (AltTab-exact, AX raise mandatory)
Re-resolve the element at commit (cheap `kAXRoleAttribute` probe; if invalid, current-Space re-walk `kAXWindowsAttribute`, off-Space re-acquire via brute force). Current-Space + valid element → today's public path (no Space switch). Off-Space → guarded `GetProcessForPID(pid,&psn)` (reject zero PSN) + `_SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)` + `makeKeyWindow(psn,wid)` (two `SLPSPostEventRecordTo` records: `bytes[0x04]=0xf8`, `bytes[0x3a]=0x10`, wid at `0x3c`, `0xff` fill at `0x20`, `bytes[0x08]=0x01` then `0x02`) + **mandatory** `AXUIElementPerformAction(kAXRaiseAction)`. AltTab keeps both the SLPS front and the AX raise (both necessary). Do **not** use `CGSManagedDisplaySetCurrentSpace`/`CGSAddWindowsToSpaces` (auth-gated on 14.5+/26). If PSN/SLPS unavailable → degrade to `activate()` + `kAXRaiseAction` (front-only, no crash).

### D5 — Thumbnails unchanged
`ThumbnailService` already uses `onScreenWindowsOnly: false` and matches by `windowID`; `SCScreenshotManager` renders off-Space windows without bringing their Space forward. No functional change — just a comment that off-Space windows are now expected and blank-on-first-composite is acceptable.

### D6 — Ordering
`mru.rank(pid)` asc → current-Space-first → CG z-order within current Space → `spaceID` index as coarse cross-Space tiebreak. Snapshot frozen at gesture start (unchanged).

## Risks / Trade-offs

- **[`makeKeyWindow` 0xf8 byte ABI is undocumented/version-fragile]** AltTab is actively patching Tahoe front/activate regressions. → Gated behind `dlsym` presence; degrades to brute-forced `kAXRaiseAction` + `activate()` (front-only) rather than crashing. "Confirmed on 26" is point-in-time.
- **[Front-but-not-focused]** for some agent/dock-hiding and Settings windows (AltTab #1151), and System Settings Space bounce-back, are residual OS bugs with no public fix. → SLPS two-record + AX raise reduces but may not eliminate; covered by the test matrix.
- **[Off-Space titles permission-gated]** When no AX element resolves, title is app-name-only without Screen Recording. → Brute force usually yields an element (and thus `kAXTitle` without Screen Recording), so this mostly affects windows the token loop misses.
- **[Brute-force latency]** per-app `0..<1000` at 100 ms budget across many apps could add snapshot latency. → Cached per snapshot; if too slow, add a deferred `[pid: AXObserver]` registry caching elements by `axWindowID`, invalidated on destroy/terminate (shape noted, not built in v1).
- **[macOS 26 `kCGWindowOwnerPID` mis-attribution (FB18327911)]** confined to layer-25 status items, not layer-0 windows. → Cross-check pid via the AX element where available.
- **[Private symbols removed/renamed on a future macOS]** → `dlsym` preflight degrades cleanly to current-Space-only with no launch abort — the genuine "never regress" guarantee.

## Open Questions

1. Brute-force latency on a busy machine (many apps × Spaces) — measure; add AXObserver registry only if needed.
2. Multi-display Space semantics (Spaces are per-display) — v1 treats a single global ordered Space list; revisit with the 2D-grid change.
