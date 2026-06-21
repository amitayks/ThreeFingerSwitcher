# selection-io Specification

## Purpose

Define how AI commands read input from and write output into the captured front app using only already-held permissions: reading selected text via Accessibility without touching the clipboard, a clipboard-fallback copy that restores the prior pasteboard, screen-region capture for vision input, writing results back via Accessibility-or-paste, and graceful degradation when input cannot be obtained.
## Requirements
### Requirement: Read the front app's selected text via Accessibility
The system SHALL read the currently selected text of the app that was frontmost when the launcher opened, using Accessibility (`AXSelectedText` on the focused UI element), without modifying the clipboard. This SHALL reuse the Accessibility permission the app already holds and SHALL require no new permission.

#### Scenario: Selected text is read without touching the clipboard
- **WHEN** text is selected in the front app and a selection-input command is fired
- **THEN** the selected text is obtained via Accessibility and the clipboard contents are unchanged

#### Scenario: No selection yields no AX text
- **WHEN** nothing is selected in the front app
- **THEN** the Accessibility read returns no text (and the caller may fall back)

### Requirement: Clipboard fallback with restore
When Accessibility does not expose the selection, the system SHALL fall back to synthesizing ⌘C against the captured front app, reading the resulting pasteboard text, and then **restoring the previous pasteboard contents** so the user's clipboard is left as it was.

#### Scenario: Fallback reads via copy and restores the clipboard
- **WHEN** the AX selection read fails but text is selected, and the fallback is used
- **THEN** the text is obtained via a synthesized copy and the prior clipboard contents are restored afterward

#### Scenario: Fallback does not clobber a password on the clipboard
- **WHEN** the clipboard held sensitive content before the fallback ran
- **THEN** that content is restored unchanged after the fallback read

### Requirement: Screen-region capture for vision input
The system SHALL capture a **user-designated region** of the screen as an image for vision commands, using the interactive region picker, reusing the Screen Recording permission the app already holds. The captured image SHALL be the **designated rectangle only** (not the full display) and SHALL be supplied to the runtime as the command's input. A **cancelled** pick (a click without a drag) SHALL yield **no image**, so the command aborts rather than running on a blank or full-screen capture. The capture SHALL exclude the app's own overlay windows.

#### Scenario: Designated region capture feeds the vision model
- **WHEN** a screen-region command is fired and the user drags out a region
- **THEN** that region (only) is captured as an image and passed to the runtime as input

#### Scenario: Cancelled pick yields no image
- **WHEN** the user cancels the region pick (a click without a drag)
- **THEN** no image is produced and the command does not run on a fallback capture

#### Scenario: Region capture reuses the held permission
- **WHEN** a region is captured
- **THEN** the already-held Screen Recording permission is used and no new permission is requested

### Requirement: Write output back into the front app
The system SHALL deliver a command's committed result into the app that was frontmost when the launcher opened: for `replaceSelection`, by setting the selection's text via Accessibility when the element is settable, otherwise by pasting; for `pasteAtCursor`, by pasting at the insertion point. The paste path SHALL reuse the existing paste-on-fire mechanism (restore representations + synthesized ⌘V into the captured app).

#### Scenario: Replace via Accessibility when settable
- **WHEN** the focused element exposes a settable selected-text attribute and a `replaceSelection` result is committed
- **THEN** the selection is replaced via Accessibility without a paste

#### Scenario: Fall back to paste when not settable
- **WHEN** the element is not settable and a `replaceSelection` result is committed
- **THEN** the result is delivered by pasting into the captured front app

### Requirement: Reuse held permissions and degrade gracefully
Selection I/O SHALL rely only on permissions the app already holds (Accessibility for read/replace, Screen Recording for region capture) and SHALL behave safely when input cannot be obtained: if neither Accessibility nor the clipboard fallback yields text for an input-requiring command, the system SHALL report a clear "no input" state and SHALL NOT run the model on empty input.

#### Scenario: No new permission prompt for selection I/O
- **WHEN** a selection-input command runs
- **THEN** no new permission is requested (the held Accessibility permission is used)

#### Scenario: Unobtainable input is reported, not guessed
- **WHEN** input cannot be obtained by any path for an input-requiring command
- **THEN** the system surfaces a "no input" state rather than invoking the model

### Requirement: Read the current clipboard image as vision input
The system SHALL read the current clipboard **image** — from the **live system pasteboard** (preferring `public.png`, falling back to `public.tiff`), normalized to **PNG** bytes — and supply it to the runtime as a vision command's image input. This SHALL be symmetric with the existing live clipboard-**text** read: it reads the live pasteboard, **not** the stored clipboard history, and SHALL reuse already-held access (reading the pasteboard requires no new permission). When the pasteboard holds no image, or its image data cannot be decoded/normalized to PNG, the read SHALL yield **no image** so the caller surfaces a "no input" state rather than invoking the model on empty input.

#### Scenario: Clipboard image is read as PNG for the vision model
- **WHEN** an image is on the clipboard and a `clipboardImage` command is fired
- **THEN** the image is read as PNG bytes and passed to the runtime as the command's image input

#### Scenario: TIFF-only clipboard image is normalized to PNG
- **WHEN** the pasteboard holds only a `public.tiff` image and a `clipboardImage` command is fired
- **THEN** the image is normalized to PNG bytes before being supplied to the runtime

#### Scenario: No clipboard image yields no input
- **WHEN** a `clipboardImage` command is fired and the clipboard holds no image (or undecodable image data)
- **THEN** no image is produced and the caller surfaces a "no input" state (the model is not invoked)

#### Scenario: No new permission for the clipboard-image read
- **WHEN** a `clipboardImage` command runs
- **THEN** no new permission is requested (reading the pasteboard uses already-held access)

