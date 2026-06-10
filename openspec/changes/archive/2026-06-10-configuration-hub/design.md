## Context

Configuration is spread across four AppKit-hosted surfaces, all opened through `AppCoordinator`:

- **Settings** — `NSWindow` → `SettingsView` (460px, a 9-section grouped `Form`), retained as `AppCoordinator.settingsWindow`.
- **Favorites** — `NSWindow` → `FavoritesEditorView` (860×600, 3-pane sources | bands | items), retained as `favoritesEditorWindow`.
- **Setup/Onboarding** — `NSWindow` → `OnboardingView` (520px, permissions + native-gesture opt-ins), retained as `onboardingWindow`.
- **AI Command editor** — a SwiftUI `.sheet` inside `SettingsView` → `AICommandEditorView` (2-pane command list | inspector).

Plus `ModelManagementView` shown inline in Settings, and ~6 `NSAlert.runModal` confirmations driven from the status menu / coordinator.

The model layer is already clean and stays: `AppSettings` (UserDefaults-backed, ~31 published prefs with deliberate opt-in/reset carve-outs), `FavoritesStore` (`@Published Favorites`, `mutate`+`save`), `AICommandStore` (`@Published [AICommand]`), `ClipboardStore` (on-disk index + blobs), `ModelManager`. The launcher already renders everything as one type: a `ContextBand` of `LaunchItem`s, where `kind` already has `.aiCommand(AICommand)` and `.clipboardEntry(ClipboardEntry)` cases — today marked "synthetic & ephemeral" and projected at launcher-open by `AICommandBandBuilder` / `ClipboardBandBuilder`.

Constraint (CLAUDE.md): Core stays MLX-free and verifiable with `swift build`/`swift test`; the app/`GemmaRuntime` target compile-verifies with `xcodebuild` only. No app build/sign/install from the agent shell.

## Goals / Non-Goals

**Goals:**
- One window for all configuration; the four surfaces above are deleted, not hidden.
- The band is the single content primitive: AI commands become real, movable, persisted band items editable inline alongside apps/files/scripts.
- Visual continuity with the runtime overlays (Liquid Glass / material).
- AI items always present and fire; availability is resolved in the AI canvas, not by hiding items.
- Preserve every existing tunable, its persistence key, default, and opt-in/reset semantics. Preserve user data through migration (command IDs survive).

**Non-Goals:**
- No change to gesture mechanics, the launcher's runtime navigation, the switcher/clipboard overlays, or the AI execution/runtime seam (`LLMRuntime`, `AICommandExecutor` task dispatch) beyond the fire-time availability check.
- The clipboard band stays synthetic — clipboard entries are captured data, never authored in the Bands canvas. The same "live band" model is reserved for future auto-populated bands.
- No new model backends, no vision, no cloud.

## Decisions

### D1. One Hub window hosting a SwiftUI `NavigationSplitView`
A single `NSWindow` (retained as `AppCoordinator.hubWindow`, `isReleasedWhenClosed = false`, frame autosaved) hosts an `NSHostingController<HubView>`. `HubView` is a `NavigationSplitView`: a glass sidebar of destinations and a detail column that swaps the selected page. `AppCoordinator.showHub(selecting:)` creates-or-reuses the window, brings it forward, and optionally deep-links a sidebar selection (so the menu's "Add Front App to Band" and any "open to the AI page" callers land on the right page).

- **Sidebar destinations:** `Overview`; `Content` → `Bands`; `Features` → `Switcher`, `Spaces`, `Launcher`, `Clipboard`, `AI`; `System` → `Setup`, `General`.
- **Overview** is the landing page: a material-grouped list with every feature's master toggle (Switcher `enabled`, `manageVerticalGesture`, `enableLauncher`, `keepClipboardHistory`, `aiCommandsEnabled`) and a chevron deep-linking to each feature page. Toggling here writes the same `AppSettings` property the feature page binds.
- *Alternative considered:* a top tab-bar. Rejected — a sidebar scales better as features keep arriving (stated requirement) and matches macOS settings conventions.

### D2. Feature pages are thin re-homings of existing controls
Each feature page binds the **same** `AppSettings` properties via the same helpers (`slider`/`intSlider`/excluded-apps editor/model picker). No new persistence, no new keys, no changed defaults; `resetToDefaults()` keeps its exact carve-outs (`manageVerticalGesture`, `enableLauncher`, `manageSpacesRearrange`, `keepClipboardHistory`, `clipboardExcludedApps`, `aiCommandsEnabled`, `aiSelectedModelID` not reset). The page just relocates the controls into a sidebar destination with breathing room instead of one 460px scroll. A disabled feature keeps its page visible (controls disabled, like today's disabled `Form` sections) so it can be re-enabled.

### D3. AI commands fold fully into the band model (the core decision)
`LaunchItem.kind.aiCommand(AICommand)` becomes a **persisted, first-class** case (drop the "synthetic & ephemeral" treatment). `AICommand` and its nested enums (`InputSource`, `OutputTarget`, `TaskKind`, `Destination`, `ModelSelector`) are already `Codable`, so they serialize cleanly inside `ContextBand.items` in the `Favorites` record.

- `AICommandStore` and `AICommandBandBuilder` are **deleted**. AI commands live wherever the user puts them — any band — and move by drag like any item.
- The Bands canvas (former `FavoritesEditorView`) gains an **"AI Command"** source in its add-item picker; picking it creates an `.aiCommand` item with a sensible default and selects it. The item inspector becomes polymorphic: the former `AICommandInspector` (name/icon/tint, input source, prompt template + token bar, output target with task/destination detail, model selector, confirm-before-run) renders when the selected item's kind is `.aiCommand`; the existing simple inspectors render for `.app`/`.action`/etc.
- **Execution is essentially unchanged:** a fired `LaunchItem.kind.aiCommand(cmd)` already carries the full `AICommand` to `AICommandExecutor`. Only the *authoring/persistence* path moves (FavoritesStore instead of AICommandStore).
- *Alternative considered:* a reference model (`.aiCommandRef(UUID)` pointing at a retained `AICommandStore`). Rejected — keeps two stores, allows dangling refs, and leaves the command "living" in the AI band, contradicting the goal of *moving* a command out of the AI band.

### D4. Seed reconciliation + one-time idempotent migration
Today two seed paths exist: `FavoritesStore.seeded()` (Dev/Comms/Media/System bands) and `AICommandStore.seeded()` (6 commands: Fix Grammar, Make Concise, Translate, Explain, Summarize, Add to Calendar).

- **Fresh install:** `FavoritesStore.seeded()` additionally appends a normal "AI" band (name "AI", the former `AICommandBandBuilder` color) containing the 6 seeded commands as `.aiCommand` items.
- **Upgrade migration:** bump `Favorites.schemaVersion`. On load, if the new version predates the AI fold-in **and** `UserDefaults["aiCommands"]` exists, decode that `Stored` blob, build an "AI" band from its commands (**preserving each command's `id`** — IDs key the executor and SwiftUI), append it once to `bands`, write the bumped record, and retire the old key. Guard with the schema version so it never runs twice (idempotent). If `aiCommands` is absent (never opted in), seed the default AI band instead. This logic is pure/Core-testable.

### D5. AI availability is resolved at fire time, in the canvas — not by hiding items
The launcher stops calling `AICommandBandBuilder.shouldPresent` / filtering by opt-in. AI items always project and are always fireable. When an `.aiCommand` is fired:

- If AI is enabled and the selected model is loaded/ready → run as today (streaming preview canvas).
- If AI is **disabled** or the model is **not downloaded/ready** → `AICommandCanvasView` opens in an **unavailable** state: a clean headline (via the `AIError`/`AIPresentedError` translator), an **Enable** affordance (flips `aiCommandsEnabled`), a **Download** action, and a **model picker** (binds `aiSelectedModelID`). The canvas is dismissable with the normal swipe-to-resolve gesture; a started download continues in the background via `ModelManager`. No app-modal alert — bounded and non-blocking per the AI error convention.
- *Alternative considered:* hide AI items when AI is off (the earlier explore default). Rejected by the user — discoverability wins; the canvas becomes the single funnel that turns AI on.

### D6. Liquid Glass continuity — reuse the overlays' treatment
The runtime overlays already use `.glassEffect(.regular)` and `.ultraThinMaterial` (`LauncherView`, `ClipboardBandView`, `SwitcherView`) under the existing macOS-26 availability handling (deployment target is macOS 15). The Hub reuses the same idiom: a translucent/material sidebar and material-grouped cards on the detail pages, with graceful fallback below macOS 26 exactly as the overlays do. No new styling system; factor the shared treatment so the Hub and overlays read as one app.

### D7. Menu trim + inline Setup confirmations; one entry point
`StatusItemController` collapses to: **Open Hub…**, a quick **Switcher enable/disable** toggle, **Add Front App to Band ▸ <band>**, **Quit**. `AppCoordinator.showSettings`/`showFavoritesEditor`/`showOnboarding` collapse into `showHub(selecting:)`. The native-gesture/spaces opt-in **triggers and live status** move onto the **Setup** page (the Onboarding window is deleted).

**Decision (revised during review):** the ~6 system-setting confirmations themselves (free three-finger swipe, spaces rearrange, vertical gesture, launcher setup, restore actions, restore-on-quit) **remain momentary, user-initiated `NSAlert.runModal` confirmations**, invoked from the Setup-page buttons — they are *not* converted to inline in-page flows. Rationale: each confirms an irreversible *system* change (a trackpad/Mission-Control setting that requires a re-login), so a momentary modal acknowledgement is appropriate and matches how the OS gates such changes; and this does not violate the CLAUDE.md invariant, which bans app-modal alerts only for *background AI failures* (these are foreground, user-initiated, not AI failures, and there is no longer a Settings window for a modal to freeze). The Setup page reflects the resulting state live (re-reading after each action) so the page stays the single home for setup.

## Risks / Trade-offs

- **Data migration corrupts or loses AI commands** → Keep migration pure and Core-testable; preserve IDs; gate on `schemaVersion` for idempotency; cover with unit tests (had-commands, never-opted-in, already-migrated, empty record). Never delete the old key until the new record is written successfully.
- **`Favorites` record grows / decode breaks on the new persisted `.aiCommand`** → `AICommand` is already `Codable`; add round-trip encode/decode tests for a band containing `.aiCommand` items and a forward-compat decode of an old record (migration path).
- **AI canvas "unavailable" state competes with the existing `.failed` taxonomy** → It is *not* a failure: model it as a distinct, non-error `unavailable` presentation that still routes its headline through `AIPresentedError`, so cancellation/dismissal stays a no-op and nothing gets stuck mid-flight.
- **Deleting four views in one change risks a big-bang regression** → Phase the tasks (shell+Overview → feature pages → Setup → Bands → AI fold-in+migration → delete+menu-trim); compile-verify (`swift build`/`xcodebuild`) and run `swift test` at each phase so the tree stays green.
- **Losing window-specific affordances (frame autosave, file pickers, character palette)** → The Hub keeps frame autosave; `NSOpenPanel` pickers and the emoji/SF-symbol pickers move with the Bands canvas unchanged.
- **Core must stay MLX-free** → Migration, the band model, and gating live in Core (operate on `AICommand`/`Favorites` only). The fire-time "is the model ready" check uses the existing `LLMRuntime`/`ModelManager` seam already visible to app code; Core sees only the taxonomy.

## Migration Plan

1. Land the Hub shell + Overview alongside the existing windows (no deletion yet); route `showHub` from a new menu item.
2. Re-home feature pages; verify each binds the identical `AppSettings` property.
3. Fold Setup in; delete `OnboardingView` and its window.
4. Fold the Bands canvas in; delete `FavoritesEditorView` and its window.
5. Flip `.aiCommand` to persisted; add seed reconciliation + migration; absorb the AI inspector into Bands; add the fire-time canvas gating; delete `AICommandStore`, `AICommandBandBuilder`, `AICommandEditorView`, and the Settings sheet.
6. Delete `SettingsView` and the three retained windows; trim the menu; final `swift test` + `xcodebuild` compile-verify.

**Rollback:** the migration only *adds* an AI band and retires a key after a successful write; if reverted before archive, the old `aiCommands` key can be re-read. Each phase is independently compilable.

## Open Questions

- Should the **Overview** also surface read-only health (e.g., permissions-missing badge, model-not-downloaded badge) as deep links to Setup/AI? Proposed: yes, lightweight badges only — defer richer status to the feature pages.
- Should `Add Front App to Band` remain a menu submenu, or become a Bands-page affordance only? Proposed: keep the menu submenu (fast capture) and have it deep-link the Hub to the target band when more editing is wanted.
