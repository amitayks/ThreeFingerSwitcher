## ADDED Requirements

### Requirement: Map a received LinkItem to a ClipboardEntry
The system SHALL convert a `DeviceLinkProtocol.LinkItem` into a `ClipboardEntry`, mirroring the per-kind representation building used for local pasteboard capture. For each `LinkItemKind` it SHALL populate the `ClipboardEntry.representations` keyed by the same UTI strings used for local capture, derive a single-line `key` via the existing key helpers, and derive a stable `fingerprint` consistent with local capture so peer and local copies of identical content de-duplicate to one entry. Text/richText/url/color/image map to inline representations; `file` is handled by the inbox requirement below.

#### Scenario: Text item maps to a text entry
- **WHEN** a `LinkItem` of kind `text` carrying UTF-8 plain-text bytes is adapted
- **THEN** the result is a `ClipboardEntry` of kind `text` whose plain-text representation equals those bytes, with a first-line key and a fingerprint equal to the one a local copy of the same text would produce

#### Scenario: Identical local and peer content de-duplicates
- **WHEN** the same text is first copied locally and later received from a peer
- **THEN** both produce the same fingerprint, so inserting the peer entry bumps the existing entry's recency rather than creating a duplicate

#### Scenario: Image item carries its bytes and dimensions key
- **WHEN** a `LinkItem` of kind `image` carrying PNG/TIFF bytes is adapted
- **THEN** the entry holds the image representation and a key describing its pixel dimensions

### Requirement: Persist received files to a dedicated inbox directory
For a `LinkItem` of kind `file`, the system SHALL write the transferred bytes to a dedicated **inbox directory** (a sibling of the store's `blobs/` directory, e.g. `…/clipboard/inbox`), under a name derived from the message id and the item's suggested name, and SHALL produce a `.file` `ClipboardEntry` whose file-URL representation points at the written path. The inbox SHALL be outside the `blobs/` deterministic-naming scheme so the store's blob externalization never overwrites or prunes a received file. The inbox directory SHALL be injectable (for testing) and created on demand.

#### Scenario: A received file is written and referenced
- **WHEN** a `LinkItem` of kind `file` with bytes B and suggested name N is adapted against an inbox directory D
- **THEN** B is written to a file under D whose name incorporates N, and the resulting `.file` entry's file-URL representation resolves to that file

#### Scenario: Inbox is created on demand
- **WHEN** the inbox directory does not yet exist and a file item is adapted
- **THEN** the directory is created and the write succeeds

#### Scenario: A received file references a real, openable path
- **WHEN** a file entry produced from a peer item is later pasted
- **THEN** its file-URL representation is a valid `file://` URL to the inbox copy (so a paste targets a real file, not a dangling reference)

### Requirement: Stamp peer provenance on received entries
Every `ClipboardEntry` produced from a `LinkItem` SHALL carry `origin = .peer(deviceName:)` taken from the item's originating device identity (the device name when present). Entries produced from local pasteboard capture SHALL NOT be stamped peer (their origin remains unset / local).

#### Scenario: Peer item is stamped with its device name
- **WHEN** a `LinkItem` whose origin device name is "iPhone" is adapted
- **THEN** the resulting entry's `origin` is `.peer(deviceName: "iPhone")`

#### Scenario: Missing device name still marks peer
- **WHEN** a `LinkItem` with no origin device name is adapted
- **THEN** the resulting entry's `origin` is `.peer(deviceName: nil)`, distinct from local

### Requirement: Insert received items through the existing store seam
The adapter's output SHALL be inserted via the existing `ClipboardStore.insert` write path, so received items are subject to the same de-duplication, retention caps (count / bytes / age), pinned-exemption, and band assembly as local copies. There SHALL be no separate peer-only storage or retention path.

#### Scenario: Retention applies to peer items
- **WHEN** received items exceed the configured retention caps
- **THEN** they are evicted by the same rules as local items (oldest non-pinned first), with pinned entries exempt

#### Scenario: Received item appears in the Clipboard band
- **WHEN** a peer item is inserted while the Clipboard band is shown on the next launcher open
- **THEN** it appears in the band's recent window like any other entry
