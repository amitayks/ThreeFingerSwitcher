## ADDED Requirements

### Requirement: Adaptive container width
The overlay container SHALL adapt its width to the number of cards: when the cards fit within the available screen width it SHALL shrink to wrap the cards and center horizontally on the active screen; when the cards exceed the available width it SHALL clamp to the maximum width, stay centered, and scroll to keep the highlighted card visible.

#### Scenario: Short list hugs and centers
- **WHEN** the overlay is shown for a snapshot whose cards fit within the available screen width
- **THEN** the container width equals the card content width (the rounded background wraps the cards with no empty trailing space)
- **AND** the container is centered horizontally on the active screen
- **AND** no scrolling occurs

#### Scenario: Overflowing list clamps and scrolls
- **WHEN** the overlay is shown for a snapshot whose cards are wider than the available screen width
- **THEN** the container width is clamped to the available screen width (minus side margins) and centered
- **AND** scrubbing scrolls the strip to keep the highlighted card visible

#### Scenario: Card metrics are a single source of truth
- **WHEN** the container width is computed
- **THEN** it uses the same card width, spacing, and padding values that the card strip uses to lay out, so the two cannot diverge
