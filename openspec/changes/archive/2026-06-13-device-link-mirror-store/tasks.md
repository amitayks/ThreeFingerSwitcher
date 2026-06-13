## 1. Package wiring

- [x] 1.1 `Package.swift`: add a `DeviceLinkMirror` library product + target (path `Sources/DeviceLinkMirror`, dep `DeviceLinkProtocol`, v6) and a `DeviceLinkMirrorTests` test target (v5).

## 2. Model

- [x] 2.1 `MovedItem.swift`: `MoveDirection` enum; `MovedItem` (`Codable`/`Equatable`/`Identifiable`/`Sendable`) with id/direction/kind/title/peerName/movedAt/representations.
- [x] 2.2 `MovedItem.from(_ LinkItem, direction:at:)` + title derivation (text/url first line, file suggestedName, image/color labels).

## 3. Store

- [x] 3.1 `MovedItemStore.swift`: injectable directory; private `StoredItem` (metadata + `repFiles: [uti: blobName]`); in-memory `[StoredItem]`.
- [x] 3.2 `insert` (write blobs, replace-by-id, append, evict, save); `list()` (newest-first, materialize blobs → `MovedItem`); `remove(id:)`/`clear()` (delete blobs); `count`.
- [x] 3.3 Count-cap eviction deletes evicted items' blobs; load/save JSON index.

## 4. Tests

- [x] 4.1 `from(_:)` mapping: text title = first line; file title = suggested name; representations carried.
- [x] 4.2 insert → list newest-first; bytes present.
- [x] 4.3 reload: new store on same dir → byte-identical representations (blob materialization).
- [x] 4.4 remove/clear remove entries (and their blobs are gone from disk).
- [x] 4.5 count cap: insert > cap → only newest `cap` listed; evicted blobs deleted.

## 5. Verify

- [x] 5.1 `swift build --target DeviceLinkMirror` clean; `swift test --filter DeviceLinkMirrorTests` green; full `swift test` no regressions.
