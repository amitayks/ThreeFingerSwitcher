## MODIFIED Requirements

### Requirement: De-duplication and retention caps

The system SHALL de-duplicate entries: copying content identical to an existing entry SHALL update that entry's recency rather than create a duplicate. The recorder SHALL NOT record the app's own pasteboard writes (a launcher paste), so a paste never re-ingests its entry, changes its source application, or duplicates an image whose stored representations differ from the pasted ones. The system SHALL bound storage by configurable caps on entry **count**, total **bytes**, and **age**, evicting the oldest non-pinned entries first when a cap is exceeded; the byte cap SHALL count every entry's payload size whether it is held inline or as a blob file (including entries loaded from disk after a relaunch). Pinned entries SHALL be exempt from count/age eviction. Payloads above a threshold SHALL NOT stay resident in memory once persisted; they are read back on demand.

#### Scenario: Re-copying does not duplicate
- **WHEN** the user copies a value that already exists in history
- **THEN** no second entry is created and the existing entry becomes the most recent

#### Scenario: Pasting from the band is not re-recorded
- **WHEN** the user pastes an entry from the Clipboard band into another application
- **THEN** the recorder does not create or modify an entry for that pasteboard change

#### Scenario: Oldest entries evict past the cap
- **WHEN** recording a new entry would exceed a retention cap
- **THEN** the oldest non-pinned entries are evicted until the store is within the cap

#### Scenario: Byte cap applies after relaunch
- **WHEN** the app relaunches with blob-backed entries whose total size exceeds the byte cap and a new entry is recorded
- **THEN** the oldest non-pinned entries are evicted so the total, counting blob files, is within the cap

#### Scenario: Pinned entries survive eviction
- **WHEN** a retention cap is exceeded and old entries are evicted
- **THEN** pinned entries are retained regardless of age or count

### Requirement: Versioned on-disk storage separate from favorites

The system SHALL persist clipboard history on disk under the app's Application Support directory, **separate** from the Favorites record (which remains a small UserDefaults blob). The store SHALL keep small payloads (text, references, colors) in an index and large payloads (image bytes, cached thumbnails) as blob files. Persistence MAY be asynchronous, but the system SHALL drain pending writes before the process terminates and before the history directory is deleted. The store SHALL carry a schema version that allows forward migration, and clipboard entries SHALL NEVER be written into the Favorites/launch-items record.

#### Scenario: History persists across relaunch
- **WHEN** the user records history, quits, and relaunches the app
- **THEN** the stored entries (and pins) are restored from disk

#### Scenario: The last change before quitting is durable
- **WHEN** the user copies or pins an entry and immediately quits the app
- **THEN** that change is present after relaunch

#### Scenario: Favorites record stays clipboard-free
- **WHEN** clipboard history is recorded
- **THEN** the Favorites record is unchanged and contains no clipboard entries
