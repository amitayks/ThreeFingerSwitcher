## Why

The iPhone app is "a scrollable list of what has moved." That list needs a local store of moved items — things sent to the Mac and things received from it — that survives relaunch and holds enough to re-share a received item (its bytes). This is pure Foundation logic (Codable + files), so it belongs in a shared, macOS-testable SwiftPM package the iOS app consumes — keeping the store fully unit-tested even though the iOS UI is not. It mirrors the Mac's `ClipboardStore` design (on-disk index + externalized blobs) but is simpler (no pins/de-dup; newest-first with a count cap), and it maps directly from a `LinkItem`.

## What Changes

- **A new pure SwiftPM library `DeviceLinkMirror`** (depends only on `DeviceLinkProtocol`), consumed by the iOS app. Builds/tests under `swift build`/`swift test` on macOS.
- **`MovedItem`** — a `Codable`, `Sendable` record of one moved thing: id, **direction** (`sent`/`received`), `LinkItemKind`, a display **title**, the peer name, a timestamp, and the materialized representation bytes. A `from(_ LinkItem, direction:at:)` builder derives the title (first line of text, the file's suggested name, "Image"/"Color") and carries the representations.
- **`MovedItemStore`** — an on-disk store: a small JSON index of metadata plus **blob files** for each representation's bytes (so the index stays tiny and images/files don't bloat it). Insert (newest-first, replacing a same-id item), list (materialized, newest-first), remove, clear, and a **count cap** that evicts the oldest and deletes its blobs. Injectable directory for tests.

## Capabilities

### New Capabilities
- `device-link-mirror-store`: the iOS app's local record of moved items — `MovedItem` (with `LinkItem` mapping + title derivation) and `MovedItemStore` (index + per-representation blobs, newest-first insert, count-cap eviction with blob cleanup, list/remove/clear). Pure Foundation, fully unit-tested, shared with the Mac repo's package graph.

## Impact

- **New:** `Sources/DeviceLinkMirror/MovedItem.swift`, `MovedItemStore.swift`; `Tests/DeviceLinkMirrorTests/MovedItemStoreTests.swift`. `Package.swift` gains the `DeviceLinkMirror` library product + target + test target (depends on `DeviceLinkProtocol`).
- **Modified:** `Package.swift` only.
- **Build/permissions:** pure logic, MLX/UIKit-free, in the `swift test` fast loop; no permission/distribution impact. The iOS Xcode app will reference this product by local package path.
- **Privacy/speed/UX:** privacy — the store is local to the device; UX — backs the scrollable "what moved" list.
