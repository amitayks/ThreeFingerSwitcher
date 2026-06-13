# device-link-mirror-store Specification

## Purpose
TBD - created by archiving change device-link-mirror-store. Update Purpose after archive.
## Requirements
### Requirement: MovedItem model and LinkItem mapping
The package SHALL define a `MovedItem` value type recording one moved thing: a stable id, a direction (`sent` or `received`), the item kind, a single-line display title, an optional peer device name, a timestamp, and the materialized representation bytes keyed by UTI. It SHALL provide a builder from a `LinkItem` that carries the representations and derives the title (first non-empty line for text/url, the suggested name for a file, a fixed label for image/color). `MovedItem` SHALL be `Codable` and `Sendable`.

#### Scenario: Build a moved item from a text LinkItem
- **WHEN** a `text` `LinkItem` is mapped with direction `received`
- **THEN** the `MovedItem` has that direction, kind `text`, a title equal to the text's first line, and the same representation bytes

#### Scenario: A file item's title is its suggested name
- **WHEN** a `file` `LinkItem` with a suggested name is mapped
- **THEN** the `MovedItem`'s title is that suggested name

### Requirement: Persistent moved-item store
The package SHALL provide a `MovedItemStore` persisting to an injectable directory as a small JSON index of metadata plus per-representation blob files (so the index stays small and binary payloads are externalized). It SHALL support inserting an item (newest-first; an item with an existing id replaces the prior one), listing items newest-first with their representation bytes materialized from blobs, removing by id, and clearing. Persisted items SHALL reload across store instances with their bytes intact.

#### Scenario: Insert then list newest-first
- **WHEN** two items are inserted at different times
- **THEN** listing returns them newest-first, each with its representation bytes

#### Scenario: Bytes survive reload
- **WHEN** an item with binary representation bytes is inserted and a new store instance is opened on the same directory
- **THEN** the item is listed with byte-identical representations (materialized from its blobs)

#### Scenario: Remove and clear
- **WHEN** an item is removed by id (or the store is cleared)
- **THEN** it (or everything) is gone from the listing and its blob files are deleted

### Requirement: Count-cap eviction
The store SHALL enforce a configurable maximum item count, evicting the oldest items beyond the cap on insert and deleting their blob files, so the store does not grow without bound.

#### Scenario: Oldest evicted beyond the cap
- **WHEN** more items than the cap are inserted
- **THEN** only the newest `cap` items remain listed, and the evicted items' blob files are removed

