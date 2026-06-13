# clipboard-history Specification

## Purpose

Define the opt-in clipboard history feature: a background recorder that snapshots the general pasteboard, faithful multi-representation capture, privacy controls (concealed content, excluded apps, pause, clear), de-duplication and retention caps, versioned on-disk storage separate from favorites, the synthetic Clipboard launcher band, the deferred-reorder pin model, and paste-on-fire into the captured front app.
## Requirements
### Requirement: Opt-in clipboard recording

The system SHALL record clipboard history only while a "Keep clipboard history" opt-in is enabled, and the opt-in SHALL default to OFF. While enabled, the recorder SHALL detect new copies by polling the general pasteboard's change counter (macOS provides no change event) at a tunable interval and snapshot the pasteboard each time the counter advances. While disabled, the recorder SHALL NOT run, SHALL NOT read clipboard contents, and no Clipboard band SHALL be shown. Enabling or disabling the opt-in SHALL take effect without relaunching the app and SHALL NOT request any new permission (reading the general pasteboard needs none).

#### Scenario: Recording is off by default
- **WHEN** the app runs for the first time with no prior settings
- **THEN** clipboard history is not recorded and no Clipboard band appears in the launcher

#### Scenario: Enabling starts recording
- **WHEN** the user enables "Keep clipboard history" and then copies something
- **THEN** the copied content is captured as a new history entry

#### Scenario: Disabling stops recording immediately
- **WHEN** the user disables the opt-in
- **THEN** the recorder stops polling and reading the pasteboard, and the Clipboard band no longer appears

### Requirement: Faithful multi-representation capture

When capturing a copy, the system SHALL store enough of the pasteboard item's representations to reproduce it faithfully on a later paste, not merely a plain-text rendering. Rich text SHALL retain both its rich form and a plain-text fallback; an image copied as data SHALL retain its image bytes; a copied file SHALL retain its file-URL reference (and MAY cache a content thumbnail) rather than the file's bytes; a copied color or URL SHALL retain its canonical string. Each entry SHALL also derive a short single-line **key** for the list (e.g. the first line of text, the file name, an image's pixel dimensions, or the color value) and SHALL record the source application when available.

#### Scenario: Rich text keeps both forms
- **WHEN** styled text is copied
- **THEN** the entry stores the rich representation and a plain-text fallback, and pasting it later reproduces the styled text where supported

#### Scenario: Image keeps its bytes
- **WHEN** an image is copied as data (no backing file)
- **THEN** the entry stores the image bytes and a key describing it (e.g. its pixel dimensions)

#### Scenario: File keeps a reference
- **WHEN** a file is copied in Finder
- **THEN** the entry stores the file-URL reference (not a byte copy) and a key showing the file name

### Requirement: Privacy — concealed content, excluded apps, pause, and clear

The system SHALL NOT record pasteboard items marked with the standard concealed or transient types (`org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`) that password managers and similar tools use to opt out of clipboard managers. The system SHALL support a user-managed list of excluded source applications whose copies are never recorded, a way to pause recording without disabling the feature, and a "clear history" action that permanently removes stored entries (with an option to also clear pinned entries). All history SHALL be stored locally only and SHALL never be transmitted off the device.

#### Scenario: Concealed copies are skipped
- **WHEN** a password manager copies a secret marked concealed/transient
- **THEN** no history entry is created for it

#### Scenario: Excluded app is not recorded
- **WHEN** a copy originates from an application on the exclusion list
- **THEN** no history entry is created for it

#### Scenario: Clear removes stored history
- **WHEN** the user invokes "clear history"
- **THEN** the stored entries are permanently deleted and the Clipboard band is empty on its next open

### Requirement: De-duplication and retention caps

The system SHALL de-duplicate entries: copying content identical to an existing entry SHALL update that entry's recency rather than create a duplicate. The system SHALL bound storage by configurable caps on entry **count**, total **bytes**, and **age**, evicting the oldest non-pinned entries first when a cap is exceeded. Pinned entries SHALL be exempt from count/age eviction.

#### Scenario: Re-copying does not duplicate
- **WHEN** the user copies a value that already exists in history
- **THEN** no second entry is created and the existing entry becomes the most recent

#### Scenario: Oldest entries evict past the cap
- **WHEN** recording a new entry would exceed a retention cap
- **THEN** the oldest non-pinned entries are evicted until the store is within the cap

#### Scenario: Pinned entries survive eviction
- **WHEN** a retention cap is exceeded and old entries are evicted
- **THEN** pinned entries are retained regardless of age or count

### Requirement: Versioned on-disk storage separate from favorites

The system SHALL persist clipboard history on disk under the app's Application Support directory, **separate** from the Favorites record (which remains a small UserDefaults blob). The store SHALL keep small payloads (text, references, colors) in an index and large payloads (image bytes, cached thumbnails) as blob files. The store SHALL carry a schema version that allows forward migration, and clipboard entries SHALL NEVER be written into the Favorites/launch-items record.

#### Scenario: History persists across relaunch
- **WHEN** the user records history, quits, and relaunches the app
- **THEN** the stored entries (and pins) are restored from disk

#### Scenario: Favorites record stays clipboard-free
- **WHEN** clipboard history is recorded
- **THEN** the Favorites record is unchanged and contains no clipboard entries

### Requirement: Synthetic Clipboard band built from the store

While the opt-in is enabled, the launcher SHALL present a **Clipboard** band as the **last** band. The band SHALL be **built fresh on every launcher open** from the store as a recent-window slice (a tunable number of most-recent entries) with **pinned entries ordered first**, and SHALL be ephemeral — recreated each open and never stored in the Favorites record nor designated as the home band. When history is empty (feature on but nothing recorded yet, or just cleared), the band SHALL show an empty state rather than vanishing.

#### Scenario: Clipboard is the last band
- **WHEN** the launcher opens with the opt-in enabled
- **THEN** a Clipboard band appears as the last band, after the user's favorites bands

#### Scenario: Band reflects the current store on each open
- **WHEN** new entries are recorded and the launcher is opened again
- **THEN** the band shows the latest recent-window slice, pinned entries first

#### Scenario: Empty history shows an empty state
- **WHEN** the opt-in is enabled but no entries have been recorded
- **THEN** the Clipboard band is present and shows an empty state, and is not the launcher's home band

### Requirement: Pin model with deferred reorder

An entry SHALL be pinnable and unpinnable, and the pin state SHALL persist in the store. Pinned entries SHALL be ordered before non-pinned entries when the band is **built** (on a subsequent open). Toggling a pin **during an open launcher session SHALL NOT reorder the live list** — the selected entry stays in place and is marked pinned/unpinned — so the selection never jumps out from under the user; the pinned-first ordering is applied on the next build.

#### Scenario: Pin persists and floats to top next time
- **WHEN** the user pins an entry, then closes and reopens the launcher
- **THEN** that entry is shown among the pinned entries at the top of the Clipboard band

#### Scenario: Pinning mid-session does not move the selection
- **WHEN** the user pins the currently selected entry while the launcher is open
- **THEN** the entry is marked pinned but stays in its current position for the rest of this session (no live reorder)

### Requirement: Paste on fire into the captured front app

Firing a Clipboard entry (lift while armed, via the same dwell-to-arm/lift semantics as any launcher item) SHALL restore that entry's stored representations to the general pasteboard and paste into the application that was frontmost when the launcher opened, by synthesizing the paste shortcut, using only the already-held Accessibility permission. The chosen entry SHALL become the current clipboard contents. A stale file reference (the file no longer exists) SHALL fail gracefully without crashing.

To paste usefully into apps that do not accept the rich type, the system SHALL also place compatibility representations alongside the original: a **plain-text fallback** when the entry has none of its own — a file/folder's POSIX path, a URL's string, or a color's hex — and, for images, **both PNG and TIFF** so an app that wants either accepts the paste. The original rich representation (e.g. the file-url) SHALL be kept too, so a file still pastes as a file in Finder/IDEs while a text field pastes its path.

#### Scenario: Firing pastes into the prior front app
- **WHEN** an entry is armed and the fingers lift
- **THEN** the entry's representations are placed on the pasteboard and pasted into the app that was frontmost when the launcher opened

#### Scenario: Chosen entry becomes the clipboard
- **WHEN** an entry is fired
- **THEN** the general pasteboard holds that entry's content afterward

#### Scenario: File pastes as a file or as its path
- **WHEN** a copied file or folder entry is fired
- **THEN** the pasteboard carries both the file-url (so Finder/IDEs paste the file) and the POSIX path as plain text (so a text field pastes the path)

#### Scenario: Image is offered in multiple formats
- **WHEN** an image entry is fired
- **THEN** the pasteboard carries both PNG and TIFF so apps accepting either format paste the image

#### Scenario: Stale file reference fails gracefully
- **WHEN** a fired file entry references a file that no longer exists
- **THEN** the paste does nothing harmful and the app does not crash

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

