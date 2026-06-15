# dock-preview-overlay Specification

## Purpose
TBD - created by archiving change dock-window-previews. Update Purpose after archive.
## Requirements
### Requirement: Mouse-interactive, non-activating preview popup
The preview popup SHALL be a non-activating overlay panel that — unlike every other overlay in the app — **accepts mouse hover and click** on its thumbnails. It SHALL NOT become the app's key/main focus target, SHALL NOT steal focus from the previously focused window (so commit raises the chosen window cleanly), and SHALL tear down **synchronously** on dismiss. The popup SHALL be positioned so it does not overlap the Dock icon itself, so a native click on the Dock icon still reaches the system.

#### Scenario: Popup receives the pointer
- **WHEN** the popup is open and the cursor moves over a thumbnail
- **THEN** the thumbnail responds to the hover (it is not pass-through)

#### Scenario: Popup does not steal focus
- **WHEN** the popup is shown
- **THEN** the previously focused application remains the focus/raise target and the popup never becomes the app's key window

#### Scenario: Native Dock click still works
- **WHEN** the cursor clicks the Dock icon itself rather than a thumbnail
- **THEN** the click reaches the system Dock unmodified

#### Scenario: Synchronous teardown
- **WHEN** the popup dismisses
- **THEN** the panel is ordered out synchronously (no deferred teardown that could ghost on a Space switch)

### Requirement: Row of the app's current-Space windows, including minimized
The popup SHALL render a row of thumbnails for the hovered app's windows on the **current Space only**, including **minimized** windows, one card per window. Minimized windows SHALL be visually distinguished. The row SHALL use a stable per-window identity across re-lists so it does not strobe.

#### Scenario: One card per current-Space window
- **WHEN** the popup opens for an app with N windows on the current Space
- **THEN** N cards are rendered, one per window

#### Scenario: Minimized windows are included and marked
- **WHEN** the app has minimized windows on the current Space
- **THEN** those windows appear in the row and are visually distinguished as minimized

#### Scenario: Other-Space windows are excluded
- **WHEN** the app has windows on Spaces other than the current one
- **THEN** those windows do not appear in the row

#### Scenario: Stable identity across re-lists
- **WHEN** the row is rebuilt while open
- **THEN** cards keep a stable per-window identity so the row does not strobe

### Requirement: Apps with no current-Space windows show nothing
The popup SHALL NOT appear for an app that has no windows on the current Space. No empty popup SHALL be shown.

#### Scenario: No popup for an app with no current-Space windows
- **WHEN** the cursor hovers the tile of a running app that has zero windows on the current Space
- **THEN** no popup appears

### Requirement: Hover peek fronts the real window and restores it on leave
The peek SHALL show the hovered window's **true, live content at its real on-screen position and size** by bringing the **real window to the front** (macOS does not render fresh pixels for a window that is not on screen, so an in-popup projection of an occluded window cannot be live — fronting the real window is the only way to a true live preview). Before the first peek of a session the system SHALL record the previously-frontmost window, and when the cursor leaves the popup **without committing** it SHALL restore that window to the front, so a hover-and-leave leaves the desktop exactly as it was. Moving to a different card SHALL front that window instead. A **minimized** window SHALL NOT be fronted for a peek (that would require de-minimizing it); it surfaces only on commit. The peek front-raise SHALL be lightweight and reversible — without the commit path's focus-history promotion or post-commit watchdog.

#### Scenario: Hovering a card fronts the real window live
- **WHEN** the cursor hovers a card for a non-minimized window
- **THEN** that real window is brought to the front and shows its live, updating content at its actual position and size

#### Scenario: Leaving without committing restores the prior window
- **WHEN** the cursor leaves the popup after peeking but without clicking a card
- **THEN** the window that was frontmost before the peek began is brought back to the front

#### Scenario: Moving between cards re-fronts
- **WHEN** the cursor moves from one card to another
- **THEN** the newly hovered window is fronted (the previously peeked window falls behind)

#### Scenario: Minimized windows are not fronted to peek
- **WHEN** the cursor hovers a card for a minimized window
- **THEN** the window is not de-minimized or fronted for the peek (it surfaces only on commit)

### Requirement: Tab thumbnails use cache-first last-good-frame safety
Each tab SHALL show a thumbnail using the same cache-first safety as the switcher: a degraded or occluded capture SHALL be discarded so the last good frame is preserved (a tab SHALL never show a sideways/strip proxy), falling back to the app icon until a good frame is available. On open the popup SHALL seed each tab from the last-good cached frame so it does not re-open on bare icons. Once a window has been peeked (fronted) it captures cleanly, and that frame SHALL persist as the tab's last-good frame.

#### Scenario: Degraded capture does not overwrite a good frame
- **WHEN** a window's capture would be degraded (occluded / set-aside / strip proxy)
- **THEN** the tab keeps its last good thumbnail (or the app icon) rather than showing a degraded image

#### Scenario: Popup re-opens on last-good frames, not icons
- **WHEN** the popup re-opens for an app whose windows were captured before
- **THEN** each tab shows its last-good cached frame immediately rather than the app icon

#### Scenario: Peeking yields a clean tab frame
- **WHEN** a window has been fronted by a peek
- **THEN** a clean thumbnail is captured and retained as that tab's last-good frame

### Requirement: A peek-captured frame refreshes the switcher too
A good frame captured while a peek has fronted a window SHALL refresh the switcher's thumbnail for that window as well, so both the Dock-preview tab and the switcher show the same fresh image. The two surfaces SHALL share captured frames in both directions (each may seed a tab/card from the other's cache).

#### Scenario: Peek frame updates the switcher
- **WHEN** hovering a tab fronts a window and a good frame is captured
- **THEN** the switcher's thumbnail for that window is refreshed with the same frame

#### Scenario: Tabs benefit from switcher captures
- **WHEN** the switcher has already captured a window's thumbnail
- **THEN** that window's Dock-preview tab can show that frame immediately on open

### Requirement: Click commits the chosen window permanently
Clicking a card SHALL bring that window forward permanently using the existing raise path. If the chosen window is **minimized**, it SHALL be un-minimized first and then raised. A failed commit SHALL surface as a bounded, non-blocking card (clean headline + opt-in copyable details), never an `NSAlert` and never raw error text in the headline.

#### Scenario: Click raises a normal window
- **WHEN** the user clicks a card for a non-minimized window
- **THEN** that window is raised and its application activated, becoming frontmost with keyboard focus

#### Scenario: Click un-minimizes then raises
- **WHEN** the user clicks a card for a minimized window
- **THEN** the window is un-minimized and then raised to the front

#### Scenario: Commit failure is bounded and non-blocking
- **WHEN** a commit fails
- **THEN** a bounded, non-blocking error card is shown (clean headline, opt-in details) and no app-modal alert appears

