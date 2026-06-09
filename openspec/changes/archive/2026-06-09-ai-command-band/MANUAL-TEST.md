# AI Command Band — signed-build manual-test checklist

Everything below requires a **stable-signed install** (`INSTALL=1 ./scripts/build-app.sh`) — ad-hoc agent builds break TCC grants. The headless logic is unit-tested (433 tests); this list covers what can only be validated on-device: Accessibility/clipboard/screen capture, EventKit, and the gesture *feel*.

Two modes:
- **Now (stub runtime):** the band runs against `DevAIRuntime`/`StubLLMRuntime` (no download). Output is scripted/echoed — enough to validate the *interaction* (band, canvas, swipe-to-resolve commit/discard, routing, permissions). Steps marked **[feel]** work in this mode.
- **After Phase 10 (real Gemma 4 via MLX):** wire `GemmaMLXRuntime` + the SwiftPM deps in Xcode (see tasks.md phases 1.3–1.4, 10.1–10.6), then the **[model]** steps (real transforms, vision, calendar parsing) become meaningful.

## Setup
- [ ] Enable the opt-in: Settings ▸ AI commands ▸ "Enable AI commands" (default OFF). Confirm the launcher shows an **AI band** only after enabling **and** with ≥1 command configured.
- [ ] Confirm turning the opt-in OFF removes the band and (with a real model) evicts it from memory.

## Selection I/O (Accessibility) — **[feel]**
- [ ] Select text in **TextEdit**, dwell on **Fix Grammar**, lift → the **canvas opens** (overlay does NOT dismiss), the front app stays frontmost, output streams in.
- [ ] Non-destructive read: put a distinctive string on the clipboard first; after firing, paste elsewhere → clipboard **unchanged** (AX read path).
- [ ] Repeat the selection read in **Safari**, **VS Code**, **Notes**. For any app where AX yields nothing, confirm the **⌘C-with-restore** fallback still captures the selection and restores the prior clipboard.
- [ ] Sensitive-clipboard restore: copy a password (from a password manager), select text in an app needing the ⌘C fallback, fire, then paste the clipboard → the **password is restored unchanged**.
- [ ] `replaceSelection` via AX (settable field, e.g. TextEdit): commit → selection replaced **in place**, no clipboard flicker.
- [ ] `replaceSelection` paste fallback (non-settable field, e.g. some web editors): commit → delivered by ⌘V, prior clipboard restored.
- [ ] No-input path: nothing selected + empty clipboard, fire a selection command → canvas shows **"No input"**, model not run.

## Swipe-to-resolve: commit / discard (gesture feel) — **[feel]**
The canvas opens with the fingers already lifted (from the firing swipe), so it is resolved by a **fresh four-finger swipe**, never by re-lifting.
- [ ] **Commit (swipe down):** from a ready canvas, a fresh four-finger **down** swipe routes the result per output target and dismisses — it should feel like "bringing the result down into the document."
- [ ] **Discard (swipe sideways):** while streaming OR ready, a fresh four-finger **horizontal** swipe past the threshold → generation cancels, **nothing written**, overlay dismisses. Tune the activation distance so a wobble never resolves but one deliberate swipe does — **the main feel knob**.
- [ ] **Down swipe while still streaming:** a down swipe before the result is ready is **ignored** (the canvas waits) — confirm it does not commit empty and does not get stuck.
- [ ] **Up swipe is inert:** a fresh four-finger **up** swipe does nothing (never throws the result away).
- [ ] **Stray re-lift is inert:** putting fingers down and lifting again (no swipe) neither commits nor discards — the canvas stays open.
- [ ] Front app stays key throughout; the overlay never becomes the key window.

## Background tasks — **[feel]** for routing, **[model]** for parsing
- [ ] **Add to Calendar, confirm ON (default):** fire over meeting text → canvas shows loading, then the **armed-confirmation review** of the parsed event fields. Nothing applied yet. A down-swipe commit fires EventKit create; a horizontal discard swipe cancels with no event.
- [ ] **EventKit lazy permission:** the macOS Calendar prompt appears on the **first** calendar commit (not at launch / not at opt-in).
- [ ] **Calendar denied:** deny (or revoke in System Settings) → committing a calendar action creates **no event**, the canvas shows **"Calendar access is required…"** (human message, not a raw enum), and other AI commands keep working. Verify the Settings deep-link.
- [ ] **Confirm OFF:** toggle `confirmBeforeRun` off for a task command in the editor → it commits the side effect directly (no extra review state).
- [ ] **Decline (not fabricate) [model]:** run Add to Calendar over text with **no meeting** → the model **declines** ("not applicable"); **no phantom event** is created.
- [ ] **Save to project:** confirm content appends to the per-project note on disk (Application Support).
- [ ] **Send-to / Open-tool:** confirm routing to the configured Shortcut / URL scheme / app.

## Vision (screen region) — **[model]**
- [ ] With Screen Recording granted, fire a `screenRegion` command → a capture is fed to the vision model and answered.
- [ ] Revoke Screen Recording → the command reports **unavailable**, no crash. (Note: the interactive region *picker* is deferred — today this captures the main display.)

## Model lifecycle — **[model]**
- [ ] Opt-in OFF → ON: model download starts (resumable, integrity-verified); canvas shows a **loading** state on first use, not a silent block.
- [ ] Residency: a second command does not pay a full cold-load.
- [ ] Opt-in ON → OFF: model evicted from memory.
- [ ] Global model picker (Settings) writes `aiSelectedModelID`; the management surface reflects the selected model + size + status.

## Regression sanity (must be unchanged)
- [ ] Non-AI launcher items (apps/actions/clipboard) still **lift-fire-and-dismiss** exactly as before; Space-switch actions don't drag the overlay onto the destination Space.
