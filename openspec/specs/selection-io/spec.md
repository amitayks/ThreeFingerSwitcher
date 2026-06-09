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
The system SHALL allow capturing a region of the screen as an image for vision commands, reusing the Screen Recording permission the app already holds. The captured image SHALL be supplied to the runtime as the command's input.

#### Scenario: Region capture feeds the vision model
- **WHEN** a screen-region command is fired and the user designates a region
- **THEN** that region is captured as an image and passed to the runtime as input

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
