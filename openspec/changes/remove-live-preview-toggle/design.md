## Context

Live preview is now safe to run unconditionally: the motion gate (capture only once the frame holds still for `liveSettleTicks` consecutive ticks), the fresh-frame degraded gate, and the `.fit` render together keep it from ever capturing an in-flight / sideways frame. With the no-sideways concern handled at the capture layer, the opt-in toggle is pure friction — and it actively caused a stuck-off state on machines that ran the earlier (reverted) "default-off" experiment, where `livePreviewEnabled = false` is persisted and silently wins over the code default.

## Decisions

### Remove the setting entirely (not just hide the toggle)
Delete `livePreviewEnabled` (property, `Defaults`, `Keys`, init read, reset) rather than hardcoding it `true` behind a hidden flag. Removing the *read* is what fixes the stuck-off machines: a persisted `false` is no longer consulted, so live preview is on for everyone with **no migration**. The orphaned UserDefaults key is harmless and needs no cleanup.

### Loop lifecycle unchanged; only the gates and observer go
`startLivePreview` / `stopLivePreview` keep starting the loop on overlay show and stopping it on every teardown path. Only three things are removed: the `settings.livePreviewEnabled` clause in `startLivePreview`'s guard, the `settings.livePreviewEnabled` guard at the top of `tickLivePreview`, and the `observeLivePreviewToggle` Combine observer (plus its call site) — there is no longer a value to react to. `tickLivePreview` remains the single choke point for every live re-capture, now unconditional.

## Risks / Trade-offs

- **A user who preferred static thumbnails loses the choice.** Accepted: the dynamic preview is the intended experience and it now captures cleanly; if a static mode is ever wanted again it can return as a new setting.
- **No migration relies on the removed read ignoring the orphaned key.** This is standard `UserDefaults` behavior — an unread key has no effect.
