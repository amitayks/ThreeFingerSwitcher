## 1. Package wiring

- [x] 1.1 Add a `DeviceLinkProtocol` library product + target to `Package.swift` (path `Sources/DeviceLinkProtocol`, no dependencies, Swift 6 mode) and a `DeviceLinkProtocolTests` test target (path `Tests/DeviceLinkProtocolTests`).
- [x] 1.2 Confirm the target builds empty under `swift build` (no AppKit/UIKit/Network import anywhere in the target).

## 2. Versioning & identity

- [x] 2.1 `ProtocolVersion.swift`: `protocolVersion` (major/minor) constant + a `DeviceIdentity` value type (stable id + name) + a compatibility check (`isCompatible(with:)`, major must match).
- [x] 2.2 Unit-test: compatible accepts, major-mismatch refuses, newer-minor accepts.

## 3. Item DTO & UTI constants

- [x] 3.1 `LinkUTI.swift`: shared UTI string constants (plain text, rtf, png, tiff, file-url, url, color) mirroring `ClipboardUTI` so both ends label representations identically.
- [x] 3.2 `LinkItem.swift`: `LinkItemKind` enum (`text`/`richText`/`image`/`color`/`url`/`file`); `LinkItem` value type (`messageID: UUID`, `kind`, `representations: [String: Data]`, optional `suggestedName`/`capturedAt`/`origin: DeviceIdentity?`); `Equatable`, `Sendable`. No storage-type coupling.
- [x] 3.3 Unit-test: `LinkItem` equality + that the module imports nothing platform-specific.

## 4. Frames

- [x] 4.1 `Frame.swift`: the closed frame enum — `hello(DeviceIdentity, ProtocolVersion)`, `ack(UUID)`, `error(LinkProtocolError.Code)`, `itemBegin(ItemHeader)`, `chunk(ChunkFrame)`, `itemEnd(UUID)`, `cancel(UUID)`; `ItemHeader` (messageID, kind, `manifest: [String: UInt32]`, optional metadata); `ChunkFrame` (messageID, uti, `seq: UInt32`, `bytes: Data`).
- [x] 4.2 Each item-bearing frame exposes its `messageID`; add a `frameType` tag enum used by the codec.

## 5. Length-prefixed codec

- [x] 5.1 `LinkCodec.swift`: `encode(_ Frame) -> Data` writing `magic | version | frameType | UInt32-BE length | payload`; control/header bodies via a deterministic `Codable` encoder, `chunk` body as a fixed sub-header + raw bytes.
- [x] 5.2 A streaming `FrameDecoder` that buffers incoming `Data`, splits complete frames, reassembles a frame across reads, enforces a configurable max-frame length, and decodes each to a `Frame` or throws a typed error.
- [x] 5.3 Configurable constants: default chunk byte bound (256 KiB) and max-frame cap (8 MiB).
- [x] 5.4 Unit-tests: round-trip every frame; split-buffer reassembly; trailing-bytes preserved; oversize-length rejected; truncated frame rejected; bad-magic rejected; unknown frame tag → typed error.

## 6. Inbound reassembly

- [x] 6.1 `InboundAssembler.swift`: consume `Frame`s, track per-`messageID` manifest + per-representation accumulating bytes by `seq`, emit a completed `LinkItem` on `itemEnd` after validating each representation's total equals the manifest.
- [x] 6.2 Reject: chunk for unknown message, duplicate/out-of-range seq, total exceeding manifest, second `itemBegin` for a live id; `cancel` discards partial state. No I/O; bounded to in-flight items.
- [x] 6.3 Unit-tests: complete single item; interleaved small-ahead-of-large by `messageID`; byte-count mismatch rejected; cancel discards; unknown-message chunk rejected.

## 7. Error taxonomy

- [x] 7.1 `LinkProtocolError.swift`: `Error`/`LocalizedError` with a `Code` per failure class (bad magic, unsupported version, unknown tag, oversize, truncated, manifest mismatch, unknown message, bad seq, cancelled) + clean per-case messages, no raw interpolation.
- [x] 7.2 Unit-test: every decode/reassembly failure surfaces a `LinkProtocolError` case (never a Foundation error) and yields a clean `localizedDescription`.

## 8. Verify

- [x] 8.1 `swift build` clean; `swift test` green for `DeviceLinkProtocolTests`; existing `ThreeFingerSwitcherTests` still green (no regressions from the `Package.swift` edit).
- [x] 8.2 Grep the target for `import AppKit|UIKit|Network` → none.
