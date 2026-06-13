## ADDED Requirements

### Requirement: Versioned protocol identity
The protocol SHALL expose a single integer `protocolVersion` constant, and every session SHALL open with a `hello` control frame carrying the sender's `protocolVersion` and a device identity (a stable device id + a human-readable name). A receiver SHALL compare versions and, on an incompatible major version, SHALL refuse the session with a typed error rather than attempting to parse later frames. The wire format SHALL be self-describing enough that a receiver can reject a stream that is not this protocol before allocating for it.

#### Scenario: Compatible hello is accepted
- **WHEN** a `hello` frame is received whose `protocolVersion` matches the receiver's
- **THEN** the session is accepted and subsequent frames are processed

#### Scenario: Incompatible version is refused
- **WHEN** a `hello` frame is received with an incompatible `protocolVersion`
- **THEN** the receiver surfaces a typed version-mismatch error and does not process further item frames

#### Scenario: Non-protocol bytes are rejected early
- **WHEN** a frame is decoded whose magic prefix is not the protocol's
- **THEN** decoding fails with a typed error before any payload is allocated

### Requirement: Explicit framed message set
The protocol SHALL define a closed, `Codable` set of frames: **control** (`hello`, `ack` carrying the acknowledged message id, `error` carrying a typed code), an **item header** (`itemBegin`), streamed **payload** (`chunk`), and **terminators** (`itemEnd`, `cancel`). Every item-bearing frame SHALL carry the `messageID` it belongs to so frames for different items can be interleaved on one stream. There SHALL be no implicit or untyped frame; an unknown frame tag SHALL decode to a typed error.

#### Scenario: Each frame carries its message id
- **WHEN** an `itemBegin`, `chunk`, `itemEnd`, or `cancel` frame is constructed
- **THEN** it carries the `messageID` of the item it belongs to

#### Scenario: Unknown frame tag is a typed error
- **WHEN** a frame with an unrecognized type tag is decoded
- **THEN** decoding yields a typed `LinkProtocolError`, not a crash or silent drop

### Requirement: Length-prefixed binary codec
The protocol SHALL provide pure `Data`-in/`Data`-out encode and decode functions that frame each message as: a fixed **magic** marker, a **version** byte, a **frame-type** tag, and a big-endian `UInt32` **length** prefix followed by exactly that many payload bytes. The decoder SHALL split a byte stream into frames deterministically, reassemble a frame that arrives across multiple buffer reads, reject a declared length above a configured maximum, and reject a truncated or malformed frame with a typed error. Encode→decode SHALL round-trip every frame type without loss.

#### Scenario: Round-trip preserves every frame
- **WHEN** any frame is encoded and the bytes are decoded
- **THEN** the decoded frame equals the original

#### Scenario: Partial buffer reassembles
- **WHEN** a frame's bytes arrive split across two or more reads
- **THEN** the decoder buffers and emits the frame once its full length is available, leaving any trailing bytes for the next frame

#### Scenario: Oversize length is rejected
- **WHEN** a frame declares a length above the configured maximum
- **THEN** the decoder fails with a typed error and consumes no unbounded memory

#### Scenario: Truncated frame is rejected
- **WHEN** a frame is decoded whose payload is shorter than its declared length and the stream has ended
- **THEN** the decoder reports a typed truncation error

### Requirement: Streamed chunked item model
An item SHALL be transmitted as one `itemBegin` header, then one or more `chunk` frames, then one `itemEnd`. The `itemBegin` header SHALL declare the item kind and a **manifest** mapping each representation's UTI to its total byte length, so the receiver knows the complete size before bytes arrive and never needs the whole item buffered to begin handling it. Each `chunk` SHALL carry a representation UTI, a monotonically increasing sequence number, and a bounded slice of that representation's bytes. The sender SHALL be able to emit a small item's frames ahead of, or interleaved with, an in-flight large item's chunks (the framing SHALL not require an item to complete before another begins).

#### Scenario: Header declares the full manifest before bytes
- **WHEN** an `itemBegin` is produced for an item with representations R
- **THEN** its manifest contains every UTI in R mapped to that representation's exact total byte length

#### Scenario: Chunks are bounded and ordered
- **WHEN** a representation larger than the chunk bound is sent
- **THEN** it is split into multiple `chunk` frames with consecutive sequence numbers, each no larger than the bound

#### Scenario: Interleaving a small item ahead of a large one
- **WHEN** a large item's chunks are mid-flight and a small item is enqueued
- **THEN** the small item's `itemBegin`/`chunk`/`itemEnd` frames may be emitted interleaved, distinguished by `messageID`, without waiting for the large item to finish

### Requirement: Transport-agnostic item DTO
The protocol SHALL define a `LinkItem` value type — a `LinkItemKind` (`text`, `richText`, `image`, `color`, `url`, `file`), a `representations: [String: Data]` map keyed by UTI string, and metadata (`messageID`, optional `suggestedName`, `capturedAt`, and an `origin` device descriptor) — that is `Equatable`, `Sendable`, and carries **no AppKit/UIKit/Network dependency**. The protocol SHALL also expose shared UTI string constants so both ends name representations identically. The DTO SHALL be defined independently of any storage type (e.g. the Mac's `ClipboardEntry`); mapping the DTO to/from storage is explicitly out of this capability.

#### Scenario: LinkItem is platform-free
- **WHEN** the `DeviceLinkProtocol` module is built
- **THEN** it imports no AppKit, UIKit, or Network framework, and builds under plain `swift build`

#### Scenario: Shared UTI constants
- **WHEN** either end labels a representation (e.g. plain text, png, file-url)
- **THEN** it uses the protocol's shared UTI constant, so the manifest keys match across devices

### Requirement: Inbound reassembly state machine
The protocol SHALL provide a pure `InboundAssembler` that consumes decoded frames and emits a completed `LinkItem` (or a typed error) per message. It SHALL track each in-flight `messageID`'s manifest, accumulate `chunk` bytes per representation in sequence, and on `itemEnd` validate that every representation's accumulated byte count equals its manifest total before emitting the item. It SHALL reject a `chunk` for an unknown message, a duplicate or out-of-range sequence, a total exceeding the manifest, and a second `itemBegin` for a live `messageID`; a `cancel` frame SHALL discard that message's partial state. The assembler SHALL perform no I/O and hold only the bytes of items currently in flight.

#### Scenario: Complete item is emitted on itemEnd
- **WHEN** an item's `itemBegin`, all `chunk`s, and `itemEnd` are fed in order
- **THEN** the assembler emits one `LinkItem` whose representations match the manifest exactly

#### Scenario: Byte-count mismatch is rejected
- **WHEN** `itemEnd` arrives but a representation's accumulated bytes do not equal its manifest total
- **THEN** the assembler emits a typed error and discards that message's state, emitting no item

#### Scenario: Cancel discards partial state
- **WHEN** a `cancel` frame arrives for an in-flight `messageID`
- **THEN** the assembler drops that message's accumulated bytes and emits neither an item nor an error for it

#### Scenario: Chunk for an unknown message is rejected
- **WHEN** a `chunk` arrives whose `messageID` has no live `itemBegin`
- **THEN** the assembler emits a typed error and ignores the chunk

### Requirement: Protocol error taxonomy
The protocol SHALL define a single `LinkProtocolError` type conforming to `Error`/`LocalizedError`, with a distinct case per failure class (bad magic, unsupported version, unknown frame tag, oversize length, truncated frame, manifest mismatch, unknown message, duplicate/out-of-range sequence, cancelled), each with a clean human-readable message. Transports and feature code SHALL be able to map these at their boundary; the protocol itself SHALL never surface a raw decoding/Foundation error to callers.

#### Scenario: Every failure maps to a typed case
- **WHEN** any decode or reassembly failure occurs
- **THEN** callers receive a `LinkProtocolError` case, never an untyped or Foundation error

#### Scenario: Errors carry a clean message
- **WHEN** a `LinkProtocolError` is presented via `localizedDescription`
- **THEN** it yields a concise human-readable string with no raw interpolation of internal state
