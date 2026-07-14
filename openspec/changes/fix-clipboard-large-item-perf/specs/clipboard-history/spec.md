## ADDED Requirements

### Requirement: Bounded resource use for large entries

The clipboard history SHALL remain responsive and SHALL NOT crash regardless of an entry's payload size. Recording a copy, building the Clipboard band, scrubbing between entries, and previewing an entry's value SHALL each run in time and memory that do **not** scale with the payload size. Specifically: capturing a copy SHALL NOT block the main thread on disk I/O; building the band and scrubbing SHALL hold at most one entry's full payload in memory at a time (the band SHALL NOT load every windowed entry's full payload at once); and the value preview SHALL render a **bounded** amount of content (truncating large content) rather than laying out the entire payload. The system MAY refuse to record a single payload larger than a hard capture ceiling. Faithful paste of the full content SHALL still be preserved (see "Paste on fire into the captured front app").

#### Scenario: Copying a very large item does not freeze the app
- **WHEN** the user copies a multi-megabyte text item while recording is enabled
- **THEN** the copy is recorded without a perceptible stall of the app's main thread, and no subsequent copy re-processes the large payload in a way that stalls the UI

#### Scenario: Opening the band with large entries does not crash
- **WHEN** the launcher opens with one or more large entries in the recent window
- **THEN** the Clipboard band builds without loading every entry's full payload into memory and the app does not crash

#### Scenario: Previewing a huge entry stays bounded
- **WHEN** the user selects an entry whose content is very large
- **THEN** the value preview shows a bounded excerpt (indicating it is truncated) instead of rendering the entire payload, and remains responsive

#### Scenario: A pathologically large payload is not recorded
- **WHEN** a single copied payload exceeds the hard capture ceiling
- **THEN** it is skipped rather than recorded, and no partial or corrupt entry is created

## MODIFIED Requirements

### Requirement: Faithful multi-representation capture

When capturing a copy, the system SHALL store enough of the pasteboard item's representations to reproduce it faithfully on a later paste, not merely a plain-text rendering. Rich text SHALL retain both its rich form and a plain-text fallback; an image copied as data SHALL retain its image bytes; a copied file SHALL retain its file-URL reference (and MAY cache a content thumbnail) rather than the file's bytes; a copied color or URL SHALL retain its canonical string. Each entry SHALL also derive a short single-line **key** for the list (e.g. the first line of text, the file name, an image's pixel dimensions, or the color value) and SHALL record the source application when available. Deriving the key and any de-dup fingerprint SHALL be bounded in cost — the system SHALL NOT retain a full copy of the raw payload in the entry's key or fingerprint.

#### Scenario: Rich text keeps both forms
- **WHEN** styled text is copied
- **THEN** the entry stores the rich representation and a plain-text fallback, and pasting it later reproduces the styled text where supported

#### Scenario: Image keeps its bytes
- **WHEN** an image is copied as data (no backing file)
- **THEN** the entry stores the image bytes and a key describing it (e.g. its pixel dimensions)

#### Scenario: File keeps a reference
- **WHEN** a file is copied in Finder
- **THEN** the entry stores the file-URL reference (not a byte copy) and a key showing the file name

#### Scenario: Large payloads do not bloat the key or fingerprint
- **WHEN** a large text item is copied
- **THEN** the entry's key is a short single-line label and its de-dup fingerprint is a bounded value (e.g. a content hash), neither of which grows with the size of the copied content

### Requirement: De-duplication and retention caps

The system SHALL de-duplicate entries: copying content identical to an existing entry SHALL update that entry's recency rather than create a duplicate. De-duplication SHALL be decided by a **bounded content fingerprint** (e.g. a content hash) whose size and comparison cost do NOT scale with the payload size, so recording remains cheap regardless of how large the copied content is. The system SHALL bound storage by configurable caps on entry **count**, total **bytes**, and **age**, evicting the oldest non-pinned entries first when a cap is exceeded. Pinned entries SHALL be exempt from count/age eviction.

#### Scenario: Re-copying does not duplicate
- **WHEN** the user copies a value that already exists in history
- **THEN** no second entry is created and the existing entry becomes the most recent

#### Scenario: De-dup cost does not scale with payload size
- **WHEN** the user copies large content and later copies identical large content
- **THEN** the duplicate is detected via a bounded fingerprint (not a full-content comparison) and the existing entry's recency is updated

#### Scenario: Oldest entries evict past the cap
- **WHEN** recording a new entry would exceed a retention cap
- **THEN** the oldest non-pinned entries are evicted until the store is within the cap

#### Scenario: Pinned entries survive eviction
- **WHEN** a retention cap is exceeded and old entries are evicted
- **THEN** pinned entries are retained regardless of age or count

### Requirement: Versioned on-disk storage separate from favorites

The system SHALL persist clipboard history on disk under the app's Application Support directory, **separate** from the Favorites record (which remains a small UserDefaults blob). The store SHALL keep small payloads (references, colors, short text) in an index and externalize **large payloads — including large text as well as image bytes and cached thumbnails — as blob files** referenced by the index, so the index stays small regardless of any entry's content size. Writing an entry to disk SHALL NOT block the main (capture) thread on the payload's I/O. The store SHALL carry a schema version that allows forward migration, and clipboard entries SHALL NEVER be written into the Favorites/launch-items record.

#### Scenario: History persists across relaunch
- **WHEN** the user records history, quits, and relaunches the app
- **THEN** the stored entries (and pins) are restored from disk

#### Scenario: Large text is externalized, keeping the index small
- **WHEN** a large text item is recorded
- **THEN** its bytes are stored as a blob file and the index entry stays small (it does not embed the full text), so persisting further copies does not rewrite the large payload inline

#### Scenario: Favorites record stays clipboard-free
- **WHEN** clipboard history is recorded
- **THEN** the Favorites record is unchanged and contains no clipboard entries

### Requirement: Synthetic Clipboard band built from the store

While the opt-in is enabled, the launcher SHALL present a **Clipboard** band as the **last** band. The band SHALL be **built fresh on every launcher open** from the store as a recent-window slice (a tunable number of most-recent entries) with **pinned entries ordered first**, and SHALL be ephemeral — recreated each open and never stored in the Favorites record nor designated as the home band. Building the band SHALL NOT load every windowed entry's full payload into memory: band items SHALL carry only the metadata needed to list and preview them plus a **bounded preview** of the value, and the full representations SHALL be materialized on demand (for the selected entry's preview and on paste) rather than held for the whole window. The value preview SHALL render a bounded excerpt of large content (indicating truncation) so it stays responsive and cannot crash, while small content renders in full as before. When history is empty (feature on but nothing recorded yet, or just cleared), the band SHALL show an empty state rather than vanishing.

#### Scenario: Clipboard is the last band
- **WHEN** the launcher opens with the opt-in enabled
- **THEN** a Clipboard band appears as the last band, after the user's favorites bands

#### Scenario: Band reflects the current store on each open
- **WHEN** new entries are recorded and the launcher is opened again
- **THEN** the band shows the latest recent-window slice, pinned entries first

#### Scenario: Band build does not materialize full payloads for the whole window
- **WHEN** the band is built from a window that includes large entries
- **THEN** only bounded previews (and metadata) are loaded for the listed entries, and a full payload is materialized only when its entry is previewed or fired

#### Scenario: Large value preview is truncated and responsive
- **WHEN** an entry with very large content is selected in the band
- **THEN** its value preview shows a bounded, truncated excerpt and the UI stays responsive

#### Scenario: Empty history shows an empty state
- **WHEN** the opt-in is enabled but no entries have been recorded
- **THEN** the Clipboard band is present and shows an empty state, and is not the launcher's home band

### Requirement: Paste on fire into the captured front app

Firing a Clipboard entry (lift while armed, via the same dwell-to-arm/lift semantics as any launcher item) SHALL restore that entry's **full** stored representations to the general pasteboard and paste into the application that was frontmost when the launcher opened, by synthesizing the paste shortcut, using only the already-held Accessibility permission. Because the band carries only a bounded preview, the full representations SHALL be materialized on demand from the store at fire time (identified by the entry's stable id), so the pasted content is the complete original, not the truncated preview. The chosen entry SHALL become the current clipboard contents. A stale file reference (the file no longer exists) SHALL fail gracefully without crashing.

To paste usefully into apps that do not accept the rich type, the system SHALL also place compatibility representations alongside the original: a **plain-text fallback** when the entry has none of its own — a file/folder's POSIX path, a URL's string, or a color's hex — and, for images, **both PNG and TIFF** so an app that wants either accepts the paste. The original rich representation (e.g. the file-url) SHALL be kept too, so a file still pastes as a file in Finder/IDEs while a text field pastes its path.

#### Scenario: Firing pastes the full content into the prior front app
- **WHEN** an entry is armed and the fingers lift
- **THEN** the entry's full representations (materialized on demand, not the truncated band preview) are placed on the pasteboard and pasted into the app that was frontmost when the launcher opened

#### Scenario: Chosen entry becomes the clipboard
- **WHEN** an entry is fired
- **THEN** the general pasteboard holds that entry's content afterward

#### Scenario: Firing a large entry pastes the whole payload
- **WHEN** a large text entry (shown truncated in the preview) is fired
- **THEN** the complete original content is placed on the pasteboard and pasted, not the truncated preview

#### Scenario: File pastes as a file or as its path
- **WHEN** a copied file or folder entry is fired
- **THEN** the pasteboard carries both the file-url (so Finder/IDEs paste the file) and the POSIX path as plain text (so a text field pastes the path)

#### Scenario: Image is offered in multiple formats
- **WHEN** an image entry is fired
- **THEN** the pasteboard carries both PNG and TIFF so apps accepting either format paste the image

#### Scenario: Stale file reference fails gracefully
- **WHEN** a fired file entry references a file that no longer exists
- **THEN** the paste does nothing harmful and the app does not crash
