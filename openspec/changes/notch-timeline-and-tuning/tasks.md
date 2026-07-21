# Tasks — notch-timeline-and-tuning

## 1. Segment model (Core, display-only)

- [x] 1.1 Add `TurnSegment` (`kind: .thinking | .answer`, `text`; Codable/Equatable/Sendable) and `AgentMessage.segments: [TurnSegment]?` in `AI/Agent/AgentConversation.swift`; keep `text`-only assembly untouched and extend the file-header invariant note
- [x] 1.2 Add born-with tuning optionals `reasoningOverride: Bool?` / `contextTokens: Int?` to `AgentConversation` (decode-safe, like `skillID`/`autoApprove`)
- [x] 1.3 `AgentConversationTests`: Codable round-trip with/without segments + tuning fields; legacy JSON (no new keys) decodes; assembly still excludes thinking/segments

## 2. Engine streaming (NotchSessionEngine)

- [x] 2.1 Add `@Published liveSegments: [TurnSegment]` with the append-or-coalesce rule; feed it from the plain `runTurn` token loop (both channels), keeping `thinking` and `.conversing(partial:)` accumulating as today
- [x] 2.2 Generalize `runRoutedTurn`'s ordered thinking stream to `(TokenChannel, String)` events; wire `AgentLoop.onResponseToken` so the routed answer streams into `liveSegments` and `.conversing(partial:)`
- [x] 2.3 Persist the timeline: `appendAssistantTurn` stamps `segments` (plus existing `text`/`thinking`) and clears `liveSegments`; clear on turn failure/cancel paths too
- [x] 2.4 Tuning snapshot: inject `tuningDefault: () -> (reasoning: Bool, contextTokens: Int)`; `startNew()` stamps both onto the newborn conversation; `bind()` prefers stored values with the legacy fallback (reasoningDefault + injected budget); compactor uses the per-session budget
- [x] 2.5 `ConversationSessionTests`: interleave order (T,R,T,R script → segments in arrival order) on both paths; routed answer streams before settle; persisted segments on the settled message; born-with tuning stamped, retained across rebind, legacy conversation falls back

## 3. Notch tuning setting

- [x] 3.1 Add `NotchTuning` (quick/balanced/deep/max; `reasoning`, `contextTokens(modelMax:)`, titles) in Core; persist `AppSettings.notchTuning` (default `.balanced`, Keys/load/reset)
- [x] 3.2 Wire `makeNotchSessionEngine` (`AppCoordinator`) to pass a settings-backed `tuningDefault` (clamped to the model max via the `AgentContextBudgetProvider` idiom)
- [x] 3.3 `AppSettingsTests` round-trip + default; `NotchTuning` mapping unit test

## 4. Notch UI — timeline transcript

- [x] 4.1 Rebuild `NotchConversationView.thread`: per-message segment rendering (answer = `BidiText` bubble, thinking = muted per-block collapsible), legacy fallback (flat `thinking` → one leading block), live turn rendered from `engine.liveSegments`; drop the bottom `thinkingSection` and the `.conversing` partial bubble; auto-scroll pins on `liveSegments`
- [x] 4.2 Live thinking block streams expanded, collapses to a compact expandable row at settle; no new repeating animation (idle-CPU-spin rule)

## 5. Notch UI — settings zone

- [x] 5.1 Add `Mode.settings` to `NotchHomeZoneViewModel`; gear icon button stacked above `NotchNewChatCard`; `onOpenSettings` callback threaded like `onNewSession`
- [x] 5.2 `NotchHomeZoneLayout` settings solve + controller transition (same border-stretch resize as `expandSession`; back affordance returns to rail; panel never takes key in settings mode; grace-dismiss active as in rail mode; synchronous teardown paths untouched)
- [x] 5.3 Settings-zone view: the thinking+context slider (4 discrete stops over `NotchTuning`), stop title + "thinking on/off · N tokens" caption, bound to `AppSettings.notchTuning`

## 6. Verify & ship

- [x] 6.1 `swift build` + `swift test` green (MLX-free Core); `xcodebuild` compile-verify only if app-target files changed
- [x] 6.2 Update the `ai-parked-sessions` notes in `CLAUDE.md`-adjacent docs only if behavior notes exist there (none expected); keep the delta spec in this change dir
