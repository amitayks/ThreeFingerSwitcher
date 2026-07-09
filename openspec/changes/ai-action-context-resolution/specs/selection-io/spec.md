## MODIFIED Requirements

### Requirement: Write output back into the front app
The system SHALL deliver a command's committed result into the app that was frontmost when the launcher opened, choosing the write path from the command's **resolved input channel** rather than a single stored output enum: when the resolved input was a **selection** (and the command enables replacing it), by setting the selection's text via Accessibility when the element is settable, otherwise by pasting; when the resolved input was the **clipboard** (or no selection was used), by pasting the result at the insertion point. The paste path SHALL reuse the existing paste-on-fire mechanism (restore representations + synthesized ⌘V into the captured app).

#### Scenario: Replace via Accessibility when the input was a settable selection
- **WHEN** the resolved input was the selection, the focused element exposes a settable selected-text attribute, and the result is committed to a replace
- **THEN** the selection is replaced via Accessibility without a paste

#### Scenario: Fall back to paste when not settable
- **WHEN** the resolved input was the selection but the element is not settable and the result is committed to a replace
- **THEN** the result is delivered by pasting into the captured front app

#### Scenario: Clipboard input writes by pasting at the cursor
- **WHEN** the resolved input was the clipboard (no selection used) and the result is committed
- **THEN** the result is pasted at the insertion point and the selection is not modified
