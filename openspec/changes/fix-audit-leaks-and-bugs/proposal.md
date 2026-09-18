# Fix the audit's memory leaks, stale switcher previews, and correctness bugs

## Why

A five-area audit (Windows/Spaces, input/gesture, overlays/Dock, Hub/onboarding, app services) of the post-cleanup app found one genuine unbounded leak, one leak-guard from the previous perf fix that never worked, the real reasons the switcher's window previews update late, and a set of correctness bugs — a few of them user-visible in painful ways (the Danger-zone wipe stranding relocated system gestures; a three-finger touch killing an open ⌘-Tab session; bare Tab swallowed system-wide after a tap stall). None of it is behavior anyone chose.

## What Changes

**Leaks (process-lifetime growth):**
- The two private SkyLight `Copy` functions (`CGSCopyManagedDisplaySpaces`, `CGSCopyWindowsWithOptionsAndTags`) were bound as `-> CFArray?` on a C function pointer; Swift retained the already-owned result, leaking one array per call — every switcher open, every Space, and 60 ms polling after Space actions. Confirmed empirically (retain count 2, ~1.5 KB/call). Bound as `Unmanaged` + `takeRetainedValue()` like the existing `_AXUIElementCreateWithRemoteToken` binding.
- The 1 Hz permission poll's "no regular window visible" guard was always satisfied by the status item's own `NSStatusBarWindow`, so a Hub closed on the Setup page still polled six TCC services per second for the process lifetime. The guard now requires a titled window.
- The Dock preview's own thumbnail cache is pruned alongside the switcher's, and both prune to the set of *all existing* windows (not the switcher's filtered snapshot, which evicted frames of windows merely filtered out).
- Clipboard: the byte cap now counts blob-backed entries after relaunch; large session payloads are externalized to blobs once persisted so they stop being resident; `flush()` (previously uncalled) runs at quit and before the Danger-zone wipe.

**Switcher previews update immediately:**
- An explicit refresh (open, Space switch) now *replaces* a sweep still refreshing the row the user just left instead of being dropped by skip-if-busy (previously up to ~1.6 s of stale frames on the new Space). Timer ticks stay skip-if-busy.
- Captures run a few at a time (bounded task group) instead of strictly sequentially; the `SCShareableContent` enumeration is cached across a session's sweeps; the open sweep captures the visible row first and then every other Space's row once; frames landing within one frame are coalesced into a single publish; the one window mid-capture at hide/switch no longer sits out the next sweep; the Hub's mini switcher joins the live fan-out.

**Correctness:**
- Danger-zone data wipe restores the gesture/Spaces relocations synchronously before the preferences domain (where the backups live) is deleted — the deferred flag observers restored nothing.
- `disable()` always tears down (it no-op'd after a wake where the trackpad wasn't back), and the wake restart gates on the opt-in so a later wake retries.
- A trackpad three-finger touch while a ⌘-Tab session owns the overlay is refused *entirely* (no steps, no commit, no cancel) — it used to hijack or dismiss the keyboard session.
- The ⌘-Tab tap re-derives the ⌘ state from every event and after every tap re-enable (a ⌘-up missed during a tap stall left bare Tab/Esc/arrows swallowed system-wide).
- The post-commit focus watchdog and Stage-Manager hold-guard are released by user input (mouse down, ⌘-shortcut) and by a Dock peek, so they no longer undo a deliberate switch-away; the de-minimize deferred raise is token-gated and reports a failed minimize write.
- Dock preview: leave-restore only when the peeked window is still frontmost; peek is idempotent under hover flicker; the empty-app memo sticks.
- Clipboard: the recorder ignores the launcher's own pastes (they were re-recorded with the wrong source app and duplicated TIFF images); image previews read only the needed representation, off the main actor, behind a settle gate; the Clipboard band's horizontal auto-repeat suppression is re-evaluated per tick.
- Hub/onboarding: Setup's app-activation re-read only while the Hub is visible; band-canvas drag ids cleared on any drop so a cancelled drag can't replay a reorder; the Hub card gets its own Space's index; wizard hand act counts travel, not touchdown, as a scrub; excluded-apps editor dedupes by bundle id.
- Per-site keyboard language: negative-result backoff for the Accessibility address-bar walk and a short Apple Events timeout, so a browser without a findable address bar can't cost the main thread twice a second.
- Smaller: focus tracker retries an app whose AX observer registration failed; deterministic main-display current Space on multi-display; the minimized supplementary pass reuses the per-snapshot AX reads; the legacy snapshot prunes the element cache; the touch engine drops the one frame the shared stream replays after a restart; Keep Awake's `onActiveChanged` is wired; the keyboard-language store skips no-op writes; launcher presets no longer report "Done" early and never surface raw OS error text; the dormant tour engine's vertical sign matches the recognizer.

## Capabilities

### Modified Capabilities
- `window-enumeration-and-raising`: thumbnail refresh contract (replacing explicit refresh, whole-reel open sweep, coalesced publish, cached enumeration); post-commit guards released by user input; de-minimize raise token-gated; private Spaces API ownership.
- `dock-preview-overlay`: leave-restore is conditional on the peeked window still being frontmost.
- `command-tab-switcher`: a trackpad touch during a keyboard session is refused entirely; the tap resyncs ⌘ state after a disable.
- `configuration-hub`: Danger-zone restore is synchronous and precedes the wipe; clipboard persistence is drained first.
- `clipboard-history`: own pastes are not re-recorded; byte cap counts blob-backed entries; durable flush at quit/wipe; bounded resident payloads.
- `per-site-keyboard-language`: bounded host-reading cost.
- `permissions-onboarding`: polling is scoped to a visible titled window.
- `menubar-app-shell`: disable/wake symmetry.
- `first-run-onboarding`: a live touch counts as a scrub only on real travel.

## Impact

All Core (`Sources/ThreeFingerSwitcher/…`), verified with `swift build` / `swift test` (new unit tests for the pure parts). Live AX/TCC/ScreenCaptureKit behavior — the peek restore gate, the guard release on user input, the capture latency — needs the user's signed build to confirm.
