## 1. Runtime parameter model + `{lang}` token (Core)

- [x] 1.1 Add `RuntimeParameter` (`AI/RuntimeParameter.swift`): `enum RuntimeParameter: Codable, Equatable, Sendable { case language(default: String) }`, with a fixed `AILanguages` list for the dropdown.
- [x] 1.2 Add `var runtimeParameter: RuntimeParameter?` to `AICommand` (default `nil`); ensure Codable round-trips and the existing initializer keeps current behavior when absent.
- [x] 1.3 Extend `PromptTemplate`: add `lang` to `knownTokens` and an `activeLanguage` input to `resolve(...)`; `{lang}` resolves to the active language, and to the empty string when the command declares no language parameter.
- [x] 1.4 Add per-command runtime-parameter persistence in `AppSettings` (`aiCommandLanguages: [String: String]`, UserDefaults-backed, with `remembered/rememberLanguage` + best-effort `pruneCommandLanguages`); read = next-run default, write = on canvas repick; never mutates the stored `AICommand`.
- [x] 1.5 Update `AICommandExecutor` to resolve the active language (persisted → declared default) into `{lang}`, and a `setLanguage(_:)` **re-run** entry point that persists + re-fires (cancelling the in-flight generation).
- [x] 1.6 Unit tests: `{lang}` resolution (active / absent→empty), per-command persistence round-trip + prune, re-run re-translates in place and remembers for next run. **62 tests green via `swift test`.**

## 2. AI command catalog (Core)

- [x] 2.1 Add `AI/AICommandCatalog.swift`: a `Category` enum (`CaseIterable`, with `title` + SF Symbol + per-category tint) covering Writing, Tone, Understand, Translate, Developer, Reply, Capture, Vision, Format; and an `entries: [Entry(category, AICommand)]` table.
- [x] 2.2 Populate **Writing / Tone / Understand / Format** presets (reversible short replacements default `replaceSelection`; commentary/long-structural default `previewOnly`) per the refined design principles.
- [x] 2.3 Populate **Translate** presets using `{lang}` + `runtimeParameter: .language(default:)` (primary "Translate" preview; "Translate in Place" replace; default English).
- [x] 2.4 Populate **Developer** presets (Explain Code, Explain Error, Commit Message from clipboard diff → paste, Add Docstring [previewOnly], Regex from/explain, Rewrite in Language [`{lang}` default Python], Shell, Name This).
- [x] 2.5 Populate **Reply** presets (Draft a Reply, Polite Decline, Quick Acknowledge, Summarize Thread then Reply), all `previewOnly`.
- [x] 2.6 Populate **Capture** presets routed to tasks: Add to Calendar, Add to Reminders, New Contact, Save to Project, Open with Tool…, Send to Shortcut…
- [x] 2.7 Populate **Vision** presets (`input: .screenRegion`, `previewOnly`): What is this?, Extract Text (OCR), Explain Chart, Solve, Transcribe Handwriting, Extract Table → Markdown, Translate Image Text (functional once §7 vision lands).
- [x] 2.8 `copy(of:)` mints an independent fresh-`UUID` copy for the browser's add path; `seeded()` selects the curated 8-command subset.
- [x] 2.9 Unit tests (`AICommandCatalogTests`, 7 tests): every preset fireable, all 9 categories present, copy mints distinct ids without mutating the original, vision = screenRegion+preview, `{lang}` presets declare a language parameter, Understand = preview, seed resolves all 8 curated names. `swift test` green (**499 total**).

## 3. Catalog browser in the Bands editor (Hub)

- [x] 3.1 Replaced the single-button `AICommandSource` in `Hub/BandsCanvas.swift` with a catalog **browser** mirroring `ActionBrowser`: a `List` with a `Section` per `Category`, each preset a button → `onPick(AIBand.item(for: AICommandCatalog.copy(of: preset)))`.
- [x] 3.2 Per-category **"Add all as a band"** in each section header: creates a `ContextBand` named after the category (category tint), populated with that category's presets (each via `copy(of:)`), appended unconditionally via `store.mutate`.
- [x] 3.3 Trailing **"Custom command"** entry preserving today's blank-then-edit flow (`input .selection`, template `{input}`, `previewOnly`), auto-selecting the new item.
- [x] 3.4 Wired `store: FavoritesStore` into `AICommandSource` (mirroring `PresetComposer`); adding does not require the AI opt-in. Compile-verified via `swift build` (Core target builds the Hub).

## 4. Grown fresh-install seed

- [x] 4.1 `AIBand.seeded()` now returns `AICommandCatalog.seeded()` (one curated 8-command band); `bandID`, name, color, `item(for:)`, `band(from:)`, `isAIBand`, `seededBand()`, and the migration/idempotency guard left unchanged.
- [x] 4.2 Tests: existing seed/fold-in tests (`AICommandFoldInTests`) still pass against the catalog-drawn seed (they assert intent/shape, not an exact count); catalog `seeded()` resolution asserted in `AICommandCatalogTests`. `swift test` green.

## 5. In-canvas language picker + re-run (canvas)

- [x] 5.1 In `Overlay/AICommandCanvasView.swift`, a language **dropdown** appears only when the live command declares a runtime parameter (`executor.activeLanguage != nil`), seeded from the persisted/active value; options come from the command's own parameter (`runtimeParameter?.options` — human languages for Translate, programming languages for "Rewrite in Language").
- [x] 5.2 On selection change → `executor.setLanguage(_:)` persists per command + re-fires (cancel in-flight, re-resolve `{lang}`, re-stream into the same canvas) without reopening the launcher or losing the captured front app. Persistence wired in `AppCoordinator` (`loadLanguage`/`saveLanguage` → `AppSettings`).
- [x] 5.3 Commit/discard semantics unchanged after a re-run (the executor's output routing + cancellation are reused); a command with no runtime parameter shows no dropdown.
- [x] 5.4 Headless executor re-run tests pass (`AICommandExecutorTests`, 21). Canvas compiles under `swift build` (Core builds the Overlay); app-target `xcodebuild` compile-check + the picker's live behaviour are a user-side manual confirm.
- [x] 5.5 **Picker is clickable + restyled (refinement):** the overlay panel was gesture-only (`ignoresMouseEvents = true`) except for the `.unavailable` state, so the dropdown received no clicks — extended `LauncherOverlayController`'s interactivity gate to also enable `setCanvasInteractive(true)` when `command.runtimeParameter != nil` (safe: `.nonactivatingPanel` never activates the app, swipe-resolve runs off the multitouch device, write-back re-activates the captured app on commit). Repositioned the picker as a **centered top Liquid-Glass capsule** (`glassEffect(.regular, in: Capsule())` + `.ultraThinMaterial` fallback) reading "Auto-detect → [Language ▾]". Builds clean; live click/glass are a user-side confirm.

## 6. Bidirectional (RTL/LTR) canvas rendering

- [x] 6.1 Added `firstStrongDirection(_:)` (RTL blocks → `.rightToLeft`; any other strong letter → `.leftToRight`) for the short SwiftUI `Text` surfaces.
- [x] 6.2 Added `BidiText` (NSViewRepresentable over a read-only `NSTextView`, `baseWritingDirection = .natural`, natural alignment, transparent, non-selectable) for the streamed/ready output; the `.declined`/`.failed` bodies also route through it; short review-field values use the first-strong helper (single-paragraph by construction). The system Bidi algorithm resolves mixed runs per paragraph.
- [x] 6.3 `BidiText.updateNSView` re-sets the string + re-asserts unbounded container height + `invalidateIntrinsicContentSize()` on every stream update, so base direction recomputes as tokens arrive (no lock to the first token).
- [ ] 6.4 **User manual confirm (signed build):** a Hebrew result is right-aligned RTL; Hebrew + embedded Latin/URL resolves cleanly; English stays LTR — `BidiText`'s final visual sizing inside the ScrollView can only be confirmed in a real rendered build.

## 7. Vision in the Gemma runtime (separate group)

- [x] 7.1 Studied the dependency's hand-rolled multimodal path (`Gemma4CLI.swift`): `Gemma4ImageProcessor.processImage` (CGImage overload → pixel values), `<|image|>` + `boi/imageTokenId×280/eoi` token expansion, `Gemma4Registration.register(multimodal: true)`, `Gemma4MultimodalLLMModel.pendingPixelValues`, manual prefill + decode loop. Confirmed `Gemma4Pipeline.container` is private (can't reuse), so vision owns a separate container.
- [x] 7.2 In `GemmaRuntime/GemmaMLXRuntime.swift`, replaced the `unsupportedModality(.vision)` refusal with a **new image-aware generate path**: decode PNG `Data` → CGImage (ImageIO) → `Gemma4ImageProcessor` → pixel values, splice image tokens (CLI-faithful), set `pendingPixelValues`, run the manual generate loop. **Non-streaming** (buffers the full answer, yields it + a final token) — incremental streaming noted as a follow-up.
- [x] 7.3 Vision uses a **separate, lazily-loaded, resident multimodal `ModelContainer`** (loaded from the same downloaded files on first vision request via `register(multimodal:true)` + `loadModelContainer`); the text path keeps `Gemma4Pipeline.chatStream` unchanged. Two resident graphs accepted per the high-end-hardware-only target (design D7).
- [x] 7.4 `capabilities = [.text, .vision]`; capability-based selection routes `screenRegion → .vision` → this runtime; `SelectionService` PNG bytes flow into the new path. Cancellation honored; vendor/OS errors mapped to `RuntimeError` at the boundary.
- [x] 7.5 **Compile-verified:** `xcodebuild build -scheme ThreeFingerSwitcher` → **BUILD SUCCEEDED** (MLX/Metal, GemmaRuntime + app target). API faithfulness independently confirmed against the checkout (every symbol public/matching). **Remaining = your on-device run** (download a vision model, fire a screen-region command) — inherently your machine (no model/GPU here).

## 8. Add-to-reminders task

- [x] 8.1 Add `ParsedReminder` (`AI/Tasks/ParsedActions.swift`) with `applicable`+`reason`+`{title, due?, notes?, priority?}` and its `StructuredSchema` (decline affordance).
- [x] 8.2 Add `TaskKind.addToReminder` and route it in `TaskDispatcher`; add a `ReminderSink` protocol + `EventKitReminderSink` (EKReminder via `requestFullAccessToReminders`), with a test recording sink.
- [x] 8.3 Extend `TaskError` (`remindersPermissionDenied`) + `PermissionsService.requestRemindersAccess` so a denied Reminders permission yields a clean, recoverable message naming Reminders; consent-gated at first use only.
- [x] 8.4 Tests: well-formed reminder action + execute-routes-to-sink, decline path. Throw→`.failed` is covered by the executor's generic throwing-commit test. `swift test` green.

## 9. New-contact task

- [x] 9.1 Add `ParsedContact` with `applicable`+`reason`+`{name, email?, phone?, organization?, notes?}` and its `StructuredSchema`.
- [x] 9.2 Add `TaskKind.newContact` and route it in `TaskDispatcher`; add a `ContactSink` protocol + `ContactsSink` (`CNMutableContact` + `CNSaveRequest`), with a test recording sink. (Note: `CNContact.note` is intentionally not written — it needs the Apple-approval-gated `contacts.notes` entitlement.)
- [x] 9.3 `TaskError.contactsPermissionDenied` + `PermissionsService.requestContactsAccess` (clean, recoverable, names Contacts); consent-gated at first use only.
- [x] 9.4 Tests: contact action + execute-routes-to-sink, decline path. `swift test` green (45 task/executor tests). **Info.plist usage strings (`NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription`) deferred to §10.4 (app-target build, App Sandbox stays off — no new entitlement).**

## 11. Picker for open-tool / send-to-shortcut targets (no manual identifier typing)

- [x] 11.1 Added `ToolTargetPicker` in `Hub/BandsCanvas.swift` replacing the open-tool `TextField`: a `Menu` with an **Apps** section (`loadInstalledApps()` → stores `app.url.path`) and a **Shortcuts** section (`loadShortcutNames()` → stores the name), label resolved to a friendly name. Storage routes correctly through the opener (path ⇒ app, bare name ⇒ `shortcuts run`).
- [x] 11.2 Added `ShortcutPicker` replacing the `.shortcut` `TextField("Shortcut name")` in `aiDestinationEditor`; `.urlScheme` / `.shell` kept as text fields.
- [x] 11.3 Both pickers have a **"Custom…"** escape hatch and auto-show the field for a pre-existing custom/unlisted value (gated on a `loaded` flag so a listed value doesn't flash the field while the list loads); lists load lazily via `.task` and tolerate an empty result (shortcuts CLI unavailable).
- [x] 11.4 `swift build --target ThreeFingerSwitcherCore` clean; reviewer APPROVE (storage semantics verified against the opener); the one flicker nit fixed. UI behaviour is a user-side confirm.

## 12. On-device reasoning (model thinking) with a live, collapsible canvas section

- [x] 12.1 Core seam: `LLMRequest.reasoning` flag + `Token.channel` (`.thinking`/`.response`, default `.response`); `AppSettings.aiReasoningEnabled` (**default ON**, preserved from reset) + a Hub AI-section toggle; flag plumbed through the executor (text) and the task dispatcher (structured) so it applies to every command. `swift test` green.
- [x] 12.2 Executor splits channels: thinking accumulates into `@Published thinking`; the result/state and what commit routes are **response-only** (thinking never reaches the document or a task); resets on fire/cancel. Tested.
- [x] 12.3 Canvas: a **collapsible Thinking section**, collapsed by default with a live pulse + elapsed timer (so the user sees it's working), tap to expand/collapse, **scrollable**; the response pane stays scrollable. Canvas made always-interactive so taps/scroll land on it.
- [x] 12.4 Scroll routing: relaxed `shouldConsumeScroll` to `fingerCount >= 3 || ((launcherOpen || switcherOpen) && !canvasActive)` so 1–2-finger scroll reaches the open canvas while 3+ finger stays consumed (a resolve swipe can't leak) and the normal launcher is unaffected. Tested.
- [x] 12.5 GemmaRuntime: `enable_thinking` wired from the `reasoning` flag (Gemma 4 does NOT think by default — so no latency unless reasoning is on); a `ChannelClassifier` (replicating `Gemma4TokenFilter`) tags each token; reasoning/vision routes through the manual generate loop streaming `Token(channel:)`, non-reasoning text keeps the `chatStream` fast path; `generateText` overridden to response-only so structured/task JSON never sees thinking. **`xcodebuild` → BUILD SUCCEEDED (independently verified).**
- [x] 12.6 **Per-command reasoning override:** `AICommand.reasoning: AIReasoning?` (`.on`/`.off`; **nil = follow the global toggle** — optional so legacy commands decode to nil), `resolvedReasoning(globalDefault:)`; the executor resolves once per fire and threads the same value into the text request AND `dispatcher.prepare(…reasoning:)` (so tasks honor it too); a **Default / On / Off** picker in the Bands command inspector. Tested: `.off` beats a global ON and `.on` beats a global OFF on both paths; legacy decode → nil. **519 tests green.**
- [ ] 12.7 **Your on-device run:** with a downloaded model, fire a reasoning command — confirm the thinking streams into the collapsed section (expand to watch), only the response is inserted, reasoning-off commands stay fast, and a per-command On/Off override beats the global toggle.

## 10. Spec sync & verification

- [x] 10.1 `swift build` + `swift test` green for the MLX-free Core (**501 tests, 0 failures**); `xcodebuild build -scheme ThreeFingerSwitcher` → **BUILD SUCCEEDED** (compile-verifies `GemmaRuntime` + app target, MLX/Metal).
- [ ] 10.2 **Manual run by you (stable-signed install):** add a category-as-band, fire a translate command and repick language in the canvas (verify re-run + persistence), fire a vision command, run a reminders/contacts task (verify consent + review), confirm RTL Hebrew + mixed text render cleanly.
- [x] 10.3 Added Info.plist usage strings to `Resources/Info.plist`: `NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription` (App Sandbox stays off — no new entitlement); `plutil -lint` OK. `build-app.sh` copies `Resources/Info.plist` into the bundle, so they ship in your build.
- [ ] 10.4 Run `/opsx:verify` for the change, then `openspec validate` (✓ valid) and sync the delta specs into `openspec/specs/` on archive.
