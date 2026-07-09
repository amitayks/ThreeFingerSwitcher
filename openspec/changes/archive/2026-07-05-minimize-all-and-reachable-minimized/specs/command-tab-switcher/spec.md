## MODIFIED Requirements

### Requirement: Releasing ⌘ commits the selection with a cross-Space raise
Releasing ⌘ while the overlay is open SHALL commit: it raises the highlighted window and, when that window is on a different Space than the active one, switches to that Space — reusing the existing cross-Space raise. When the highlighted window is **minimized** (present in the reel because the include-minimized-windows setting is on), the commit SHALL **un-minimize it in place and then raise it**, reusing the existing un-minimize-then-raise path so the window returns to its prior position with keyboard focus. On commit the overlay SHALL hide promptly.

#### Scenario: ⌘ release raises the highlighted window
- **WHEN** the overlay is open on a highlighted window and the user releases ⌘
- **THEN** the highlighted window is raised and focused, and the overlay hides

#### Scenario: Commit switches to the window's Space when off-Space
- **WHEN** the committed window is on a different Space than the active one
- **THEN** the system switches to that window's Space and raises it, exactly as raising any off-Space window does

#### Scenario: ⌘ release un-minimizes and raises a minimized selection
- **WHEN** the overlay is open on a highlighted minimized window and the user releases ⌘
- **THEN** the window is un-minimized in place and then raised to the front with focus, and the overlay hides
