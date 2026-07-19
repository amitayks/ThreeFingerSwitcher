# Design — Keep Awake: guard lock + keyboard backlight dim

## Context

The user's ask was "chain actions before and after Keep Awake." The two motivating examples turned out to be two different categories, and the design models them as such rather than as a generic action chain:

- **Keyboard backlight off** is a *symmetric session state* — exactly the shape display brightness already has (snapshot on start, set, re-pin on heartbeat, restore on stop, force-restore on quit/sleep). A chained one-shot "turn the light off" would drift back on under auto-illumination and never restore on quit.
- **Lock on stop** is a *path-sensitive exit one-shot*: it must fire on the input stop path and must NOT fire on teardown (quit/will-sleep) or explicit stops.

User decisions locked in: (1) an input while guarded is treated as an intentional end — no "work continues behind the lock" phase; (2) the guard triggers on **any input**, not just trackpad; (3) config = two plain toggles on the item, internal model shaped as an effects set.

## Decisions

### D1 — Two effect categories inside the session, not a generic action chain
`KeepAwakeController` keeps a single start→arm→stop lifecycle and grows: a second snapshot/restore map (keyboard backlight, mirroring `savedBrightness`), heartbeat re-pin of both, and a `StopReason` (`.input` vs `.explicit`) that gates the one exit one-shot (lock). No per-item action lists, no editor chain UI — a future effect is one more seam entry + config flag.

### D2 — Any-input guard, layered on the existing arming rule
The existing arm gate (wait for one empty trackpad frame so the trigger can't self-cancel) stays the single arming point. On the ARM transition, if `lockOnStop` is set, the controller installs an input monitor via the effects seam; the monitor's callback and the existing `noteTouch` armed-contact path both call `stop(reason: .input)`.

`InputActivityMonitor` (new, Core) wraps **passive** `NSEvent` global + local monitors over `mouseMoved`, `left/right/otherMouseDown`, `keyDown`, `flagsChanged` — the `GlobalCursorMonitor` precedent; key-down global monitoring rides the already-granted Accessibility permission. Deliberate exclusions:

- **Trackpad contacts are NOT monitored here** — the raw touch stream (`noteTouch`) already covers every trackpad contact, sooner and more reliably.
- **`scrollWheel` is excluded** — a momentum tail from the firing gesture could otherwise self-trip the guard right at arm time; a stranger using a mouse fires `mouseMoved` before any scroll anyway.
- **Self-synthesized events are filtered by source PID** (`kCGEventSourceUnixProcessID == getpid()`): the app's own computer-use agent acts by posting CGEvents, and the guard must never lock the screen out from under an acting agent. Hardware events carry PID 0 and pass.

The monitors are removed *first* in `stop()`, before the lock fires, so the lock's own event fallout can't re-enter.

### D3 — Lock first, then restore (no unlocked flash)
Stop ordering on the input path: remove monitors → **lock** → restore keyboard backlight → restore displays → end assertion. If restore ran first, the unlocked desktop would flash at full brightness for a beat before the lock landed — exactly what a shoulder-surfer needs. Locking first means the lock screen is what fades in as brightness returns. On non-input paths the order is the same minus the lock.

The stopping input stays **non-consuming** (architecture unchanged): post-lock, a leaked gesture/keystroke lands on the lock screen, which is inert. The guard's job is the lock, not event suppression.

### D4 — Private API surfaces, crash-safe, with fallbacks (the `DisplayBrightness` pattern)
- **Lock:** `SACLockScreenImmediate` from `login.framework`, resolved via `dlopen`/`dlsym`; if unresolvable, fall back to posting the ⌃⌘Q lock keystroke as a CGEvent (public shortcut, rides Accessibility). Never a crash, no new permission.
- **Keyboard backlight:** `KeyboardBrightnessClient` from `CoreBrightness.framework`, resolved via `dlopen` + `NSClassFromString` + `responds(to:)`-guarded IMP casts (`copyKeyboardBacklightIDs`, `brightnessForKeyboard:`, `setBrightness:forKeyboard:`). Any resolution failure → no keyboard IDs → the effect is skipped, the session still runs (the undimmable-display rule). This is the one **runtime unknown**: selector availability across macOS versions is verified in the user's signed build, not assumable from `swift test`.

### D5 — Config rides the item as decode-safe optionals
`case automation(AutomationKind, dimPercent: Double? = nil, dimKeyboard: Bool? = nil, lockOnStop: Bool? = nil)` — synthesized Codable uses `decodeIfPresent`, so pre-existing items decode with `nil` (= off) and no schema bump (the `.url`/`.action` precedent, same as `dimPercent` itself). `LaunchService.onAutomation` grows from `(AutomationKind, Double?)` to `(AutomationKind, AutomationSettings)` — a small resolved-config struct — so the seam doesn't accrete positional optionals. The controller takes a `Config` (dim level fraction + the two flags); `start(dimTo:)`/`toggle()` remain as conveniences.

### D6 — Only the input path locks
`StopReason.input` = armed trackpad contact or monitor callback. `.explicit` = everything else (re-fire toggle, menu-bar Stop, quit, will-sleep). While guarded, the explicit paths are mostly unreachable anyway (reaching the menu bar moves the mouse → guard fires first) — but they must never lock: will-sleep locking would fight the OS sleep transition, and quit locking would turn "quit the app" into "lock the Mac."

## Risks / caveats

- **`KeyboardBrightnessClient` selector drift** across macOS versions — mitigated by `responds(to:)` guards (skip, never crash); user-run verification required.
- **One leaked input event pre-lock** — a stranger's first keystroke may reach the frontmost app before the lock lands (monitors are passive, not consuming). Accepted: the lock follows within milliseconds, and consuming would require a new event tap for marginal gain.
- **`mouseMoved` global monitor delivery** depends on some app requesting mouse-moved events — same dependency `GlobalCursorMonitor` (Dock previews) already ships with; the trackpad touch stream covers the by-far-common case regardless.
- **Guard + Hub open:** if our own app is frontmost, global monitors don't see our events — the local monitor covers that case.
