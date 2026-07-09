# Tasks — canvas bidi + selection fixes

## 1. Fix 1 — first-strong, stable, all RTL scripts (`Overlay/BidiText.swift`)
- [x] 1.1 `isStrongRTL` covers the full `U+0590–U+08FF` RTL block + presentation forms (all RTL scripts)
- [x] 1.2 `BidiText.apply` picks each paragraph's base from `firstStrongDirection` (first word/char decides, stable)
- [x] 1.3 `naturalTextDirection(for:)` uses `firstStrongDirection`
- [x] 1.4 Remove `dominantDirection`; update doc comments (first-strong, stable)

## 2. Fix 2 — read selection before the panel takes key
- [x] 2.1 `AICommandExecutor`: `onReadyForInteraction` hook, called after acquisition + in the `.unavailable` branch
- [x] 2.2 `AICommandExecutor`: refactor the input read into `acquire(_:) -> Acquisition`; retain it; `fire(reuseInput:)` + `run(reuseInput:)`
- [x] 2.3 `AICommandExecutor`: `setLanguage` re-fires with `reuseInput: true` (reuse the acquired source, don't re-read)
- [x] 2.4 `LauncherOverlayController`: drop `setCanvasInteractive(true)` from the fire / `showCanvas` paths; add guarded `makeCanvasInteractive()`
- [x] 2.5 `AppCoordinator`: wire `aiCommandExecutor.onReadyForInteraction = { launcherOverlay.makeCanvasInteractive() }`

## 2b. Fix 2b — the ⌘C fallback lands (on-device diagnosis via `[Selection]` logging)
- [x] 2b.1 `SelectionService`: diagnostic `os.Logger` (category `Selection`) across `readSelectedText` / `copyWithRestore` + the executor's channel resolution — surfaced the real failure (`⌘C changeCount advanced=false` for Terminal)
- [x] 2b.2 `copyWithRestore` re-asserts the captured app as frontmost (`activate` + 40ms settle) before synthesizing ⌘C — mirrors the working paste path; a ⌘C posted to a non-active app didn't land
- [x] 2b.3 Detect + log **Secure Keyboard Entry** (`IsSecureEventInputEnabled()`) so a system-wide synthetic-key block is diagnosable, not a silent clipboard fall-through
- [x] 2b.4 `selection-io` spec delta: activate-before-copy + Secure-Keyboard-Entry behavior

## 3. Tests
- [x] 3.1 `BidiTextDirectionTests`: first-strong decides + is stable as content appends; leading-neutral skip; all RTL scripts; neutral→LTR; strong-class guards
- [x] 3.2 `AICommandExecutorTests`: interaction hook fires once after acquisition; a language re-run reuses the retained input rather than re-reading a changed selection
- [x] 3.3 `SelectionServiceTests` still green after the `copyWithRestore(pid:)` → `copyWithRestore(app:)` signature change

## 4. Verify
- [x] 4.1 `swift build` — clean
- [x] 4.2 `swift test` — 1491 tests, 0 failures
- [ ] 4.3 User confirms on a signed build: (a) a command with text selected uses the selection (down-swipe replaces); with nothing selected uses the clipboard (pastes); (b) a Hebrew translation anchors each line by its first word and stays stable while streaming
- [ ] 4.4 Apply the `launcher-overlay` delta to the main spec at archive (`/opsx:archive` / `/opsx:sync`)
