# ai-error-handling Specification

## Purpose

Define how the AI feature handles, translates, and surfaces errors so that failures are clean, non-blocking, observable, recoverable, and never silent. Every error the AI feature originates is classified into one shared taxonomy and translated to a concise headline (with opt-in details) by a single central translator; raw vendor/OS errors are mapped at the runtime boundary and never reach the UI; failures become observable states that never stall, are surfaced through non-blocking, bounded surfaces, always offer a way forward, and are reported rather than masked as success.

## Requirements

### Requirement: Single error taxonomy and translator
The AI feature SHALL classify every error it originates (provision/download, model load, generation,
structured/task output, selection I/O, and side-effecting tasks) into one shared, bounded taxonomy and
translate it to a user message via a single central translator. The translator SHALL return a concise
human-readable **headline** and an optional, separately-carried **details** payload. The headline SHALL be
derived in priority order: the app's own `LocalizedError` description when the error is an app error;
otherwise a classifier for vendor/OS errors; otherwise a generic fallback ("Something went wrong."). The
same error SHALL produce the same headline regardless of which surface displays it.

#### Scenario: One error, identical message on every surface
- **WHEN** the same underlying error is shown in the Settings model-status row, in any alert, and in the overlay canvas
- **THEN** all three display the identical concise headline produced by the central translator

#### Scenario: Unknown error falls back safely
- **WHEN** an error of a type the translator does not recognize is encountered
- **THEN** the headline is a generic safe sentence and the raw error is attached only as opt-in details, never as the headline

### Requirement: No raw error text in user-facing strings
A user-facing string (any status text, alert body, or canvas caption) SHALL NOT contain raw error text —
i.e. the result of interpolating an `Error` (`"\(error)"`), `String(describing:)` of an error, or the
`.localizedDescription` of an operating-system error directly into the headline. Raw error text MAY appear
only in logs and in the opt-in **details** payload. The app's own error types that are user-facing SHALL
conform to `LocalizedError` with a clean `errorDescription` for every case.

#### Scenario: Offline provision shows a clean message, not an NSError dump
- **WHEN** the model download is attempted with no internet connection
- **THEN** the Settings status row shows a short connectivity message and never the `Error Domain=…Code=…UserInfo={…}` dump

#### Scenario: A runtime error is self-describing
- **WHEN** any code reads a runtime error's localized description
- **THEN** it yields the clean per-case message (the runtime error type conforms to `LocalizedError`), not a reflected enum dump or the generic default

### Requirement: Errors are mapped at the runtime boundary
Raw vendor and operating-system errors SHALL be converted into the shared taxonomy at the seam where they
cross into application code, and SHALL NOT be propagated raw to a view model or the UI. This applies to the
model-download library's errors, `NSURLError`, EventKit, `FileManager`/`FileHandle`, and `Process`.
Diagnostic logging of the original error at the boundary is permitted and encouraged.

#### Scenario: Download-library error is converted before it leaves the runtime
- **WHEN** the model runtime's prepare step fails with a vendor download-library error
- **THEN** it is converted to the corresponding taxonomy case (e.g. offline, server-unavailable, access-denied, model-load-failed) before it is thrown out of the runtime, and the original error is only logged

### Requirement: Failure is an observable state that never stalls
A failed AI operation SHALL transition its owning state machine to a failed state carrying the clean headline,
rather than leaving the caller to surface a thrown error. No AI operation SHALL be able to leave its state
machine stuck in an in-progress state because of an unhandled (non-cancellation) error. Cancellation SHALL
continue to be treated as not-a-failure and SHALL NOT be surfaced as an error.

#### Scenario: A non-cancellation download error resolves the state
- **WHEN** a download fails for any reason other than user cancellation
- **THEN** the model lifecycle state becomes failed with a clean message (it does not remain in "downloading")

#### Scenario: Cancellation is silent
- **WHEN** the user cancels a download or discards a generation
- **THEN** no error is surfaced and the state returns to its prior resting state, not a failed state

### Requirement: Error surfaces are non-blocking and bounded
AI error surfaces SHALL keep their host window interactive and SHALL bound the rendered message. A
Settings-scoped failure SHALL NOT be surfaced by an application-modal alert that suspends the window's event
loop; it SHALL use the in-window failed state (or a window-modal/non-modal presentation). User-facing error
text SHALL be length-capped (truncating) with full text available via an opt-in details disclosure and a copy
action, and the containing layout SHALL degrade to scrolling rather than overflowing a fixed frame.

#### Scenario: Settings stays interactive on failure
- **WHEN** a model preparation fails while the Settings window is open
- **THEN** the window remains scrollable and clickable (no application-modal alert blocks it) and shows the failed state inline

#### Scenario: A long error never breaks the layout
- **WHEN** the failure carries an unusually long message or details
- **THEN** the status row shows a capped, truncated headline and the content scrolls; it does not overflow or freeze the window

#### Scenario: Details are available on demand
- **WHEN** the user wants the full technical error
- **THEN** a "Show details"/"Copy" affordance exposes the raw details without showing them inline by default

### Requirement: A failed state offers recovery
A surfaced AI failure SHALL be paired with a way forward — a retry, a dismiss, or a pointer to the relevant
system setting — so a failure is never a dead end.

#### Scenario: A failed download offers retry
- **WHEN** the model download is in a failed state in Settings
- **THEN** a Retry action is available that re-attempts the download

#### Scenario: A permission failure points to the fix
- **WHEN** a task fails because a system permission (e.g. Calendar) is denied
- **THEN** the message names the missing permission and points the user to the relevant System Settings pane

### Requirement: Failure is never silent
A side-effecting or selection operation that does not actually accomplish its effect SHALL report a failure,
not a success. Opening a tool, running a destination adapter, writing a project note, replacing the selection,
and pasting SHALL each surface a failed state when the effect did not land, rather than reporting "Done".

#### Scenario: A write that did not land is reported
- **WHEN** replacing the selection (or pasting the result) does not actually apply to the focused app
- **THEN** the command surfaces a failed state with a clean message, not a committed/"Done" state

#### Scenario: A task whose side effect failed is reported
- **WHEN** a task's side effect (file write, tool open, adapter run) throws or returns a non-success status
- **THEN** the task surfaces a clean task-failed message rather than silently completing
