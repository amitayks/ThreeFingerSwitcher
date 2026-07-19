# Delta: switcher-overlay (window-groups)

## MODIFIED Requirements

### Requirement: Window grid of real-proportion cards

The overlay SHALL render the current Space's windows as a wrapped grid of cards, one card per window in snapshot order, filling each visual row left-to-right and stacking the rows bottom-to-top — so the first window (in snapshot order) occupies the BOTTOM visual row and later windows wrap UPWARD. (A single row is unaffected: its first window is leftmost.) Each card SHALL render at its window's true proportion (from the window's real Accessibility frame), not a fixed shape, so a portrait window is a tall-narrow card and a landscape window a wide card. Each card SHALL show the window's thumbnail (or the app-icon placeholder when no thumbnail is available). Within a visual row, cards of differing height SHALL be vertically centered to the row's band height (the tallest card in that row).

Windows belonging to one **group** (the window-groups capability) SHALL render as a **fused cluster**: one flow-wrap unit whose member cards are placed at their windows' real relative arrangement — each member at the shared uniform scale times its real frame, offset within the cluster by the scaled offset of its real frame within the group's union rectangle — so snapped windows visibly sit snapped in the grid. The cluster takes the flow position of its earliest member (in snapshot order); its members are consecutive items of the visual row, ordered by their real position (left-to-right, then top-to-bottom). Member cards SHALL keep individual thumbnails, individual highlight, and individual selection — the cluster is a layout unit, not a selection unit. Cluster members SHALL be exempt from the per-card minimum-size floor (flooring one member would break the mirrored adjacency); when no groups exist the layout SHALL be identical to the ungrouped layout.

#### Scenario: One card per window in order

- **WHEN** the overlay is shown for a Space of N windows
- **THEN** N cards are rendered in snapshot order, each row filled left-to-right with rows stacked bottom-to-top (the first window in the bottom row, later windows wrapping upward)

#### Scenario: First window sits in the bottom row

- **WHEN** the overlay is shown for a Space whose windows wrap into two or more visual rows
- **THEN** the first window (in snapshot order) is in the bottom visual row
- **AND** entering the Space highlights that first window at the bottom-left, with a swipe-up moving toward the top row

#### Scenario: Cards keep their window's proportion

- **WHEN** a card is rendered for a window
- **THEN** the card's width-to-height ratio matches the window's real frame ratio (portrait windows are narrow, landscape windows are wide), rather than a fixed card shape

#### Scenario: Thumbnail or icon placeholder

- **WHEN** a card is rendered
- **THEN** it shows the window's thumbnail image, or the owning app icon as a placeholder when no thumbnail is available

#### Scenario: Mixed-height rows are centered

- **WHEN** a visual row contains cards of differing heights
- **THEN** each card is vertically centered within the row's band (height of the tallest card in that row)

#### Scenario: Grouped windows render fused, mirroring the real arrangement

- **WHEN** two windows are grouped (snapped side by side on screen) and their Space is shown
- **THEN** their cards render adjacent as one cluster whose internal arrangement matches the real windows' relative positions at the shared uniform scale (side-by-side windows are side-by-side cards, a stacked pair is stacked), visually distinct from the normal inter-card spacing

#### Scenario: Individual highlight within a cluster

- **WHEN** the selection moves onto a grouped window
- **THEN** only that member card shows the selection highlight, and horizontal scrubbing steps between the cluster's members like any neighboring cards

#### Scenario: No groups means the layout is unchanged

- **WHEN** no window groups exist
- **THEN** the wrapped grid is identical to the layout before this capability existed
