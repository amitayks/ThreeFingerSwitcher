## Why

The link is bidirectional: the Mac should also push an item to the iPhone (e.g. "send this clipboard entry to my phone"). That needs the inverse of the inbound adapter — turn a `ClipboardEntry` into a wire `LinkItem` — plus a way to hand it to the connected peer(s). The mapping is pure and testable, and it should **round-trip** against the inbound adapter (`ClipboardEntry → LinkItem → ClipboardEntry` preserves the content), which is the strongest correctness guarantee. The actual user trigger (a menu / Hub action choosing a target device) is the Hub change; this change builds the adapter and the service send path.

## What Changes

- **A `LinkOutboundAdapter`** (Core) mapping a materialized `ClipboardEntry` → `LinkItem`: kind 1:1 (`ClipboardKind` ↔ `LinkItemKind`); for text/richText/image/color/url it carries the entry's inline representation bytes under their UTIs; for **`file`** it resolves the entry's `file://` reference, **reads the file's bytes**, and sends them under a content UTI with `suggestedName` = the filename (the inverse of inbound, which writes received bytes to the inbox and references them). The item is stamped with the **local device identity** as origin so the peer marks it "from \<this Mac\>".
- **Round-trip fidelity.** `ClipboardEntry → LinkOutboundAdapter → LinkItem → LinkInboundAdapter → ClipboardEntry` preserves the content (text bytes, url, file bytes), proven by tests.
- **A service send path.** `DeviceLinkService.send(_ item:)` forwards an item to its live `LinkConnection`s (on the service queue). Compile-verified; the per-device targeting + the user trigger are the Hub change.

## Capabilities

### New Capabilities
- `device-link-outbound`: the send-side adapter (`ClipboardEntry → LinkItem`, including reading file bytes for `.file` and stamping local origin), its round-trip fidelity with the inbound adapter, and the service-level send/broadcast to connected peers. The user-facing trigger/target selection is out of scope (Hub).

## Impact

- **New:** `Sources/ThreeFingerSwitcher/Clipboard/LinkOutboundAdapter.swift`; `Tests/ThreeFingerSwitcherTests/LinkOutboundAdapterTests.swift`.
- **Modified:** `DeviceLink/DeviceLinkService.swift` (add `send(_:)` broadcasting to connections).
- **Permissions / distribution:** none. Reads files the user chose to send (app is unsandboxed). No new entitlement.
- **Build:** the adapter is `swift test`-verified; the service `send` compiles under `swift build`.
- **Privacy/speed/UX:** privacy — only sends what the user explicitly chooses (trigger is in the Hub); speed — file bytes streamed via the pump's chunking; UX — surfaced by the Hub later.
