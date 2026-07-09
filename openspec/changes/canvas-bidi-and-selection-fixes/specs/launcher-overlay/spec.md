## MODIFIED Requirements

### Requirement: Bidirectional (RTL/LTR) text rendering in the preview canvas
The preview canvas SHALL render text **bidirectionally**: each paragraph's **base direction is decided by its FIRST strong directional character** (the first word/char of the line) — leading neutrals (whitespace, digits, punctuation, a bullet, a URL) are skipped to that first strong character. Once the first strong character is present the paragraph's side SHALL be **stable**: characters that arrive later in the line SHALL NOT re-decide its direction (a line that starts in a left-to-right script stays left-aligned even as right-to-left content follows, and vice versa). A paragraph that has streamed only neutrals so far SHALL default to left-to-right until its first strong character arrives, then adopt that character's side. RTL detection SHALL cover **all RTL scripts** (the `U+0590–U+08FF` block — Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, Arabic Extended — plus the Hebrew/Arabic presentation-form blocks), not only Hebrew and Arabic. **Mixed** left-to-right and right-to-left runs within a paragraph SHALL resolve via the Unicode Bidi algorithm so combined text reads cleanly (e.g. a Latin word or URL inside a Hebrew sentence). This SHALL apply to the **streamed output**, the **input echo**, and the **task-review fields**.

#### Scenario: A right-to-left result starts from the correct side
- **WHEN** the streamed result is Hebrew text
- **THEN** it renders right-aligned with a right-to-left base direction and correct punctuation placement

#### Scenario: The first word decides the line and the side is stable
- **WHEN** a line begins with a strong character of one direction and later contains runs of the other direction
- **THEN** the line's base direction follows the first strong character and does NOT change as the later runs stream in (the embedded runs are still placed correctly by the Bidi algorithm)

#### Scenario: Leading neutrals are skipped to the first strong character
- **WHEN** a paragraph begins with whitespace, a number, or a bullet marker before its first letter
- **THEN** the base direction is decided by the first strong letter, not the leading neutrals

#### Scenario: A neutral-only line adopts its side once the first strong char arrives
- **WHEN** a paragraph has streamed only neutral characters so far
- **THEN** it renders left-to-right until its first strong directional character streams in, then locks to that character's side

#### Scenario: Non-Hebrew/Arabic RTL scripts resolve right-to-left
- **WHEN** a line's first strong character is in another RTL script (e.g. Syriac, Thaana, or N'Ko)
- **THEN** it renders right-aligned with a right-to-left base direction

#### Scenario: Left-to-right text is unaffected
- **WHEN** the streamed result is English text
- **THEN** it renders left-aligned with a left-to-right base direction

## ADDED Requirements

### Requirement: The canvas reads the fired command's input before taking key focus
When an AI command is fired, the preview canvas panel SHALL remain **pass-through (non-key)** until the executor has **read the command's input**, and SHALL become key-interactive only afterward. This ordering exists because the panel is a non-activating panel: taking key focus removes the system key window from the app that was frontmost when the launcher opened, which empties that app's Accessibility focused element and prevents the clipboard-copy fallback from landing — so a selection read taken while the panel is key returns nothing and the input wrongly falls through to the clipboard. The executor SHALL signal readiness after acquisition (and immediately for the availability/`unavailable` state, whose enable/download controls need the mouse); the controller SHALL make the canvas interactive on that signal, guarded on the canvas still being open. While the panel is pass-through, the two-finger resolve gestures (which ride the multitouch device, not window events) SHALL keep working.

#### Scenario: A selection is read before the panel takes key focus
- **WHEN** an AI command is fired with text selected in the front app
- **THEN** the selection is read while the front app still holds key focus (the canvas panel has not yet taken key), so the selected text — not the clipboard — is used as the input

#### Scenario: The canvas becomes interactive after the input is read
- **WHEN** the executor finishes acquiring the fired command's input
- **THEN** the canvas panel becomes key-interactive so its controls (language pill, scroll, and the unavailable enable/download controls) respond

#### Scenario: A language re-run reuses the acquired input
- **WHEN** the user changes the runtime language of an in-flight command after the canvas has become interactive
- **THEN** the re-run reuses the input acquired by the first fire rather than re-reading the selection (which would fail now that the panel holds key focus), and re-runs against the same source
