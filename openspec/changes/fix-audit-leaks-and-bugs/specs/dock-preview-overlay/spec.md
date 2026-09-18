## MODIFIED Requirements

### Requirement: Hover peek fronts the real window and restores it on leave
The peek SHALL show the hovered window's **true, live content at its real on-screen position and size** by bringing the **real window to the front**. Before the first peek of a session the system SHALL record the previously-frontmost window, and when the cursor leaves the popup **without committing** it SHALL restore that window to the front **only if the peeked window is still frontmost** — if the user has meanwhile activated some other window (a click on the desktop, ⌘-Tab, a Dock click), that choice stands and nothing is re-fronted. Re-hovering the already-peeked card SHALL NOT re-front it or restart its capture (hover flicker is idempotent). Moving to a different card SHALL front that window instead. A **minimized** window SHALL NOT be fronted for a peek; it surfaces only on commit. The peek front-raise SHALL be lightweight and reversible — without the commit path's focus-history promotion or post-commit watchdog — and SHALL release any pending post-commit guard from an earlier commit.

#### Scenario: Hovering a card fronts the real window live
- **WHEN** the cursor hovers a card for a non-minimized window
- **THEN** that real window is brought to the front and shows its live, updating content at its actual position and size

#### Scenario: Leaving without committing restores the prior window
- **WHEN** the cursor leaves the popup after peeking, without clicking, and the peeked window is still frontmost
- **THEN** the window that was frontmost before the peek began is brought back to the front

#### Scenario: Leaving after the user activated something else does not restore
- **WHEN** the user clicks or ⌘-Tabs to a third window while the popup is open and then the popup dismisses
- **THEN** the third window stays frontmost; the pre-peek window is not re-fronted

#### Scenario: Hover flicker does not re-peek
- **WHEN** the hover state of the already-peeked card toggles during its scale-up animation
- **THEN** no additional front-raise or capture restart happens

#### Scenario: Minimized windows are not fronted to peek
- **WHEN** the cursor hovers a card for a minimized window
- **THEN** the window is not de-minimized or fronted for the peek (it surfaces only on commit)
