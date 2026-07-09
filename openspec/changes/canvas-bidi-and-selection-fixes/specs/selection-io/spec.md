## MODIFIED Requirements

### Requirement: Clipboard fallback with restore
When Accessibility does not expose the selection, the system SHALL fall back to synthesizing ⌘C against the captured front app, reading the resulting pasteboard text, and then **restoring the previous pasteboard contents** so the user's clipboard is left as it was. Before synthesizing the ⌘C, the system SHALL **re-assert the captured app as frontmost** (activate it and let activation settle), because a ⌘C posted to an app that is not the active app is not processed (e.g. Terminal) — mirroring the write-back paste path, which already activates before synthesizing ⌘V. When **Secure Keyboard Entry** is enabled (Terminal's Secure Keyboard Entry, or any app that enabled it), synthesized keystrokes are blocked system-wide; the fallback SHALL then yield no text (the caller surfaces "no input" / the existing clipboard fall-through) rather than appearing to succeed, and this condition SHALL be recorded in the diagnostic log so it is distinguishable from a genuinely empty selection.

#### Scenario: Fallback reads via copy and restores the clipboard
- **WHEN** the AX selection read fails but text is selected, and the fallback is used
- **THEN** the captured app is re-asserted as frontmost, a synthesized ⌘C captures the selection, and the prior clipboard contents are restored afterward

#### Scenario: Fallback does not clobber a password on the clipboard
- **WHEN** the clipboard held sensitive content before the fallback ran
- **THEN** that content is restored unchanged after the fallback read

#### Scenario: Secure Keyboard Entry blocks the synthesized copy
- **WHEN** Secure Keyboard Entry is enabled and an AX-opaque app's selection is read via the ⌘C fallback
- **THEN** the copy does not land, the system yields no text (surfaced as no input rather than a false success), and the blocked-by-secure-input condition is logged
