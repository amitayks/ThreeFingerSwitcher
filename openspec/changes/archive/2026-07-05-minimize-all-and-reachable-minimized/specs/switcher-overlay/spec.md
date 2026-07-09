## ADDED Requirements

### Requirement: Minimized windows are badged and not live-peeked
When the include-minimized-windows setting is on and the switcher lists a minimized window, its card SHALL display a minimized affordance — a badge and/or dim, consistent with the Dock-preview treatment — so the user can distinguish it from a live window. The periodic live-preview refresh SHALL NOT attempt to capture or front-peek a minimized window (macOS renders no fresh pixels for a minimized window, so a capture would be wasted or degraded); a minimized card SHALL instead show its last-good cached frame or, absent one, the app icon. Live (non-minimized) cards SHALL be unaffected — they capture and refresh exactly as before. Selecting a minimized card SHALL restore the window in place, per the un-minimize-then-raise commit requirement.

#### Scenario: Minimized card shows a minimized affordance
- **WHEN** the switcher lists a minimized window (include-minimized-windows on)
- **THEN** its card shows a minimized badge and/or dim and its last-good frame or the app icon, distinguishable from live cards

#### Scenario: Minimized cards are not peeked or captured
- **WHEN** the periodic preview refresh runs while a minimized card is visible
- **THEN** the minimized window is not fronted or captured and its card keeps its cached/icon frame

#### Scenario: Live cards are unaffected
- **WHEN** the visible row contains both live and minimized windows
- **THEN** the live windows are captured and refreshed on the normal cadence while the minimized windows are skipped

#### Scenario: Selecting a minimized card restores the window
- **WHEN** the user commits a minimized card
- **THEN** the window is un-minimized in place and raised to the front with focus
