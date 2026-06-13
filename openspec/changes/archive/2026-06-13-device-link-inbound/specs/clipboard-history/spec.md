## ADDED Requirements

### Requirement: Entry provenance
A `ClipboardEntry` SHALL carry an optional provenance describing where it came from — a device origin distinct from the existing app `sourceApp`. The provenance SHALL be additive and backward-compatible: an entry persisted before this field existed SHALL load successfully with provenance treated as local, and entries created by local pasteboard capture SHALL NOT set a peer origin. The provenance SHALL distinguish a local copy from one received from a paired device (and, for a paired device, MAY carry that device's name).

#### Scenario: Legacy entries load as local
- **WHEN** a persisted history index written before the provenance field existed is loaded
- **THEN** every entry loads successfully and is treated as local provenance (no decode failure)

#### Scenario: Local capture is not marked peer
- **WHEN** an entry is created from local pasteboard capture
- **THEN** its provenance is not a peer origin

### Requirement: Clipboard band shows peer provenance
The Clipboard band SHALL visually mark an entry whose provenance is a paired device, so the user can distinguish a mirrored item from a local copy. The marker SHALL identify the source device when its name is known and SHALL be unobtrusive (it does not change the entry's key text or value preview).

#### Scenario: Peer entry shows a source chip
- **WHEN** the Clipboard band renders an entry whose provenance is a paired device named "iPhone"
- **THEN** the entry shows a small "from iPhone" marker alongside its key

#### Scenario: Local entry shows no chip
- **WHEN** the Clipboard band renders a locally-captured entry
- **THEN** no provenance marker is shown
