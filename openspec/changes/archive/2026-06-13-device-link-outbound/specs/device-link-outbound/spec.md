## ADDED Requirements

### Requirement: Map a ClipboardEntry to a LinkItem
The system SHALL convert a materialized `ClipboardEntry` into a `LinkItem`: the kind SHALL map 1:1 between `ClipboardKind` and `LinkItemKind`; for text/richText/image/color/url the item SHALL carry the entry's inline representation bytes keyed by the same UTIs; the item SHALL be stamped with a provided **local device identity** as origin; and a fresh message id SHALL be assigned. An entry with no usable inline content SHALL produce a typed error rather than an empty item.

#### Scenario: Text entry maps to a text item
- **WHEN** a `text` `ClipboardEntry` with inline plain-text bytes is adapted with a local identity
- **THEN** the result is a `LinkItem` of kind `text` whose plain-text representation equals those bytes and whose origin is the local identity

#### Scenario: An empty entry is rejected
- **WHEN** an entry with no inline representation bytes is adapted
- **THEN** a typed error is thrown (no empty item is produced)

### Requirement: File entries send their bytes
For a `file` `ClipboardEntry`, the adapter SHALL resolve the entry's `file://` reference, read the referenced file's bytes, and produce a `LinkItem` of kind `file` carrying those bytes with `suggestedName` set to the file's name. If the file cannot be read, a typed error SHALL be thrown.

#### Scenario: A file entry carries the file's content
- **WHEN** a `file` entry referencing an existing file is adapted
- **THEN** the resulting `file` `LinkItem` carries the file's bytes and a suggested name equal to the file's last path component

#### Scenario: An unreadable file errors
- **WHEN** a `file` entry references a path that does not exist or cannot be read
- **THEN** a typed error is thrown

### Requirement: Round-trip fidelity with the inbound adapter
An item produced by the outbound adapter and then processed by the inbound adapter SHALL reconstruct an equivalent `ClipboardEntry` content. For text/url the representation bytes SHALL be preserved; for a file the received inbox file's bytes SHALL equal the original file's bytes.

#### Scenario: Text round-trips
- **WHEN** a text entry is adapted outbound to a `LinkItem` and then adapted inbound
- **THEN** the resulting entry's plain-text bytes equal the original's

#### Scenario: File content round-trips
- **WHEN** a file entry is adapted outbound and then inbound
- **THEN** the inbox file the inbound adapter writes holds bytes equal to the original file's

### Requirement: Service send to connected peers
The transport service SHALL expose sending a `LinkItem` to its currently-connected peers, dispatched on its own serial context. (Choosing a specific target device and the user trigger are outside this capability.)

#### Scenario: Send forwards to connections
- **WHEN** the service has connected peers and is asked to send an item
- **THEN** each connection sends the item to its peer
