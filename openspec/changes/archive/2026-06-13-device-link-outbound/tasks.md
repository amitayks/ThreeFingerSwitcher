## 1. Outbound adapter

- [x] 1.1 `Clipboard/LinkOutboundAdapter.swift`: `struct LinkOutboundAdapter` importing `DeviceLinkProtocol`; a `ClipboardKind → LinkItemKind` 1:1 map.
- [x] 1.2 `func linkItem(from: ClipboardEntry, origin: DeviceIdentity, messageID: UUID = UUID()) throws -> LinkItem`: non-file kinds carry inline rep bytes per UTI; `.file` resolves the `file://` rep, reads bytes, carries them under `public.data` with `suggestedName` = filename; stamps `origin`; throws `LinkOutboundError` on no content / unreadable file.

## 2. Service send

- [x] 2.1 `DeviceLink/DeviceLinkService.swift`: add `func send(_ item: LinkItem)` dispatching on the queue and forwarding to each `LinkConnection`.

## 3. Tests

- [x] 3.1 Text/url/color mapping: kind + representation bytes + local origin stamped.
- [x] 3.2 Empty entry → typed error.
- [x] 3.3 File entry referencing a real temp file → `.file` item with the file's bytes + suggestedName == filename; missing file → typed error.
- [x] 3.4 Round-trip: text entry → outbound → inbound preserves plain-text bytes; file entry → outbound → inbound writes an inbox file whose bytes equal the original.

## 4. Verify

- [x] 4.1 `swift build --target ThreeFingerSwitcherCore` clean; `swift test` green (adapter + round-trip + no regressions).
