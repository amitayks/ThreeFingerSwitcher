# Design — hub-danger-zone

## Context

The app's footprint: the preferences domain (`com.threefingerswitcher.app` — settings, favorites/bands, AI command items, keyboard-language map, first-run state, **and the gesture backups**), `~/Library/Application Support/ThreeFingerSwitcher/` (subdirs `clipboard/`, `projects/`, and the multi-GB `models/`), `~/Library/Caches/<bid>` + `~/Library/HTTPStorages/<bid>`, saved window state, and TCC grants (Accessibility, ScreenCapture, ListenEvent, AppleEvents, Calendar, Reminders, AddressBook). The trackpad/Dock relocations live in SYSTEM domains and are only recoverable via the backups stored in the app's own preferences — which is why a naive data wipe strands them.

## Goals / Non-Goals

**Goals:** selective, explicit, confirmed in-app deletion per category; never strand a relocation; end in a coherent state (fresh relaunch when identity-level state was cleared); a one-button restore-everything for gestures.

**Non-Goals:** uninstalling the .app bundle (Finder's job); factory-resetting trackpad keys with no backup (the backups exist for every app-made change; foreign changes aren't ours to delete); a sudo path (user-level `tccutil` suffices for our services).

## Decisions

- **D1 — Restore gestures before wiping app data.** If App data is selected and any gesture/Spaces backup exists, run the restore-all path first and say so in the confirmation. Rationale: the backups live inside the data being deleted; order is the only thing standing between "clean reset" and "stranded relocations". Alternative (warn only): rejected — the failure is silent and system-level.
- **D2 — AI models are their own toggle, split from App data.** The weights are multi-GB and re-downloadable; users plausibly want to keep them across a settings reset (or clear only them). App data therefore deletes Application Support EXCEPT `models/`; both selected ⇒ the whole root goes. The AI opt-in is turned off before deleting weights (evicts residency, forgets progress).
- **D3 — Wipe preferences LAST, then relaunch immediately.** The in-memory `AppSettings` keeps writing through `didSet`; any write after `removePersistentDomain` resurrects the domain. Ordering the domain wipe last and terminating into the relaunch right after minimizes the window; the relaunch guards (`isRelaunching`) already suppress quit-time restores. A fresh process reads the cleared prefs → the First Touch wizard plays again.
- **D4 — Permissions via `/usr/bin/tccutil reset <Service> <bid>`** per service, behind a command seam (testable). Resetting our own bundle's user-level TCC needs no privileges. After a permissions reset the relaunch re-enters the wizard's permission acts naturally if data was also cleared, or the Setup safety net otherwise.
- **D5 — One confirmation, in the established alert idiom.** This is a user-initiated destructive action (not a background failure), so a modal confirm listing the selected categories — including the restore-first and relaunch consequences — is the right surface. The button stays disabled while nothing is selected.
- **D6 — `restoreAllNativeGestures()` drives the existing per-feature paths**: flip the three opt-in flags off (their observers restore from backups absent-aware and clear pending markers) + restore the horizontal backup directly. No new restore machinery; one re-login note for the trackpad keys.

## Risks / Trade-offs

- **[`tccutil` blocked by management policy]** → per-service result collected; failures reported in the summary, never fatal.
- **[Concurrent writers during the wipe (clipboard monitor re-creating dirs)]** → monitors are stopped before deletion; the relaunch path makes any residue moot for the prefs domain.
- **[User clears permissions only, app keeps running without AX]** → existing degradation paths already handle revoked permissions; the completed-install safety net opens Setup on next launch.

## Open Questions

(none — scope is fixed by the request)
