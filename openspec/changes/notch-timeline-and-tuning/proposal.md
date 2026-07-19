# Proposal — Notch chat: timeline-ordered thinking/answer streaming + in-notch tuning zone

## Why

The notch conversation renders its two token channels as two disconnected flat strings: one "Thinking" collapsible pinned after the whole message list, the streaming answer in a separate state bubble — and in the **routed** turn path (the production path with tools) the answer does not stream at all; it lands whole at settle. Past turns lose their thinking entirely (per-message `thinking` is never rendered). The result reads nothing like the model actually worked: you can't see thinking and answer unfold **in the order they happened**. Separately, the two knobs that shape a conversation — reasoning on/off and context size — are buried in the Hub, are global, and the notch engine ignores the context setting entirely (hardcoded 8192-token default), so there is no way to tune the notch chat from the notch.

## What Changes

- **Timeline transcript (Claude-Code-style).** An assistant turn becomes an ordered sequence of display-only **segments** (thinking / answer), appended live in token-arrival order and persisted with the message, so both the live turn and every historical turn render as an interleaved timeline: thinking block(s) where thinking happened, answer text where the answer happened. Thinking segments stay visually distinct (muted, collapsible per block) and are still **never re-fed** to the model — assembly continues to read `text` only.
- **The routed turn streams its answer live.** `NotchSessionEngine.runRoutedTurn` wires the already-existing `AgentLoop.onResponseToken` sink (today omitted) so the final answer streams token-by-token exactly like the plain-chat path, instead of appearing whole at settle.
- **In-notch settings zone.** The rail grows a small **settings (gear) affordance above the "+ New chat" card**. Clicking it morphs the same notch panel (border-stretch, no second panel) into a **settings mode** hosting one slider — **Thinking + context** — over ordered stops (Quick: thinking off · 8k → Balanced: thinking on · 8k → Deep: thinking on · 32k → Max: thinking on · model max). The value persists in settings and applies to **each following new conversation** until changed again.
- **Tuning is born-with, per conversation.** A new conversation snapshots the slider's (reasoning, context-tokens) at birth and carries them for life (decode-safe optional fields on the stored conversation); changing the slider later never retunes an existing session. The notch engine finally honors a real context budget (per-conversation tokens clamped to the model max) instead of the hardcoded default.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ai-parked-sessions`: the expanded-conversation requirement changes from "reasoning behind a collapsible section" to a **timeline of interleaved thinking/answer segments, streamed live in arrival order (including the routed path's answer) and persisted per turn**; a new requirement adds the **in-notch settings zone** (gear above "+ New chat", panel morphs to settings mode, one thinking+context slider, persisted, applied to new conversations only, born-with per conversation).

## Impact

- **Code (all MLX-free Core, `swift build`/`swift test`):**
  - `AI/Agent/AgentConversation.swift` — display-only ordered segments on `AgentMessage` (decode-safe optional; `text`-only assembly invariant preserved); optional born-with tuning fields on `AgentConversation`.
  - `AI/Parked/NotchSessionEngine.swift` — live segment accumulation for both turn paths; wire `onResponseToken`; snapshot tuning at `startNew()`, restore it at `bind()`; per-conversation context budget feeding the compactor.
  - `App/AppCoordinator.swift` (`makeNotchSessionEngine`) — inject settings-backed tuning defaults (today the context budget is not wired at all).
  - `Overlay/NotchHomeZoneOverlay.swift` / `Overlay/NotchHomeZoneController.swift` — transcript rebuilt around segments; `Mode.settings` + gear affordance + settings-zone view + layout solve.
  - `Settings/AppSettings.swift` — one persisted notch tuning level (default Balanced).
- **Specs:** `ai-parked-sessions` delta (one MODIFIED, one ADDED requirement).
- **No new permission, no gesture relocation, no schema bump** (all persisted growth is decode-safe optionals). Existing stored conversations/messages decode unchanged (old messages render their legacy flat `thinking` as a single leading thinking segment). Runtime seam (`LLMRuntime`, channels) is untouched — this consumes the existing `.thinking`/`.response` split.
