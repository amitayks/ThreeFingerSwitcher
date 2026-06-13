## Context

The device link is two separately-distributed binaries that must agree on a wire format: the Mac app (`ThreeFingerSwitcherCore`, unsandboxed, links private mac frameworks) and the iOS app (App Store, sandboxed, cannot link the Mac module). Because neither can import the other, the **only** shared seam is a standalone package both reference. This change builds that package and nothing else — no sockets, no pairing, no UI. It is the contract; every later device-link change (transport, pairing, inbound, outbound, the iOS app) depends on it.

The Mac side already has a rich clipboard model (`ClipboardEntry` with `representations: [UTI: payload]`, `ClipboardKind`, `ClipboardUTI`) and an on-disk store with retention. The wire DTO deliberately mirrors that *shape* without reusing the *type*, so the wire stays stable across storage refactors and the iOS app gets a clean model with no Mac coupling.

## Goals / Non-Goals

**Goals:**
- One versioned, transport-agnostic, dependency-free contract, verified entirely under `swift test`.
- A framing that lets a large file **stream** (header + bounded chunks, never the whole blob in one frame) and lets a small text item be **interleaved** ahead of an in-flight file.
- Deterministic, fuzz-resistant decoding: reject non-protocol bytes, oversize lengths, and truncation before allocating.
- A `LinkItem` DTO + shared UTI constants both ends use identically, decoupled from `ClipboardEntry`.
- A pure reassembly state machine with no I/O.

**Non-Goals:**
- Networking, Bonjour, TLS, pairing — separate changes (`device-link-transport`, `device-link-pairing`).
- Mapping `LinkItem ⇄ ClipboardEntry`, the file inbox, the `origin` storage field — `device-link-inbound` (Mac).
- Compression, delta-sync, multi-device fan-out, resumable-across-reconnect transfer — future, explicitly deferred.
- Any UI, any iOS app code.

## Decisions

**D1 — A standalone, zero-dependency SwiftPM package, not a folder in Core.**
The iOS app cannot link `ThreeFingerSwitcherCore` (private mac frameworks, unsandboxed posture). A standalone `DeviceLinkProtocol` target with no dependencies is the only thing both binaries can share. *Alternative considered:* duplicate the model in each app — rejected: guarantees drift, defeats the entire point of a contract.

**D2 — Hybrid framing: fixed binary envelope + `Codable` control/header bodies + raw-bytes chunk bodies.**
The frame envelope is fixed binary — `magic(4) | version(1) | frameType(1) | length(UInt32 BE) | payload(length)`. Control and header frame bodies (`hello`, `ack`, `error`, `itemBegin`) are small and structural, so they are `Codable`-encoded (compact, forward-evolvable). `chunk` bodies are **raw bytes** with a tiny fixed sub-header (`messageID | utiIndex | seq | byteLen`), never JSON. *Alternative considered:* JSON/base64 for everything — rejected: base64 inflates payloads ~1.33× and forces whole-representation buffering, killing the streaming goal. *Alternative:* protobuf/FlatBuffers — rejected: an external dependency in a package whose whole virtue is zero dependencies, for a format we fully control.

**D3 — The DTO is decoupled from `ClipboardEntry`; mapping lives on the Mac side.**
`LinkItem` mirrors the clipboard shape (`kind` + `[UTI: Data]`) but is its own type. The Mac's `LinkItem → ClipboardEntry` adapter is a later change in Core; the wire never sees storage internals (blob externalization, fingerprints, pins). *Alternative considered:* serialize `ClipboardEntry` directly over the wire — rejected: couples an iOS release to a Mac storage refactor and leaks storage concerns to the phone.

**D4 — `InboundAssembler` materializes in-flight items into `Data`; the large-file disk-streaming path is a documented transport seam, not in the protocol.**
The pure assembler accumulates chunk bytes into `Data` per representation and emits a complete `LinkItem`. This is simple and correct and bounds memory to *items currently in flight*. For very large files the Mac transport MAY bypass the in-memory assembler and stream a representation's chunks straight to a temp file (writing as frames arrive), then construct a `.file` `LinkItem` referencing the path — that is a transport/inbound concern handled in a later change. The protocol exposes the frame stream cleanly enough to support both. *Alternative considered:* make the assembler itself write to disk — rejected: it would force I/O and a filesystem dependency into the pure package.

**D5 — Concrete types:** `messageID: UUID`; chunk `seq: UInt32`; manifest `[String: UInt32]` (UTI → total bytes); `protocolVersion` split as `major`/`minor` (refuse on major mismatch, accept newer minor and ignore unknown optional fields). Chunk byte bound is a configurable constant (default 256 KiB) and the decoder's max-frame length is a separate, larger configurable cap (default e.g. 8 MiB for a single frame; large representations are *many* chunks, so no single frame is huge).

**D6 — All multibyte integers are big-endian on the wire; all `Codable` bodies use a deterministic encoder.** Fixed endianness makes the format portable and the tests reproducible.

**D7 — Value types are `Sendable`; the assembler is not internally synchronized.** Frames and `LinkItem` are immutable value types (`Sendable`). The `InboundAssembler` is a `mutating struct` (or a plain class) driven by the transport's own single serial context (an actor/connection queue in a later change); the protocol does not impose locking it doesn't need.

## Risks / Trade-offs

- **In-memory assembly of a huge file → memory spike.** → The assembler is bounded to in-flight items, and D4 documents the disk-streaming seam the Mac transport will use for `.file`; the protocol stays pure while the heavy path streams to disk in the inbound change.
- **Hand-rolled binary framing is bug-prone.** → Exhaustive, adversarial codec tests: round-trip every frame, split-buffer reassembly, oversize-length rejection, truncation, bad-magic, unknown-tag, duplicate/out-of-range seq, manifest mismatch, cancel-mid-flight. Treat the test suite as the real spec.
- **DTO drift between the two repos.** → Single source of truth (the package) + `protocolVersion` + a `hello` handshake that refuses incompatible peers loudly instead of mis-parsing.
- **`Codable` evolution breaking old peers.** → Additive-only changes to control/header bodies, optional fields with defaults, minor-version bump; a breaking change is a major-version bump that the handshake rejects.

## Migration Plan

Purely additive: a new package target + test target in `Package.swift`. Nothing imports it yet, so there is no migration and no rollback risk — reverting is deleting the target. The Mac inbound/transport changes and the iOS app add their dependency on it in their own changes.

## Open Questions

- Default chunk size (256 KiB) and max-frame cap (8 MiB) are starting values; tune against real AWDL throughput once `device-link-transport` can measure it. (Constants, not contract — safe to tune.)
- Per-item integrity: rely on TLS (transport) for confidentiality+integrity in v1, or add an optional per-item content hash to `itemEnd` for end-to-end verification? Leaning on TLS for v1; the `itemEnd` frame leaves room to add an optional hash later without a major bump.
- Resumable-across-reconnect transfer (offset-resume after a dropped link) is deferred; the manifest + seq model is forward-compatible with adding a `resumeFrom` to `itemBegin` later.
