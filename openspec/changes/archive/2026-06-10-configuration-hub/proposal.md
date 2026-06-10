## Why

Configuration has drifted across four disconnected surfaces — a Settings window, a Favorites editor window, a Setup/Onboarding window, and an AI Command editor sheet — plus inline model management and a half-dozen modal alerts. As features keep arriving, this sprawl gets worse and the natural overlaps (an AI command is just another launchable item) stay artificially walled off. We need one place to configure everything.

## What Changes

- **NEW: a single Hub window** with an Overview landing page (every feature's master toggle at a glance) and a grouped sidebar — `Content → Bands`; `Features → Switcher / Spaces / Launcher / Clipboard / AI`; `System → Setup / General`. It uses the Liquid Glass / material language already used by the runtime overlays.
- **BREAKING: delete the Settings window, the Favorites editor window, the Setup/Onboarding window, and the AI Command editor sheet.** Their content is reborn as Hub pages. The three retained `NSWindow`s on `AppCoordinator` collapse to one `hubWindow`; `showSettings`/`showFavoritesEditor`/`showOnboarding` collapse to `showHub`.
- **BREAKING: AI commands fold into the band model.** `LaunchItem.kind.aiCommand` becomes a persisted, first-class, movable item (no longer "synthetic & ephemeral"). `AICommandStore` and `AICommandBandBuilder` are deleted; AI commands persist inside `Favorites` bands and can live in **any** band. A one-time, idempotent migration imports existing `aiCommands` into a normal, editable "AI" band (preserving IDs). The Bands canvas gains an "AI Command" item source and edits AI-command fields inline.
- **CHANGE: AI gating moves out of launcher projection.** AI-command items are never hidden or filtered — they always show and fire. Firing one while AI is disabled or the model is undownloaded opens the AI preview canvas in an **unavailable** state offering Enable / Download plus a model picker; the canvas is dismissable and any download continues in the background. This routes through the existing `AIError`/`AIPresentedError` taxonomy (bounded, non-blocking, no app-modal alert).
- **CHANGE: the status menu shrinks** to Open Hub…, a quick Switcher enable/disable toggle, "Add Front App to Band ▸", and Quit. Everything else moves into the Hub; the modal-alert confirmations (free gesture, spaces rearrange, vertical gesture, launcher setup, restore) become inline in-page flows on the Setup page.
- **UNCHANGED: the model/store layer.** `AppSettings` (all persisted prefs and opt-in/reset semantics), `FavoritesStore` (now also holds AI commands), `ClipboardStore` (the clipboard band stays synthetic; clipboard is configured only on its feature page), `ModelManager`/`ModelManagementView` (re-hosted on the AI page).

## Capabilities

### New Capabilities
- `configuration-hub`: the single Hub window, its Overview landing page, grouped-sidebar navigation, the per-feature pages, and the Liquid-Glass/material presentation that all former configuration surfaces fold into.

### Modified Capabilities
- `favorites-editor`: the dedicated favorites window is removed; the band/item editing canvas becomes the Hub's Bands page, and gains an AI-command item source + inline AI-command editing.
- `ai-command-band`: AI commands become persisted, movable band items (not a synthetic opt-in band); they can live in any band; the opt-in no longer hides them; firing an AI item when AI is unavailable opens the canvas in an Enable/Download state instead of being hidden; existing commands are migrated into a normal "AI" band.
- `tunable-settings`: the Settings window is removed; all tunables and master toggles move to the Hub's Overview and Feature pages with identical persistence and reset semantics; AI-command authoring is no longer reached from Settings (it moves to the Bands page).
- `permissions-onboarding`: the standalone Setup window is removed; permissions status and native-gesture opt-ins become the Hub's Setup page.
- `menubar-app-shell`: the status menu is trimmed to Hub entry + a few quick actions; all configuration entry points route to one Hub window; the favorites entry opens the Hub's Bands page.
- `launcher-overlay`: AI-command items always project; availability is resolved at fire time in the preview canvas (Enable/Download + model picker) instead of by hiding items.

(Clipboard configuration UI is already governed by `tunable-settings`; the synthetic clipboard band is unchanged, so `clipboard-history` needs no requirement change. AI task execution/contract behavior is unchanged, so `ai-command-tasks` needs no requirement change. The rule that the Bands page edits only *authored* bands — excluding the clipboard "live band" — is captured under the new `configuration-hub` capability.)

## Impact

- **Deleted views:** `SettingsView`, `FavoritesEditorView`, `AICommandEditorView`, `OnboardingView`.
- **Deleted model glue:** `AICommandStore`, `AICommandBandBuilder` (folded into `FavoritesStore` + the band model).
- **New views:** the Hub window host + `HubView` shell and its pages (Overview, Bands, Switcher, Spaces, Launcher, Clipboard, AI, Setup, General), plus an "unavailable" state in `AICommandCanvasView`.
- **Modified:** `AppCoordinator` (one `hubWindow`/`showHub`, inline Setup confirmations), `StatusItemController` (trimmed menu), `LaunchItem`/`Favorites` (persisted `.aiCommand`, schema bump + migration), `FavoritesStore` (seed reconciliation + migration), `AICommandCanvasView`/`AICommandExecutor` (fire-time availability gating).
- **Data migration:** `Favorites.schemaVersion` bump; one-time import of `UserDefaults["aiCommands"]` into an "AI" band; old key retired.
- **Verification:** `swift build`/`swift test` for MLX-free Core + tests; `xcodebuild` compile-verify for the MLX-linked app/`GemmaRuntime` target. No agent-shell app build/sign/install.
