## ADDED Requirements

### Requirement: Left-click on the shown app's Dock tile commits the highlighted preview

A **left-click on the Dock app tile of the currently-shown app**, while a card is highlighted (peeked), SHALL commit that highlighted window using the same raise path as clicking the card — so the chosen window stays front and is NOT undone by the leave-restore. The left-click SHALL be observed **passively** (a global monitor that never consumes the event), so the native Dock still receives the click unmodified. If **no** card is highlighted, the left-click SHALL NOT commit anything — the native Dock activation stands and the preview is left to normal live-zone / grace behavior. A left-click on a **different** app's tile SHALL NOT be treated as a commit (normal hover-swap and native activation apply).

#### Scenario: Icon click commits the highlighted window
- **WHEN** the preview popup is open, a card is highlighted (peeked), and the user left-clicks the shown app's Dock tile
- **THEN** the highlighted window is committed (raised, un-minimized first if minimized) and stays front, exactly as if the card had been clicked — the leave-restore does not put the previous window back

#### Scenario: The native left-click is never consumed
- **WHEN** the user left-clicks the Dock tile
- **THEN** the native Dock receives the click unmodified (the app observes it passively and does not intercept or alter it)

#### Scenario: Icon click with no highlighted card does not commit
- **WHEN** the preview popup is open but no card has been highlighted (the cursor never moved onto a thumbnail) and the user left-clicks the shown app's Dock tile
- **THEN** nothing is committed by this rule; the native Dock activation stands and the preview follows normal live-zone / grace behavior

#### Scenario: Left-click on another app's tile is not a commit
- **WHEN** the preview popup is open for one app and the user left-clicks a different app's Dock tile
- **THEN** the click is not treated as a commit of the shown app's window; the other app activates natively and the popup swaps to it per the normal live-zone behavior
