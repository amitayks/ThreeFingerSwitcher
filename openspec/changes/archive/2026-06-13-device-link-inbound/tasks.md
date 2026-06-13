## 1. Dependency wiring

- [x] 1.1 In `Package.swift`, add `DeviceLinkProtocol` to `ThreeFingerSwitcherCore`'s dependencies.
- [x] 1.2 Confirm `swift build` still builds Core with the new dependency.

## 2. Provenance on the model

- [x] 2.1 Add `ClipboardOrigin` (`enum { case local; case peer(deviceName: String?) }`, `Codable`, `Equatable`) alongside `ClipboardEntry`.
- [x] 2.2 Add `var origin: ClipboardOrigin?` to `ClipboardEntry` with a `nil` default in the initializer (additive, no schema bump). Add an `isPeer`/origin helper that reads `nil` as local.
- [x] 2.3 Verify existing `ClipboardStore`/entry tests still pass (old indexes decode with `origin == nil`); confirm no test asserts a different `currentSchemaVersion`.

## 3. The inbound adapter

- [x] 3.1 Create `Clipboard/LinkInboundAdapter.swift`: `struct LinkInboundAdapter { let inboxDirectory: URL }` importing `DeviceLinkProtocol`.
- [x] 3.2 `func entry(from item: LinkItem) throws -> ClipboardEntry` mapping per `LinkItemKind`, mirroring `ClipboardMonitor.makeEntry`: text/richText/url/color inline; image uses `NSBitmapImageRep` for the dimensions key; each derives `key` via `ClipboardKey` and a `fingerprint` matching local convention; stamps `origin = .peer(deviceName: item.origin?.name)`.
- [x] 3.3 File case: create `inboxDirectory` on demand, write the item's bytes to `received-<messageID>-<suggestedName>`, set `representations[ClipboardUTI.fileURL] = .inline(Data(url.absoluteString.utf8))`, key = file name, fingerprint = `"file:<path>"`.
- [x] 3.4 Reuse an FNV-1a hash helper (as in `ClipboardMonitor`) for image/color/rtf fingerprints so peer and local fingerprints match.

## 4. Band provenance chip

- [x] 4.1 In `Overlay/ClipboardBandView.swift`, render a small "from \<device\>" chip when the entry's `origin` is `.peer`; no chip for local. (Compile-verified under `swift build`; appearance user-verified.)

## 5. Tests

- [x] 5.1 `Tests/ThreeFingerSwitcherTests/LinkInboundAdapterTests.swift`: text item → text entry with matching plain-text rep + fingerprint equal to a local copy's (de-dup proof).
- [x] 5.2 image item → image entry with dimensions key; url/color/richText mapping.
- [x] 5.3 file item → bytes written under a temp inbox dir, `.file` entry whose file-URL resolves to the written file; inbox created on demand.
- [x] 5.4 provenance: peer device name stamped; missing name → `.peer(deviceName: nil)`; local entry → not peer.
- [x] 5.5 inserting an adapted entry into a temp `ClipboardStore` de-dups against an identical local entry (recency bump, not a duplicate).

## 6. Verify

- [x] 6.1 `swift build` clean (Core + view); `swift test` green (new adapter tests + no regressions in the existing suite).
- [x] 6.2 `DeviceLinkProtocol` import confined to the adapter (Core doesn't leak protocol types into unrelated files).
