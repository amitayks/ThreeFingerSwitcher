## ADDED Requirements

### Requirement: Thumbnails shown and refreshed on every overlay showing
The system SHALL display each window's thumbnail every time the overlay is shown — not only the first time — by applying any cached thumbnail immediately on show and refreshing (re-capturing) thumbnails so they stay current across repeated gestures.

#### Scenario: Cached thumbnail shown on repeat gesture
- **WHEN** the overlay is shown again for a window whose thumbnail was captured on an earlier gesture
- **THEN** the cached thumbnail is applied immediately so the card shows the preview (not icon-only)

#### Scenario: Thumbnail refreshed to stay live
- **WHEN** the overlay is shown
- **THEN** the visible windows' thumbnails are re-captured so the preview reflects current window content

#### Scenario: No duplicate concurrent captures
- **WHEN** a capture for a window id is already in flight
- **THEN** a second capture for the same id is not started

#### Scenario: Fallback unchanged when capture unavailable
- **WHEN** Screen Recording is not granted or a capture fails
- **THEN** the card falls back to the app-icon placeholder
