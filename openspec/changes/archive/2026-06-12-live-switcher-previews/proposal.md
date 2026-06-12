## Why

The switcher renders each window as a single static thumbnail captured once when the gesture starts, so a window that is playing video, scrolling a terminal, or running a download looks frozen while you scrub. We can show the **currently highlighted** window as a live, continuously-refreshing preview — making the switcher feel alive — without paying for N concurrent capture pipelines and without ever showing the cropped/sideways frames that minimized, set-aside, or Stage-Manager-strip windows would otherwise produce.

## What Changes

- The switcher gains a **live preview of the highlighted card**: while the overlay is open, the currently selected window's thumbnail is re-captured on a fast cadence so its preview updates in near-real-time. Exactly one window is live at a time — the live focus follows the highlight as it scrubs across the row.
- Live capture **reuses the existing one-shot capture path and its safety gate verbatim** (`isOffAllDisplays` / `isStripProxy` / `isDegradedCapture`). A window that is not cleanly presented (set-aside, Stage-Manager strip proxy, off every display, or the synthetic Hub entry) is never live-captured — it holds its last good static frame. No new sideways/cropped failure modes.
- Live previews **start as fast as possible**: the heavyweight `SCShareableContent` enumeration is hoisted to once-per-gesture (cached `SCWindow` lookup), so each live frame is a bare `captureImage(filter, config)`. Selection changes trigger an immediate capture of the newly highlighted window, and the existing `inFlight` guard back-pressures the cadence to actual capture throughput.
- A new **"Live preview of the highlighted window" toggle** is added to the Switcher page of the configuration Hub, persisted across launches. The entire behavior is gated on it; turning it off restores the current static-only behavior.
- The first-frame bootstrap is unchanged: on open the overlay still seeds cached statics and one-shot `prefetch()`s the row; the live layer refreshes the highlighted card on top of that.

## Capabilities

### New Capabilities
<!-- none — this extends existing switcher and settings behavior -->

### Modified Capabilities
- `switcher-overlay`: adds a requirement that the highlighted card shows a live, continuously-refreshing preview that follows the selection, scoped to one window at a time, reusing the degraded-capture safety gate so non-cleanly-presented windows stay on their last good static frame.
- `tunable-settings`: adds a persisted "live preview" opt-in that gates the live-preview behavior and surfaces on the Switcher page.

## Impact

- **Code (capture):** `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` — add a cached `SCShareableContent`/`SCWindow` map (per gesture) and a fast `liveCapture(id:)` path that reuses the existing degraded gate and `store`/`onThumbnail`/`inFlight` machinery; add a `prepareLiveSession`/`endLiveSession` lifecycle.
- **Code (orchestration):** `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` — own a repeating live timer started in `gestureDidActivate` and stopped idempotently at every teardown site (commit, cancel, disable, sleep, resign-active, engine stop); retarget/kick an immediate capture on `gestureDidStep` / `gestureDidStepRow`; gate on the new setting and observe its toggle.
- **Code (settings):** `Sources/ThreeFingerSwitcher/Settings/AppSettings.swift` — add the persisted `livePreviewEnabled` boolean (Keys/Defaults/init/setter).
- **Code (Hub UI):** `Sources/ThreeFingerSwitcher/Hub/HubFeaturePages.swift` — add the toggle row to the Switcher page using the existing `ToggleRow`/`Toggle` pattern.
- **No new dependencies, no new permissions:** reuses ScreenCaptureKit and the existing Screen Recording grant; degrades silently when the grant is absent, exactly as today.
- **Out of scope / unchanged:** no `SCStream`, no per-window concurrent streams, no live capture of more than one window at a time, no change to the wizard demo strip (it keeps its static/sample thumbnails), no change to off-Space static previews.
