## Context

The four-finger launcher (`LauncherOverlayController`, `LauncherModel`, `LauncherView`, `LaunchService`) presents color-coded **context bands** of favorites in a non-activating panel. Navigation is purely trackpad: horizontal/vertical scrub moves a 2D grid cursor (`LauncherModel.stepHorizontal/stepVertical`), the selection arms after a dwell, and a lift fires it. The panel is deliberately `.nonactivatingPanel` / `ignoresMouseEvents` and never becomes key, so the app the user was in stays frontmost; the coordinator already captures that app at open time (`capturedFrontApp`, used today for "close front window"-style actions). Favorites persist as one small versioned `Codable` blob in `UserDefaults` (`FavoritesStore`).

A first framing of this feature was a keyboard-driven Raycast-style picker. That was rejected: a keyboard list must become the **key window**, which steals focus from the app you want to paste into and contradicts the app's "pure trackpad" identity. The reframe — **clipboard history as one more launcher band** — dissolves that problem: the non-activating overlay keeps the target app frontmost, so "pick an entry → paste where I was" reuses the existing front-app capture plus the existing dwell/lift firing, with no key window and no new gesture to learn.

## Goals / Non-Goals

**Goals:**
- Record clipboard history locally, opt-in and default OFF, capturing enough representations for a faithful re-paste of text, images, files, colors, and URLs.
- Present history as the **last** launcher band, built fresh each open from an on-disk store, navigated with the existing scrub/dwell/lift grammar.
- Master-detail rendering: a multi-line **key** list + a large **value** preview showing the entry's *actual content* (image / QuickLook file preview / text / color).
- Repurpose horizontal travel in this band: **RIGHT pins** (deferred reorder), **LEFT goes to the previous band**.
- **Edge-triggered scroll acceleration** so a long history is traversable without repeated lift-reposition-scrub.
- Paste on fire into the captured front app, using only the already-held Accessibility permission.
- Privacy-first: skip concealed/transient items, support app exclusions, pause, and clear; bound storage.

**Non-Goals:**
- No keyboard navigation, no key window, no global hotkey entry point (possible future; out of scope).
- No type-to-search/filter (no keyboard) — mitigated by recency window + pins + edge-accel, not by search.
- No crossing into / scrolling within the value preview pane (cut: dwell == paste makes a focusable preview redundant; the window is sized to show value alongside the keys).
- No new permission, no App Sandbox change, no native-gesture relocation, no re-login.
- No cloud sync; history is local-only.

## Decisions

### Decision: Clipboard history is a synthetic launcher band, not a separate picker
Reusing the launcher overlay keeps the target app frontmost (non-activating panel), so paste-into-front is free, and the scrub/dwell/lift muscle memory carries over verbatim. *Alternative — a keyboard-driven picker:* rejected; it must become key (focus theft) and breaks the trackpad-only model. The cost of the band approach is the inherent lack of keyboard search; accepted and mitigated (recency window, pins, edge-accel).

### Decision: The band is ephemeral and never stored in Favorites
The Clipboard band is rebuilt on every `show()` from the `ClipboardStore` (recent-window slice, pinned-first) and is never written into the Favorites `Codable` record nor made the home band. This keeps the curated-favorites model clean and lets the dynamic history change without touching `FavoritesStore`. *Implementation:* to reuse `LauncherModel`'s `[[LaunchItem]]` plumbing, clipboard entries are wrapped in a **synthetic, non-persisted item cell** that the editor cannot create and the serializer never writes. *Alternative — generalize `LauncherModel` to a "navigable cell" protocol:* cleaner typing but a bigger refactor; deferred. The synthetic-cell wart is contained and reversible.

### Decision: On-disk store, separate from UserDefaults/Favorites
History is heavy and binary (images), so it lives under Application Support: a small **index** (entries' keys, types, references, colors, pin state, timestamps, source app) plus **blob files** for large payloads (image bytes, cached thumbnails). The store is versioned for forward migration. *Alternative — UserDefaults:* wrong tool for binary growth. *Alternative — SQLite:* heavier dependency than v1 needs; a JSON index + blob directory is sufficient and trivially testable, and can be swapped for SQLite later if scale demands.

### Decision: Capture multiple representations; files by reference, images by bytes
For faithful paste, each entry stores the representations that matter: rich text keeps rich + plain fallback; an inline image keeps its bytes (it has no stable URL); a copied file keeps its **file-URL reference** (+ an optional cached content thumbnail) rather than copying bytes; colors/URLs keep their canonical string. A short single-line **key** is derived for the list. *Trade-off:* a file reference can go stale if the file moves/deletes — accepted; paste of a stale reference fails gracefully.

### Decision: Privacy is opt-in, concealed-aware, and bounded
The recorder is OFF by default and, when on, never records items tagged `org.nspasteboard.ConcealedType` / `TransientType` (the standard password-manager opt-out), never records copies from excluded apps, can be paused, and can be cleared. Storage is capped by count, bytes, and age with oldest-non-pinned eviction. This is the basis of trust for storing copied content at all.

### Decision: Horizontal repurposed in the Clipboard band (RIGHT = pin, LEFT = previous band)
A single-column list has no horizontal cursor to move, freeing the axis. RIGHT toggles the pin; LEFT is a fast exit to the previous band (the band is last, so "back" is leftward). Band entry remains available the normal way (rise to the headers strip, swipe to Clipboard, drop in). *Deferred reorder:* a pin does not reorder the live list mid-session (the selection would jump out from under the finger); pinned-first ordering is applied on the next build — matching the user's "pin now, use later" intent. *Accidental-pin guard:* horizontal must be a dominant step, with immediate visual + best-effort haptic feedback, and the toggle is one swipe to undo (and low-harm, since reorder is deferred). *Alternative — crossing into the value pane to scroll:* cut, per Non-Goals.

### Decision: Edge-triggered scroll acceleration
Finite trackpad travel + no search makes a long list painful to scrub manually. When the controlling contact sits in the edge zone (normalized position near 0/1 on the scroll axis) — or the selection hits the visible top/bottom with more list remaining — an accelerating auto-repeat advances the selection until the edge condition ends or the fingers lift. The touch engine already exposes normalized contact positions; the auto-repeat timer lives in the overlay controller, the edge signal in the recognizer. Edge zone / base rate / acceleration / max rate are tunable. *Alternative — velocity-based step multiplier* (faster scrub = bigger jumps): complementary, could be added later; edge-hold is the direct answer to "ran out of trackpad."

### Decision: Paste = restore representations + synthesize ⌘V into the captured front app
On an armed lift, the entry's representations are written to `NSPasteboard.general` and ⌘V is synthesized to the front-app pid captured at open (reusing `LaunchService.postKey`-style synthesis). The chosen entry becomes the current clipboard. No new permission (Accessibility already held). *Open item:* whether to restore the user's prior clipboard afterward (see Open Questions) — v1 does not.

### Decision: Detect copies by polling `changeCount`
macOS exposes no clipboard-change notification, so the recorder polls `NSPasteboard.general.changeCount` at a tunable interval (~0.5s) and snapshots only when it advances — the approach every clipboard manager uses. The poller runs only while the opt-in is on and not paused.

## Risks / Trade-offs

- **No keyboard search → long history is hard to scan.** → Mitigated by a recent-window slice (not the whole store), pinned entries first, edge-triggered acceleration, and two-finger relax for comfortable scrolling. Framed as "quick recent paste," not "searchable archive." Inherent to the trackpad model.
- **Persistent storage of copied (possibly sensitive) content.** → Default OFF; concealed/transient skip; app exclusions; pause; clear; byte/count/age caps; local-only. This is why the feature is strictly opt-in.
- **Synthetic clipboard cell inside the `LaunchItem` plumbing.** → Contained: non-persisted, not user-creatable, excluded from the editor and serializer; a future cell-protocol refactor can remove the wart.
- **Image storage growth.** → Byte cap + oldest-non-pinned eviction; thumbnails for file previews kept small.
- **Stale file references.** → Paste no-ops gracefully; key/thumbnail still shown; reference cleaned up on access failure.
- **Accidental pin while scrubbing (diagonal noise).** → Dominant-horizontal-step requirement + immediate feedback + one-swipe undo + deferred (low-harm) reorder.
- **`changeCount` polling overhead.** → Tiny at ~0.5s; runs only when enabled and not paused; tunable.
- **Pasting a file into a text field does nothing useful.** → Inherent macOS clipboard semantics, not a defect; the entry restores the same representation the original copy had.
- **Momentum scroll after lift nudging the background window.** → Same pre-existing exposure as the launcher today; movements are small and deliberate; no new mitigation.

## Open Questions

- **Restore the user's prior clipboard after a paste?** v1: no (the chosen entry becomes the clipboard, standard manager behavior). Possible v2 toggle ("paste without changing my clipboard").
- **Storage backend:** start with JSON index + blob directory; revisit SQLite only if entry counts/perf demand it.
- **Default tunables:** recent-window size, retention caps (count/bytes/age), poll interval, and edge-accel curve need sensible defaults chosen during implementation and then tuned on-device.
- **Pin gesture:** RIGHT as a toggle (pin ↔ unpin) is assumed; confirm vs. RIGHT-always-pins with unpin only from settings.
- **Future entry points:** a global hotkey (decoupled from the four-finger trigger) and a "clear last N minutes" privacy control are out of scope here but worth revisiting.
