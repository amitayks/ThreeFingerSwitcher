## Context

`WindowService.snapshot()` builds the all-Spaces candidate set from the private CGS per-Space enumeration (`SpaceService.windowsInSpace`, options `7`), then for each window tries to resolve an Accessibility element: current-Space via `kAXWindowsAttribute`, off-Space via remote-token brute force, with a persistent `elementCache` bridging windows that were reachable earlier. When an element resolves (live or cached), `isSwitchable(el)` decides listing — it requires `kAXStandardWindowSubrole` and excludes minimized. When **no** element resolves for an off-Space window, the code falls to a metadata-only gate: `alpha > 0 && min(bounds.w, bounds.h) >= 130`. That fallback was added so genuine off-Space **Chromium** windows (which expose no remote-token-reachable element — "Bug A") still list.

The two defects:

- **Ghost listing (P2).** The metadata-only gate has no role/subrole/minimized check, so off-Space it lists dialogs, dismissed sheets, and closed-but-process-alive windows (ASUS GlideX, and a Terminal dialog/sheet with no Accessibility window, observed as a "terminate running processes?" prompt). The user confirmed these are **truly absent** on their own Space — the current-Space AX path correctly rejects them — so the bug is exclusively the metadata-only path.
- **Degraded thumbnails (P1).** `ThumbnailService.prefetch()` re-captures every visible id on every showing, including cached ones; `capture()` uses `SCContentFilter(desktopIndependentWindow:)`, which returns the window's *current* on-screen surface. Under Stage Manager set-aside that surface is the tilted strip proxy, and the result **overwrites** the previously-good cached thumbnail. `SwitcherView` applies no transform, confirming the tilt is in the bitmap.

Both share a cure: **trust the last clean observation** made while the window was cleanly visible on the current Space. Constraints: never crash / never regress the legacy current-Space path (`cgs.offSpaceSupported` guard); keep `SpaceGrouping.group()` pure; do not touch raising/focus, gesture recognition, or the overlay view; GPL-3 (AltTab-derived); app is unsandboxed.

## Goals / Non-Goals

**Goals:**
- Off-Space rows never show a window that the current-Space path would reject (ghosts), while genuine off-Space windows — including no-element Chromium — still list.
- A window's card shows its last *clean* thumbnail rather than a degraded set-aside/off-screen capture; a degraded capture never replaces a good one.
- Discriminators (which off-Space candidates are ghosts; which captures are degraded) are chosen from `--diag`/log data, not guessed.

**Non-Goals:**
- No change to the current-Space listing/ordering, raising/focus, gesture recognition, or overlay rendering.
- No attempt to render a *better* thumbnail for a set-aside window (we keep the cached/icon fallback rather than un-tilting a proxy).
- No new TCC prompts or entitlements.

## Decisions

### Sequence diagnostics first
Extend `diagnosticReport()` before writing either filter. For every window listed via the metadata-only path, dump owner/name/bounds/alpha/layer/`kCGWindowIsOnscreen` and whether a brute-force or cached element resolved; add opt-in logging of `scWindow.frame` vs the logical frame in `capture()`. Run `--diag` standing on a Space where ASUS/the Terminal sheet appear off-current, and capture a set-aside window. This converts the two open questions (what marks a ghost; what marks a degraded capture) into observations. *Why:* a ghost and a genuine never-activated off-Space Chromium window look identical at the CGS-metadata level; committing to a discriminator blind risks regressing Bug A or under-filtering.

### P2 (chosen, data-driven): require a live-or-cached AX element off-Space; drop the metadata-only path
**This supersedes the originally-chosen negative-observation cache, which the diagnostic dump proved inert.** A `--diag` capture taken with both real ghosts present (`/tmp/tfs-cross-space-diag.txt`, via the in-app "Write Diagnostics" menu) is decisive:

- The two ghosts — ASUS GlideX (wid 16614) and a Terminal no-AX window (wid 1760, observed as a "terminate?" sheet) — are the **only** layer-0 regular-app windows with `live=0 cached=0`: no Accessibility element resolves for them on **any** Space, live or cached. Every genuine window — including an *off-Space* Chrome window — has at least `cached=1` (and Chrome even showed `live=1`, i.e. remote-token brute force reached it off-Space on this Tahoe build).
- The ghosts are **indistinguishable from real windows by CGS metadata**: both have `alpha=1.0`, real bounds (260×234 and 1280×779, ≥ the 130px floor), and `CGSCopySpacesForWindows` returns `spaces=1` for them exactly as it does for every window on Tahoe.

So the only discriminator the data exposes is **Accessibility presence (live OR cached)**. The fix: in `snapshot()`, list an off-Space window only when an element resolves (brute force or `elementCache`); **remove the metadata-only fallback entirely** (`metadataListable`). This is AltTab's 100%-Accessibility model.

Consequences (net code deletion, not addition):
- The **negative-observation cache** (`negativeSwitchable`) becomes dead: it only ever fed `metadataListable`, and an AX-present-but-non-switchable window (e.g. a sheet reached off-Space) is already rejected by `isSwitchable(element)` directly. Remove it.
- The **empty-Space gate** (`CGSCopySpacesForWindows` count == 0) is both dead (only fed the metadata path) and useless on Tahoe (returns `1` for everything). Remove it (and `Spaces.spaceCount` / the `CGSCopySpacesForWindows` binding if unused elsewhere).

**Bug-A guard (load-bearing):** dropping the metadata path means a genuine off-Space window with *no* element at all would vanish. Genuine windows avoid this only because they were cached while reachable. So the `elementCache` seeding — on app activation (`didActivateApplication`) and on every snapshot's current-Space pass — is now the sole Bug-A defense and MUST be preserved; strengthen it if validation finds a real window at `live=0 cached=0` (e.g. seed on window-created Accessibility notifications, AltTab-style, to cover a window never visited since launch).

- *Why not the negative cache:* it can only learn ids that appear in an app's AX tree on the current Space; the real ghosts appear in **no** AX tree, so it stays empty for them (`negativeSwitchable set size: 0` in the dump). It remains valid only for the narrower "AX-visible-but-non-switchable sheet" class, which `isSwitchable` already handles — hence redundant.
- *Why not tighten CGS options (`7` → narrower):* the ghosts carry normal metadata indistinguishable from real windows, so no options value cleanly separates them without risking genuine off-Space windows; not pursued.

*Residual risk (accepted, validated against the dump):* a real off-Space window that was never reachable this session (never activated, never on the current Space during a snapshot) would not be listed. The dump shows no such window today (every genuine window is cached); validation requires confirming no real window is `live=0 cached=0` in a fresh capture — especially a long-unvisited off-Space Chrome window — before declaring done.

### P1: degraded-capture detection + cache-first prefetch (chosen); HW-capture experiment reverted
**Reverted dead-end:** a mid-change experiment routed Stage-Manager captures through the private window-server hardware capture (`CGSHWCaptureWindowList` with `fullSize`, AltTab's options `ignoreGlobalClipShape | bestResolution | fullSize`) on the theory it returns the full un-skewed backing store. On Tahoe it returns stale/garbage backing — the dump shows `hw=` at full logical size (e.g. `3024×1898`) for set-aside windows, but the pixels are corrupt/blank, making P1 *worse* than the original tilt. This matches AltTab's open Tahoe Stage-Manager capture issues (#1731/#4242/#5490). So the HW path in `capture()` and the `cgs.hwCaptureWindowList` binding are **removed**, falling back to ScreenCaptureKit + the degraded-capture guard below. (The `--diag` frame dump's `hw=` column is produced solely by that binding via `hwCaptureImage`, so it is dropped together with it.)

The remaining, correct mechanism — two coordinated changes in `ThumbnailService`:
1. **`capture()` bails on a degraded frame.** Compare SCK's `scWindow.frame` against the window's logical frame (`WindowInfo.frame` / CGWindowList bounds): a set-aside proxy is much smaller and/or off the display. When degraded, return without calling `store`/`onThumbnail`, preserving the cached image or icon. Exact threshold comes from the frame log.
2. **`prefetch()` is cache-first.** Only live-capture windows whose current presentation is clean — not minimized, and not set aside / parked off every display. An off-Space window whose frame still falls on a display IS captured (preserving live off-Space previews); only set-aside / off-every-display / minimized windows are skipped, with `seed` from cache covering them. The skip discriminator is the off-all-displays frame test (the same signal `isDegradedCapture` uses), **not** "off the current Space" — an off-Space-but-on-screen window like the dump's Chrome (`cur=0`, `sc=1512×949@0,33 offAllDisplays=0`) should still refresh.
3. **Warm the cache when clean.** Capturing cleanly-visible current-Space windows on show keeps a good image available for when they later go off-Space/set-aside.

**Two set-aside presentations (the strip proxy — added after on-device validation).** Stage Manager parks set-aside windows two different ways, and the first fix only caught one:
- *Strip on a NON-current Space* → windows parked at negative-x, `offAllDisplays=1`. Caught by `isOffAllDisplays`.
- *Strip on the CURRENT Space (visible side strip)* → thumbnails sit at positive x, `onScreen=1`, and **CGWindowList reports the small SCALED strip rect** (e.g. `160x184`), so neither `isOffAllDisplays` nor the SCK-vs-CGWindowList ratio fires — the tilted strip bitmap got captured and shown.

The discriminator: **CGWindowList lies under Stage Manager but Accessibility tells the truth.** The `--diag` dump proved it — strip windows show `cg=160x184 ax=1512x949` while full-size windows show `cg=1512x949 ax=1512x949`. So `WindowInfo` carries `realFrame` (the AX size), and `ThumbnailService.isStripProxy(displayedFrame:realFrame:)` skips a window whose CGWindowList frame is < 50% of its AX frame in both dimensions (serving the cached preview or icon). `prefetch()` also passes `realFrame` as the logical frame so `capture()`'s degraded check has the true size as a backstop. The change is additive: if AX had reported the strip size too, the ratio would be ≈1 and nothing would change.

- *Alternative — keep refreshing everything but never overwrite a "better" image with a "worse" one:* requires ranking image quality, which is fuzzier than detecting the degraded *presentation*. Rejected in favor of gating on observable frame/Stage-Manager state.

### Keep the pieces small and testable
The degraded-frame decision is extracted as a pure helper (`isOffAllDisplays`, `isDegradedCapture` — a `(scFrame, logicalFrame, displayUnion) -> Bool` predicate) so `Tests/ThreeFingerSwitcherTests` can pin it without a live WindowServer, matching how `SpaceGrouping` is tested. (The off-Space AX-required gate is not a pure helper — it is intrinsic to `snapshot()`'s element resolution — so its behavior is validated by the `--diag` dump and manual multi-Space checks rather than a unit test.)

## Risks / Trade-offs

- **Bug-A cold-start regression** → requiring a live-or-cached element drops a genuine off-Space window that was never reachable this session (never activated, never on the current Space during a snapshot). *Mitigation:* `elementCache` seeding on activation and every current-Space pass covers the common case; the dump shows no real window at `live=0 cached=0` today; if validation finds one, seed on window-created AX notifications (AltTab-style). This is the deliberate trade for eliminating ghosts.
- **HW capture returns garbage on Tahoe** → using `CGSHWCaptureWindowList` for set-aside windows overwrites good cache with corrupt pixels. *Mitigation:* reverted; SCK + degraded-capture guard is the path.
- **Degraded-frame threshold misclassifies a small-but-real window** (a genuinely tiny window read as set-aside) → it would fall back to icon/cache instead of a fresh capture. *Mitigation:* derive the threshold from logged set-aside vs staged frames; bias toward only treating clearly off-screen / proxy-scaled frames as degraded; worst case is an occasional stale-but-clean thumbnail, never a wrong window.
- **Cache-first prefetch shows a slightly stale preview** for a window edited while off-Space → acceptable and strictly better than a tilted proxy; refreshes the next time the window is cleanly visible.
- **`elementCache` grows unbounded** → prune to currently-enumerated ids each snapshot (already done); it is now the load-bearing Bug-A guard, so its lifetime/eviction must stay correct.

## Open Questions

- ~~Do the real ghosts (ASUS, the Terminal sheet) appear in their app's AX tree on the current Space (so the negative cache catches them), or only at the CGS level?~~ **Resolved:** neither — they appear in **no** AX tree on **any** Space (`live=0 cached=0`); the negative cache stayed empty for them (`negativeSwitchable set size: 0`). This killed the negative-cache approach and selected "require a live-or-cached AX element" (see P2 decision).
- ~~Is `scWindow.frame` for a set-aside window the strip-proxy size, an off-screen origin, or the logical frame?~~ **Resolved:** both — a small strip-proxy size **and** an off-screen (negative-x) origin, e.g. `sc=204×171@-303,259 offAllDisplays=1`. The `isOffAllDisplays` X-axis test fires on this frame, so the existing degraded-capture predicate is correct; no threshold retune needed.
- ~~If both point away from a clean signal, do we adopt narrower CGS options, an on-screen-flag check, or positive-AX-corroboration?~~ **Resolved:** positive-AX-corroboration (require a live-or-cached element), with the Bug-A cold-start caveat documented and covered by element-cache seeding.
- **Still open (validation):** does a *long-unvisited* off-Space Chrome window retain `cached=1` (or `live=1`) on Tahoe? If yes, the metadata path was pure ghost-vector and dropping it is risk-free; if a real window ever shows `live=0 cached=0`, strengthen seeding (window-created AX notifications) before relying on the AX-required gate. Confirm in a fresh "Write Diagnostics" dump.
