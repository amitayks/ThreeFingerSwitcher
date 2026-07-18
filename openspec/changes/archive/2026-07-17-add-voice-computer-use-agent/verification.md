# Manual signed-build verification (`add-voice-computer-use-agent` + `model-idle-ttl-and-memory-pressure`)

Agent-side verification is DONE: `swift build` 0 errors, `swift test` 1606/1606 green, `xcodebuild`
compile-verify (app target incl. GemmaRuntime) exit 0. Everything below needs the user's
stable-signed build (`INSTALL=1 ./scripts/build-app.sh`) because it exercises live TCC-gated
behavior (mic, AX, pressure) the agent shell cannot.

## Idle-TTL + memory pressure

1. Hub → AI: set "Free model memory after" to 15 minutes. Run one AI command (model loads → row
   "Loaded"). Close every chat, wait ~16 min → row reads "Ready" (weights on disk, RAM freed).
2. Next AI command transparently reloads (loading state, then a normal reply — no error).
3. With a chat OPEN and idle: `sudo memory_pressure -S -l warn` → model stays resident.
   `sudo memory_pressure -S -l critical` (no turn streaming) → evicted; next message reloads.
4. TTL "Never" → nothing evicts on idle (pressure still armed).

## Voice (macOS 26)

5. Hub → AI → Voice conversation ON (needs AI opt-in). First HOLD of Right Option → the mic
   permission prompt appears (not at enable time). Deny once → clean card with Settings link; allow
   → speak "what time is it", release → transcript runs a turn, the reply speaks sentence-by-sentence
   while still generating.
6. Barge-in: while it speaks, press Right Option again → speech stops instantly, mic is live.
7. Any trackpad touch while it speaks/thinks → it stops (abort, mic does NOT open).
8. Menu bar → "Speak Last Response" with a terminal frontmost showing a Claude reply → it reads the
   last response aloud (works with voice toggle OFF; uses the model when resident, last-lines
   fallback otherwise).

## Computer use

9. Hub → AI → Computer use ON. In a chat: "read my terminal window" → a read_window step returns the
   window text (no screenshot). "click the Send button in Messages" → an approval card previews the
   element; approve → click + verify; the step reports what changed.
10. "type hello into TextEdit and press return" → approval preview shows the exact text; approve →
    typed via tagged synthetic keys (⌘-Tab switcher must NOT trigger during it).
11. Auto mode: say/type "enable auto mode" → the ONE approval card; after it, acts run hands-free,
    each narrated. "disable auto mode" → instant, no card.
12. Kill switch: start a multi-step task, touch the trackpad mid-act → everything stops immediately
    as a discard (no failure card).
13. AX desert: try read_window on a game/canvas app → an honest "Can't read this window" card, never
    a guess.

## Regression (both flags OFF)

14. With voice + computer-use OFF: switcher, launcher, clipboard, Dock previews, ⌘-Tab, notch
    sessions behave byte-identically; no new tools appear in AI chats; no mic prompt ever fires.
