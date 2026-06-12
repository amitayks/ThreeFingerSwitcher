## Context

Today's ordering lives in `WindowService.snapshot()` (`WindowService.swift:267`) and `legacySnapshot()` (`:302`). The sort key is:

```
1. appRank    (mru.rank(pid))   ← app-level MRU
2. onCurrent
3. spaceIdx
4. z                            ← raw stacking order within a Space
```

`MRUTracker` keys recency by **pid** off `NSWorkspace.didActivateApplicationNotification`. Because every window of one app shares its `appRank`, same-app windows clump at level 1 and only separate at level 4 (z-order). The window the user actually alternates with gets pushed behind untouched same-app windows. After grouping into Space-rows (`SpaceGrouping.group`), this clumping is what the user feels within a single row.

The fix is a **window-level** recency key, fed by *all* focus sources so the last- and second-last-focused windows are always right — including focus changes the user made outside our switcher.

## Goals / Non-Goals

**Goals:**
- Order each Space-row by genuine **per-window** focus recency, fully interleaved across apps.
- Keep the current/frontmost window at index 0 and the previously focused window at index 1, even after an *external* switch (click, `Cmd-\``, Mission Control, Cmd-Tab).
- Preserve today's exact ordering for windows never focused since launch (current-Space → Mission Control Space order → z-order).
- No new permission, no persistence, no UI change, no activation-policy change.

**Non-Goals:**
- Persisting MRU across relaunches (stays in-memory, like app-MRU today).
- Reordering Space-**rows** — rows stay in Mission Control order (`switcher-overlay` "stable across reopens"); MRU only reorders *within* a row.
- Tracking focus of off-Space windows changed while off-Space (rare; the snapshot-time backstop covers re-entry).
- A vision/heuristic guess of focus — recency comes only from observed events.

## Decisions

### 1. A `WindowFocusTracker` keyed by `CGWindowID`, replacing app-MRU as the primary sort key
A `@MainActor` tracker holding `order: [CGWindowID]` (front = most recent) with `promote(_:)` / `rank(_:) -> Int` mirroring `MRUTracker`'s shape, but per window. `snapshot()` sorts:

```
1. winRank   (focus.rank(wid))   ← NEW primary
2. onCurrent
3. spaceIdx
4. z
```

`appRank` is dropped from the primary position. Windows with no recorded focus get `Int.max` and fall through to the existing `onCurrent → spaceIdx → z` fallback — byte-for-byte today's behavior for the never-touched case.

*Alternative considered — keep apps clustered, MRU-order windows within each app:* rejected. It still leaves the previously-used Terminal behind an untouched Chrome window; it does not solve the reported problem. The user explicitly wants full interleave.

*Alternative — keep `appRank` as a deep tiebreak below `z`:* unnecessary; once every focused window is promoted, "never focused" windows are genuinely history-less and z-order is the right fallback. (Left as a trivial option if determinism across never-focused windows of a recently-used app is ever wanted.)

### 2. Three focus sources feed `promote`, so external switches are captured
1. **Switcher commit** — `WindowService.raise(window)` promotes `window.id` immediately (most authoritative; covers same-app/current-Space raises that emit no app-activation notification).
2. **App activation** — on `didActivateApplicationNotification`, resolve the newly-front app's focused window (`AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `axWindowID`) and promote it. Covers Cmd-Tab and cross-app clicks.
3. **External within-app focus** — a live `AXObserver` on the **frontmost app only**, listening for `kAXFocusedWindowChangedNotification` (and `kAXMainWindowChangedNotification`). On fire, resolve the new focused window id and promote it. Covers clicking another window of the same app, `Cmd-\``, and Mission Control picks within one app. The observer is **retargeted** to the new frontmost app on each activation (one observer, not N across all apps).

### 3. Snapshot-time backstop keeps index 0 correct even when id resolution fails
Before sorting, `snapshot()` promotes the current frontmost app's focused window id if resolvable. This guarantees "current window first" even for an app whose AX focused-window id didn't resolve at observe time (some Electron/Chromium builds), and self-heals any missed event. It is a cheap, idempotent re-assert of source #2 at the moment it matters.

### 4. Eviction bounds the list to live windows
Like `elementCache`, prune `order` to currently-enumerated window ids on each `snapshot()` so closed windows don't linger or leak. (Ids are unique per window lifetime and not reused within a session, so a stale id can never mis-rank a new window.)

### 5. Graceful degradation without Accessibility
The AX observer and focused-window resolution require Accessibility (already required to enumerate/raise at all). With AX absent, tracking degrades to commit + app-activation only, and `snapshot()` already returns empty without AX — so there is no new failure mode and no new prompt.

## Risks / Trade-offs

- **AX observer C-callback bridging** → `AXObserverCreate` takes a C function pointer; pass the tracker via the `refcon` context pointer and bounce back on the main run loop, the standard pattern. Add/remove the observer's run-loop source on retarget to avoid leaks.
- **Focus oscillation under Stage Manager** (the co-staged same-app churn noted in `WindowService`) could rapidly re-promote → MRU only ever *reads* at snapshot, and promote is idempotent, so transient oscillation just leaves the last-settled window on top. No storm, no persisted damage.
- **Unresolved focused-window id for some apps** → source #2/#3 simply record nothing for that event; the snapshot-time backstop (#3) and z-order fallback keep ordering sane. Worst case for such an app = today's behavior.
- **Retarget races** (activation fires faster than observer teardown) → guard with the frontmost pid; promote is idempotent so a duplicate is harmless.
- **Off-Space focus changes** while a window is off-Space aren't observed (observer follows the current-Space frontmost app) → acceptable; on re-entry the window surfaces via activation/backstop. Out of scope per Non-Goals.

## Migration Plan

Pure in-memory behavior change. No data migration, no flag. Rollback = revert the commit; the app-MRU path is untouched code that can be restored. `MRUTracker` may be kept (app-MRU is now unused by ordering) or removed in the same change; keeping it is lower-risk and lets the fallback tiebreak option (#1) stay open.

## Open Questions

- Cap `order` length (e.g. last 200 ids) in addition to live-id pruning? Pruning already bounds it to live windows; a hard cap is likely unnecessary.
- Remove `MRUTracker` entirely, or leave it dormant? Leaning leave-dormant this change to minimize blast radius.
