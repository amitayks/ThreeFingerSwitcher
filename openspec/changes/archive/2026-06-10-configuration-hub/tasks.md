## 1. Hub window shell + Overview

- [x] 1.1 Add a `HubView` SwiftUI shell using `NavigationSplitView` with a glass/material sidebar; define the sidebar destinations enum (Overview; Content→Bands; Features→Switcher/Spaces/Launcher/Clipboard/AI; System→Setup/General) and a detail router that swaps pages by selection.
- [x] 1.2 Factor the shared Liquid Glass / material treatment used by `LauncherView`/`ClipboardBandView`/`SwitcherView` (glassEffect + ultraThinMaterial, with the existing macOS-availability fallback) into a reusable style the Hub sidebar and grouped cards use.
- [x] 1.3 Add `AppCoordinator.hubWindow` + `showHub(selecting:)` that creates-or-reuses one `NSWindow` (`isReleasedWhenClosed = false`, frame autosave name "HubWindow"), brings it forward, and optionally deep-links a sidebar selection.
- [x] 1.4 Build the **Overview** page: a material-grouped list of every feature master toggle (switcher `enabled`, `manageVerticalGesture`, `enableLauncher`, `keepClipboardHistory`, `aiCommandsEnabled`) bound to `AppSettings`, each row a disclosure that deep-links to its feature page.
- [x] 1.5 Add a temporary "Open Hub" status-menu item routing to `showHub` (kept alongside the old menu items until phase 6) so the Hub is reachable during development.
- [x] 1.6 Verify: `swift build` and `swift test` (Core + tests) pass; `xcodebuild` compile-verifies the app target.

## 2. Feature pages (fold SettingsView)

- [x] 2.1 Create per-feature pages — Switcher (sensitivity + behavior), Spaces (vertical gesture opt-in + row tunables), Launcher (opt-in + tunables), Clipboard (opt-in + retention/poll/edge/pin tunables + excluded-apps editor + clear buttons), AI (opt-in + `ModelManagementView` re-host + model picker) — each binding the SAME `AppSettings` properties via the existing `slider`/`intSlider`/excluded-apps/model-picker helpers (no new keys, defaults, or persistence).
- [x] 2.2 Create the **General** page: reliability (focus watchdog), show-diagnostics toggle, Open-at-Login, and Reset to defaults — preserving `resetToDefaults()` carve-outs exactly.
- [x] 2.3 Keep each disabled feature's page reachable with its controls shown disabled (mirror today's disabled `Form` sections).
- [x] 2.4 Move the diagnostic actions (write diagnostics, copy focus log) onto the General page, shown only when the show-diagnostics preference is on.
- [x] 2.5 Verify: every former `SettingsView` control has an equivalent on a feature page bound to the identical setting; `swift build`/`swift test` pass; `xcodebuild` compile-verifies.

## 3. Setup page (fold Onboarding)

- [x] 3.1 Build the **Setup** page hosting the permission status/guidance (Accessibility, Screen Recording, Input Monitoring) with live status and deep-links to System Settings, plus the native-gesture opt-ins (free three-finger swipe, Space-row switching, spaces rearrange, four-finger launcher) — porting `OnboardingView`'s content into the page.
- [x] 3.2 Surface the native-gesture/spaces opt-in triggers + live status on the Setup page. The system-setting confirmations themselves remain momentary, user-initiated `NSAlert` confirmations (they gate an irreversible re-login system change; not AI background failures) — see design D7; the page re-reads state after each action.
- [x] 3.3 Repoint `AppCoordinator.showOnboarding` callers to `showHub(selecting: .setup)`; delete `OnboardingView` and `AppCoordinator.onboardingWindow`.
- [x] 3.4 Verify: permissions/setup reachable only via the Hub; `swift build`/`swift test` pass; `xcodebuild` compile-verifies.

## 4. Bands canvas (fold FavoritesEditor)

- [x] 4.1 Port `FavoritesEditorView` (sources picker | bands list | items grid + inspectors, drag-reorder, file/script pickers, appearance editors) into a **Bands** page hosted in the Hub, bound to `FavoritesStore`.
- [x] 4.2 Ensure the Bands page edits only authored bands; the clipboard "live band" is not listed for item authoring there.
- [x] 4.3 Repoint `AppCoordinator.showFavoritesEditor` callers to `showHub(selecting: .bands)`; make "Add Front App to Band" optionally deep-link the Hub to the target band; delete the standalone `FavoritesEditorView` window + `favoritesEditorWindow`.
- [x] 4.4 Verify: bands/items editing works in the Hub; `swift build`/`swift test` pass; `xcodebuild` compile-verifies.

## 5. AI fold-in + migration

- [x] 5.1 Flip `LaunchItem.kind.aiCommand(AICommand)` from synthetic/ephemeral to a persisted, first-class case; ensure `AICommand` + nested enums serialize inside `ContextBand.items`; bump `Favorites.schemaVersion`.
- [x] 5.2 Implement the one-time, idempotent migration (Core, pure/testable): if upgrading and `UserDefaults["aiCommands"]` exists, decode it, build a normal "AI" band (name "AI", former AI-band color) preserving command IDs + order, append once, write the bumped record, then retire the old key; guard by schema version.
- [x] 5.3 Reconcile seeding: `FavoritesStore.seeded()` also seeds the default "AI" band with the 6 starter commands (fresh installs); ensure migrate-vs-seed are mutually exclusive.
- [x] 5.4 Add the **AI Command** source to the Bands source picker; make the item inspector polymorphic — render the absorbed AI-command inspector (name/icon/tint, input, prompt template + token bar, output target with task/destination detail, model selector, confirm-before-run) when the selected item is `.aiCommand`.
- [x] 5.5 Add the fire-time **unavailable** state to `AICommandCanvasView`: when AI is off or the model isn't ready, open the canvas with a clean headline (via `AIError`/`AIPresentedError`), an Enable affordance, a Download action, and a model picker; make it dismissable via horizontal discard with the download continuing in the background; route normal streaming when ready.
- [x] 5.6 Remove launcher-side AI gating: stop filtering/hiding `.aiCommand` items by opt-in; project them from the Favorites record like any item.
- [x] 5.7 Delete `AICommandStore`, `AICommandBandBuilder`, `AICommandEditorView`, and the "Manage AI commands…" sheet; repoint the executor to take the `AICommand` from the fired `LaunchItem`.
- [x] 5.8 Tests: `Favorites` round-trip encode/decode with `.aiCommand` items; migration unit tests (had-commands, never-opted-in, already-migrated/idempotent, empty record); forward-decode of a pre-fold-in record.
- [x] 5.9 Verify: `swift build`/`swift test` pass; `xcodebuild` compile-verifies the MLX-linked app/GemmaRuntime target (Core stays MLX-free).

## 6. Delete old windows + trim the menu

- [x] 6.1 Delete `SettingsView` and `AppCoordinator.settingsWindow`; collapse `showSettings`/`showFavoritesEditor`/`showOnboarding` into `showHub(selecting:)`.
- [x] 6.2 Trim `StatusItemController` to: Open Hub, quick Switcher enable/disable, Add Front App to Band ▸, Quit (plus the no-trackpad indication); remove Settings…, Favorites…, Open at Login, launcher status, gesture-restore, and diagnostics menu items.
- [x] 6.3 Remove now-dead coordinator code (orphaned NSAlert prompts, window plumbing) left by the deletions.
- [x] 6.4 Verify end-to-end: only the Hub window exists for configuration; `swift build`/`swift test` pass; `xcodebuild` compile-verifies. (Real app build/sign/install + permission testing is the user's task in their own Terminal.)

## 7. Spec sync

- [x] 7.1 After implementation is verified, run `/opsx:sync` (or `openspec`) to fold the delta specs into `openspec/specs/` and confirm the change is ready to archive.
