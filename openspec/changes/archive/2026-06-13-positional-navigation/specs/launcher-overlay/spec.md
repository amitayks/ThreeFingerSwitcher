## MODIFIED Requirements

### Requirement: Item stepping and context stepping
While the launcher overlay is active, navigation SHALL be a 2D cursor split across the band list (left) and the content grid (right). Steps SHALL be **produced positionally** (see gesture-recognition's *Anchored positional navigation interpretation*): inside the **padding box** the cursor **tracks the finger's position** in discrete steps (moving back steps it back), and once the offset leaves the box — or reaches the **edge-margin band** — it **auto-repeats** along the eased curve, not per fixed distance of accumulated travel. The per-axis cursor topology is:

- With the **band list focused**, **vertical** offset SHALL switch the active band (one band per vertical step — a *deliberate* step), and **horizontal** offset toward the content SHALL cross the focus into the grid, landing on the band's home/first item. Horizontal offset away from the content SHALL clamp (there is nothing to the left of the band list).
- With the **grid focused**, **horizontal** offset SHALL step the selection between items within the current row (one item per horizontal step); from the **first column**, a further step toward the band list SHALL cross the focus back to the band list. **Vertical** offset SHALL step between grid rows and SHALL clamp at the first and last row (it no longer rises to a separate header row — the bands are reached horizontally now).

Stepping past the first/last band or item SHALL clamp (not wrap) unless wrap is configured.

The **Clipboard band** is an exception to the grid's horizontal mapping. Its content is a single-column master-detail list (key list + value preview): horizontal offset toward the content crosses into the **key list**, vertical offset scrubs between entries (rows), and horizontal offset within the key list is repurposed for pin / return-to-band-list (see the Clipboard band navigation requirement) rather than stepping items.

#### Scenario: Vertical switches bands on the band list
- **WHEN** the band list is focused and the vertical offset crosses the outer threshold (or auto-repeats while held)
- **THEN** the active band changes to the adjacent band (and again per further step), the content pane updates to that band, and the active band's icon is highlighted

#### Scenario: Horizontal crosses from the band list into the grid
- **WHEN** the band list is focused and the horizontal offset toward the content crosses the outer threshold
- **THEN** the focus crosses into the grid, landing on the band's first/home item (now armable)

#### Scenario: Horizontal steps items within a row
- **WHEN** the grid is focused on a normal band and the horizontal offset steps (not at the first column moving outward)
- **THEN** the selection moves to the adjacent item in the current row (and again per further step)

#### Scenario: Horizontal from the first column returns to the band list
- **WHEN** the grid is focused with the selection in the first column and the horizontal offset steps toward the band list
- **THEN** the focus crosses back to the band list at the active band's icon

#### Scenario: Vertical steps grid rows and clamps at the edges
- **WHEN** the grid is focused and the vertical offset steps
- **THEN** the selection moves to the adjacent row, clamping at the first and last row (it does not rise onto the band list)

#### Scenario: Selecting an empty edge clamps
- **WHEN** the selection is on the first item and the user steps backward within the row
- **THEN** the selection stays on the first item (no wrap, by default)

#### Scenario: Clipboard band overrides horizontal item stepping
- **WHEN** the grid is focused on the Clipboard band and the horizontal offset steps within the key list
- **THEN** the selection does not step to another entry; instead the pin / return-to-band-list behavior applies

### Requirement: Edge-triggered auto-repeat for all launcher navigation

While the launcher is active, **holding the offset beyond the padding box** (or in the edge-margin band — *not* keyed to a physical trackpad edge) SHALL **auto-repeat** the corresponding navigation step, on **both axes**: a held vertical offset repeats vertical stepping (switching bands when the band list is focused, or moving between grid rows / the Clipboard list when the grid is focused), and a held horizontal offset repeats horizontal stepping (moving the item cursor within the grid, or crossing between the band list and the grid).

Auto-repeat cadence SHALL follow a **smooth eased acceleration curve over dwell duration**: position-tracking already steps the cursor to the box edge, then the **first** auto-repeat fires after a short initial delay, and the interval SHALL **shorten along a curve** (never an abrupt slow→fast jump) toward a fast minimum floor the longer the offset is held. Returning the offset back into the box SHALL stop auto-repeat; a small move back past the **back-off** SHALL stop it and re-center onto the finger. The same eased curve SHALL apply to **both axes on every navigation surface** (launcher grid, Clipboard list, and the Files navigator's highlight axis).

Auto-repeat SHALL apply to every band's navigation, not only overflowing lists — a step that has nowhere to go SHALL simply clamp. In the **Clipboard band**, horizontal auto-repeat SHALL be suppressed (there horizontal is the deliberate pin / return-to-band-list action), while vertical auto-repeat still applies. In the **Files navigator**, horizontal auto-repeat SHALL be suppressed (there horizontal *drills* the directory tree — descend/ascend a level — which must be a deliberate, discrete step, never auto-fired), while vertical (highlight) auto-repeat still applies. A clamped step (one that does not move the selection) SHALL NOT reset the dwell, so holding with nothing further to reach still lets the current item arm and fire. The padding-box size, edge-margin band, position-step, initial repeat delay, repeat floor, acceleration curve, and back-off SHALL be tunable.

#### Scenario: Holding a vertical offset keeps switching bands or stepping rows
- **WHEN** the user holds the vertical offset beyond the outer threshold (top or bottom)
- **THEN** the active band keeps switching (band list focused) or the row selection keeps advancing (grid focused) without lifting, the interval shortening along the eased curve the longer it is held

#### Scenario: Holding a horizontal offset keeps stepping items
- **WHEN** the grid is focused and the horizontal offset is held beyond the outer threshold
- **THEN** the item cursor keeps moving in that direction, accelerating along the eased curve, until it clamps (or crosses to the band list)

#### Scenario: First repeat is delayed, then the curve accelerates smoothly
- **WHEN** an offset is held just beyond the outer threshold
- **THEN** the first step fires immediately, the second fires after the initial repeat delay, and subsequent intervals shorten gradually along the curve toward the floor (not jumping straight to the fastest rate)

#### Scenario: Clipboard and Files bands suppress horizontal auto-repeat
- **WHEN** the Clipboard or Files band is active and a horizontal offset is held beyond the outer threshold
- **THEN** no pin / return-to-band-list or descend/ascend action auto-repeats (only vertical auto-repeat applies there)

#### Scenario: A clamped held offset does not block arming
- **WHEN** the selection is already at the end in the held direction and the offset stays beyond the outer threshold
- **THEN** the auto-repeat is a no-op that does not reset the dwell, so the current item can still arm and fire

#### Scenario: Returning to center stops auto-repeat
- **WHEN** the offset returns inside the inner deadzone or the contact lifts
- **THEN** auto-repeat stops and the axis re-arms

### Requirement: Swipe-to-resolve (commit / discard) for AI commands
After an AI command's result is shown in the preview canvas, a fresh **two-finger down swipe SHALL commit** the result (routing it per the command's output target — paste/replace, or run the task; "bringing the result into the document") and a fresh **two-finger horizontal swipe (deliberate excursion) SHALL discard** it (cancelling any in-flight generation and writing nothing). Committing or discarding SHALL then dismiss the overlay. A down swipe before the result is committable (still loading or streaming) SHALL be ignored — the user waits — while a horizontal discard SHALL be honored at any time. An **up** swipe SHALL be ignored, so a stray upward motion never throws the result away. The resolution swipe SHALL be a **deliberate excursion past a threshold larger than incidental two-finger scrolling**, so reading/scrolling the canvas is not mistaken for a resolve; because the firing lift has already raised the fingers, resolution is always a new swipe, and a re-lift while the canvas is open commits nothing.

This aligns the platform grammar: **four fingers open/dismiss the platform, two fingers act within it** — so the canvas (which is summoned by a two-finger trigger) is also resolved by two fingers, replacing the previous four-finger resolution.

#### Scenario: Two-finger down swipe commits
- **WHEN** the result is committable and the user makes a deliberate two-finger down swipe
- **THEN** the result is routed to the command's output target and the overlay hides

#### Scenario: Down swipe before ready is ignored
- **WHEN** the user swipes down while the model is still loading or streaming
- **THEN** nothing is committed and the canvas stays open until the result is ready

#### Scenario: Two-finger horizontal swipe discards and cancels
- **WHEN** the result is streaming or shown and the user makes a deliberate two-finger horizontal swipe to discard
- **THEN** generation is cancelled, nothing is written, and the overlay hides

#### Scenario: Up swipe is ignored
- **WHEN** the user swipes up while the canvas is open
- **THEN** nothing is committed or discarded and the canvas stays open

#### Scenario: Scrolling the canvas is not mistaken for a resolve
- **WHEN** the user scrolls the canvas content with a small two-finger motion below the resolve excursion threshold
- **THEN** the canvas scrolls and neither commit nor discard is triggered
