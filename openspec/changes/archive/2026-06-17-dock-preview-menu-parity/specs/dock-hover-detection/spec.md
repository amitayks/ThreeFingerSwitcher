## ADDED Requirements

### Requirement: Right-click on a Dock tile yields to the native menu

A **right-click on a Dock app tile** SHALL dismiss the preview (if shown) so the system's native Dock action menu is unobstructed, AND SHALL suppress re-showing the preview for that tile while the menu is up. The right-click SHALL be observed **passively** (a global monitor that never consumes the event), so the native Dock menu opens unmodified and reaches the system Dock exactly as it would with the feature off. Dismissal SHALL follow the normal teardown — any window fronted by an in-flight peek SHALL be restored to its prior frontmost window. While the preview is shown the panel SHALL NOT re-order itself to the front on the per-frame hover tick, so a menu that opens above it stays above it. After the menu opens, the system SHALL NOT re-show the preview for that tile while the cursor remains over it (so a stray cursor move does not pop the preview back up behind the menu); normal hover behavior SHALL resume once the cursor leaves the tile.

#### Scenario: Right-click on a tile dismisses the preview
- **WHEN** the preview popup is open and the user right-clicks the Dock app tile
- **THEN** the preview dismisses and the system's native Dock action menu is shown unobstructed in front

#### Scenario: The native right-click is never consumed
- **WHEN** the user right-clicks a Dock tile
- **THEN** the native Dock action menu opens unmodified (the app observes the click passively and does not intercept or alter it)

#### Scenario: A peeked window is restored on right-click dismiss
- **WHEN** a peek has fronted a window and the user then right-clicks the tile (rather than clicking a card)
- **THEN** the preview dismisses and the window that was frontmost before the peek is restored to the front

#### Scenario: Right-click away from any app tile does not trigger this dismiss
- **WHEN** the user right-clicks somewhere that is not a Dock app tile
- **THEN** the preview is not dismissed by the right-click rule (normal live-zone / grace behavior applies)

#### Scenario: The preview does not re-front itself over the menu
- **WHEN** the native Dock menu is open above the preview before the preview has dismissed
- **THEN** the preview does not re-order itself to the front on the hover tick (the menu remains in front)

#### Scenario: The preview does not re-appear while the cursor lingers on the right-clicked tile
- **WHEN** the native menu is open and the cursor moves while still over the tile that was right-clicked
- **THEN** the preview stays closed (it does not re-open behind the menu) until the cursor leaves that tile, after which normal hover behavior resumes
