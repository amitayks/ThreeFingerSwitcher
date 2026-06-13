## Why

The iPhone companion and the Mac app are two separately-distributed binaries (the Mac app is unsandboxed Developer-ID; the iOS app ships through the App Store) that must agree, byte-for-byte, on how a moved item crosses the wire. If each end hand-rolls its own serialization, an update to one silently breaks the other, and the wire format gets entangled with each side's storage and UI. We need **one versioned, transport-agnostic contract** owned in a single place — a pure Swift package both ends depend on, with no AppKit/UIKit/Network coupling, so it verifies under `swift test` and stays stable while transports and UIs evolve around it. This is the foundation every other device-link change builds on, so it lands first.

## What Changes

- **A new pure SwiftPM library target, `DeviceLinkProtocol`**, with **zero dependencies** (no AppKit, UIKit, Network, or MLX) — the shared wire contract, consumed by `ThreeFingerSwitcherCore` (Mac) and by the iOS app (by package reference). It builds and unit-tests under plain `swift build` / `swift test`, like `ThreeFingerSwitcherCore`.
- **A versioned message set (the frames).** A `protocolVersion` constant plus an explicit, `Codable` frame enum: **control** frames (`hello` with device identity + version, `ack`, `error`), an **item header** (`itemBegin`: a stable message id, the item kind, and a per-representation byte **manifest** — `[uti: byteLength]` — plus optional `suggestedName`/`capturedAt`/`origin`), streamed **payload** frames (`chunk`: message id + representation uti + sequence + a bounded byte slice), and **terminators** (`itemEnd`, `cancel`). The header-then-chunks shape means a large file **streams** and is never buffered whole, and a tiny text item can be framed ahead of an in-flight large transfer.
- **A length-prefixed binary codec.** A self-describing frame envelope: a fixed magic + version byte, a frame-type tag, and a `UInt32` big-endian length prefix, so a stream reader can split frames deterministically without a transport. Pure encode/decode functions over `Data`, fully unit-tested (round-trip, truncation, bad-magic, oversize-length rejection, partial-buffer reassembly).
- **The item value model (transport DTO).** A `LinkItem` value type mirroring the *shape* the Mac clipboard band needs — a `LinkItemKind` (`text`, `richText`, `image`, `color`, `url`, `file`) and `representations: [String: …]` keyed by UTI string — but defined **independently of `ClipboardEntry`** (the Mac storage model). The protocol owns the DTO; the *mapping* `LinkItem ⇄ ClipboardEntry` lives on the Mac side (a later change), so the wire never couples to storage internals. UTI constants are shared so both ends name representations identically.
- **A reassembly state machine.** A pure `InboundAssembler` that consumes decoded frames and emits completed `LinkItem`s (or a typed error), tracking per-message manifests, accumulating chunks per representation, validating totals against the manifest, and surfacing `cancel`/oversize/duplicate-id violations — testable with no I/O.
- **A typed error taxonomy** (`LinkProtocolError`) for malformed/violating streams, conforming to `Error`/`LocalizedError`, mapped at the boundary by transports later (mirrors the app's existing one-taxonomy convention).

## Capabilities

### New Capabilities
- `device-link-protocol`: the versioned wire contract for the iPhone↔Mac link — the frame set (control / item-header / chunk / terminator), the length-prefixed binary codec, the streamed chunked-file model, the transport-agnostic `LinkItem` DTO + shared UTI constants, the inbound reassembly state machine, and the protocol error taxonomy. Pure, dependency-free, unit-tested. **No transport, no pairing, no UI** — those are separate changes that depend on this.

### Modified Capabilities
<!-- None. This is purely additive: a new package target. No existing spec's requirements change. -->

## Impact

- **New:** a `Sources/DeviceLinkProtocol/` target (`Frame.swift`, `LinkItem.swift`, `LinkCodec.swift`, `InboundAssembler.swift`, `LinkProtocolError.swift`, `LinkUTI.swift`, `ProtocolVersion.swift`) and a `Tests/DeviceLinkProtocolTests/` target.
- **Modified:** `Package.swift` — add the `DeviceLinkProtocol` library product + target and its test target; nothing else depends on it *yet* (the Mac inbound/transport changes and the iOS app will add dependencies in their own changes).
- **Permissions / distribution:** none. No entitlement, no Info.plist key, no sandbox change, no native-gesture relocation. Pure logic.
- **Build:** stays in the MLX-free / Network-free fast loop — `swift build` / `swift test` cover it completely; no `xcodebuild` needed.
- **Privacy/speed/UX:** privacy — the contract carries only what the user chose to move and an opaque message id, no telemetry; speed — the header+chunk framing is what enables streamed, non-buffered large-file transfer and interleaving small items; UX — none directly (this is the substrate).
