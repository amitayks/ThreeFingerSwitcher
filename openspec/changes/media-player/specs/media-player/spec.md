## ADDED Requirements

### Requirement: Opt-in built-in media player, default off
The system SHALL expose a "built-in media player" opt-in that defaults to OFF and gates whether opening a playable media file from the Files band plays it in the in-app player. The opt-in SHALL relocate no native gesture, require no re-login, and request no new permission (it plays files on demand). When the opt-in is OFF, opening a media file SHALL behave exactly as before this change — handed to the system default application. Settings written before this change SHALL load with the opt-in OFF.

#### Scenario: Opt-in defaults off and preserves system-open
- **WHEN** the app loads with no prior player settings and the user opens a video file from the Files band
- **THEN** the player opt-in is OFF and the file opens in the system default application, exactly as before

#### Scenario: Enabling needs no re-login or permission
- **WHEN** the user turns the opt-in on
- **THEN** the built-in player becomes the open target for the enabled media kinds immediately, without a re-login, native-gesture relocation, or new permission prompt

#### Scenario: Legacy settings load with the player off
- **WHEN** settings written before this change are loaded
- **THEN** they decode successfully with the player opt-in OFF and no player state, and existing settings are not reset

### Requirement: Media-kind classification routes the open
The system SHALL classify a file entry as exactly one of video, audio, image, or non-media via its uniform type identifier (a pure, side-effect-free predicate). Opening a highlighted file from the Files band SHALL play it in the built-in player WHEN the file classifies as a media kind AND the player opt-in is on AND the per-kind default-open for that kind is enabled; otherwise the open SHALL fall through to the existing behavior (system default app). The Open-With action (the relative +1-finger lift) SHALL always open the file in an external application and SHALL NOT be diverted to the built-in player.

#### Scenario: A playable video routes to the player
- **WHEN** the opt-in is on, video default-open is enabled, and the user lifts to open a file classified as video
- **THEN** the built-in player opens that file instead of the system default application

#### Scenario: A non-media file is unaffected
- **WHEN** the opt-in is on and the user opens a file that classifies as non-media (e.g. a PDF)
- **THEN** the open falls through to the existing system-default-app behavior

#### Scenario: A disabled kind is not hijacked
- **WHEN** the opt-in is on but the default-open for images is disabled and the user opens an image
- **THEN** the image opens in the system default application, not the built-in player

#### Scenario: Open-With always opens externally
- **WHEN** the user performs the relative +1-finger Open-With on a media file
- **THEN** the file opens in the chosen external application and the built-in player is not used

### Requirement: Playback engine seam with AVFoundation default and libmpv alternative
The system SHALL drive playback through a single `MediaPlaybackEngine` abstraction so that no feature, navigation, or view code depends on a concrete media framework, and SHALL ship two conformers in this version: an AVFoundation-based engine as the default, and a libmpv-based engine as the alternative. The default engine SHALL be used unless the user has chosen otherwise or a fallback is triggered. The abstraction SHALL expose loading a URL, play/pause, seeking by an offset and to an absolute position, setting rate and volume, enumerating and selecting audio and subtitle tracks, and observable position/duration/playing state. The concrete engines SHALL live outside the pure core so the core's playback logic verifies against a stub engine without linking any media framework.

#### Scenario: Default engine plays a supported file
- **WHEN** the player opens a file the default engine can decode
- **THEN** playback uses the default (AVFoundation) engine and the transport controls operate through the engine abstraction

#### Scenario: Core logic runs against a stub engine
- **WHEN** the player's transport logic is exercised in tests
- **THEN** it operates against a stub engine conformer with no media framework linked

#### Scenario: Engine selection is honored
- **WHEN** the user has selected libmpv as the engine for a file (or globally)
- **THEN** the player drives playback through the libmpv engine for that file

### Requirement: Observable fallback to libmpv when the default engine cannot decode
When the default engine reports it cannot decode a file, the system SHALL NOT fail silently and SHALL NOT swap engines transparently: it SHALL transition to a bounded, non-blocking state that presents the unsupported outcome with a clean headline and offers to open the file in the libmpv engine (resolved by the player's commit gesture) or to dismiss. The decision of what to offer — given the decode-failure signal and which engines are available — SHALL be a pure, testable function. The libmpv engine SHALL also be selectable on demand from the action menu regardless of whether the default engine succeeded.

#### Scenario: Unsupported format offers libmpv
- **WHEN** the default engine reports it cannot decode the opened file
- **THEN** the player shows a bounded, non-blocking "unsupported by the default engine" state offering to open it in libmpv, and does not silently close or swap

#### Scenario: Commit opens it in libmpv
- **WHEN** the user commits the "open in libmpv" offer
- **THEN** the same file loads in the libmpv engine and playback resumes through the player surface

#### Scenario: On-demand engine override from the action menu
- **WHEN** a file is already playing in the default engine and the user picks "open in libmpv" from the action menu
- **THEN** playback switches to the libmpv engine for that file

#### Scenario: libmpv unavailable degrades, never crashes
- **WHEN** the libmpv engine cannot be loaded (its bundled library is missing or unloadable)
- **THEN** the libmpv engine reports unavailable and the player surfaces a clean bounded message rather than crashing, remaining usable with the default engine

### Requirement: Trackpad transport grammar owns the trackpad while the player is open
While the player is open it SHALL own the trackpad and interpret contacts as transport intents, NOT as the global window switcher or launcher: a two-finger horizontal excursion SHALL seek (with held-at-edge auto-repeat for continuous fast-forward / rewind); a two-finger vertical excursion SHALL change volume (with the same held-at-edge auto-repeat); a two-finger tap with no navigation excursion SHALL toggle play/pause; a relative one-finger-more posture (three fingers, relative to the two-finger navigation baseline) SHALL raise the action menu; and a four-finger gesture SHALL dismiss the player. A three-finger count while the player is open SHALL raise the action menu and SHALL NOT activate the window switcher. The player SHALL auto-repeat on both axes (unlike the depth/pin surfaces that suppress horizontal auto-repeat).

#### Scenario: Two-finger horizontal seeks
- **WHEN** the player is open and the user makes a two-finger horizontal excursion and holds it at the trackpad edge
- **THEN** playback seeks one step in that direction and then auto-repeats along the edge-triggered acceleration ramp while held

#### Scenario: Two-finger vertical changes volume
- **WHEN** the player is open and the user makes a two-finger vertical excursion and holds it
- **THEN** the volume steps in that direction and auto-repeats while held

#### Scenario: Two-finger tap toggles play/pause
- **WHEN** the player is open and the user taps two fingers without a navigation excursion
- **THEN** playback toggles between playing and paused

#### Scenario: Three fingers raise the action menu, not the switcher
- **WHEN** the player is open and the user adds a finger to reach three (one more than the navigation baseline)
- **THEN** the action menu opens and the global window switcher does not activate

#### Scenario: Four fingers dismiss the player
- **WHEN** the player is open and the user performs a four-finger gesture
- **THEN** the player dismisses, persists state, and returns the user to where they were

### Requirement: Scrubbable action menu for track, speed, loop, and engine controls
The player SHALL present an action menu, raised by the relative +1-finger posture, listing the contextual playback controls: audio track, subtitle track, playback speed, loop, chapters (when present), and "open in libmpv". The menu SHALL be navigated by the same scrubbable-picker interaction used for Open-With, and lifting on a row SHALL select that row's action. Selecting a track or speed SHALL apply it through the engine in place; selecting "open in libmpv" SHALL switch the playing file to the libmpv engine. Controls that do not apply to the current media (e.g. tracks for an image) SHALL be omitted.

#### Scenario: Select a subtitle track
- **WHEN** the action menu is open and the user lifts on a subtitle-track row
- **THEN** the engine activates that subtitle track and the menu closes back to playback

#### Scenario: Change playback speed
- **WHEN** the action menu is open and the user lifts on a speed row
- **THEN** the engine sets that rate and playback continues at the new speed

#### Scenario: Menu omits inapplicable controls
- **WHEN** the action menu is raised while viewing an image
- **THEN** the menu omits audio/subtitle/speed rows and shows only the image-applicable actions

### Requirement: Per-file resume of playback state
The system SHALL persist, per file, the resume position, the selected audio and subtitle tracks, the volume, and the playback rate, keyed by a stable file identity (absolute path with a size/modification tiebreak), in a bounded store that evicts least-recently-opened entries beyond a cap. On reopening a file, the player SHALL resume from the saved position WHEN that position is past a resume threshold and not near the end of the media; otherwise it SHALL start from the beginning. State SHALL be persisted when the player is dismissed.

#### Scenario: Reopen resumes past the threshold
- **WHEN** a file was previously left part-way through (past the resume threshold and not near the end) and is reopened
- **THEN** playback resumes from the saved position with the previously selected tracks, volume, and rate

#### Scenario: Near-start or near-end starts fresh
- **WHEN** a file's saved position is before the resume threshold or within the near-end margin
- **THEN** playback starts from the beginning

#### Scenario: Dismiss persists state
- **WHEN** the user dismisses the player
- **THEN** the current position, tracks, volume, and rate are written to the per-file store

#### Scenario: Store stays bounded
- **WHEN** more files have been played than the store's entry cap
- **THEN** the least-recently-opened entries are evicted so the store does not grow without bound

### Requirement: Non-activating, full-screen, gesture-driven player surface
The player surface SHALL be a non-activating, full-screen overlay that NEVER becomes the key or main window and is driven entirely by trackpad transport intents (it hosts no clickable controls, so it needs no key-window concession). The surface SHALL render the engine's video/image output plus a bounded status presentation, SHALL appear and recede with the app's bubble-morph spring, and SHALL tear down synchronously on a Space-switching dismiss (so it leaves no ghost on a Space switch). The player SHALL open on and play on the current Space without teleporting the user to another Space or application.

#### Scenario: Player never becomes key
- **WHEN** the player is open and playing
- **THEN** the overlay panel is non-activating and never becomes key or main, and the previously frontmost app is unaffected

#### Scenario: Opens on the current Space
- **WHEN** a media file opens in the player
- **THEN** the player appears on the current Space and does not switch Spaces or activate another application

#### Scenario: Dismiss recedes and tears down cleanly
- **WHEN** the user dismisses the player
- **THEN** the surface recedes with the bubble-morph spring and is torn down without leaving a ghost overlay on a subsequent Space switch

### Requirement: Image viewer shares the surface and grammar
The system SHALL display an image file in the same player surface with the same finger-count grammar, omitting the timeline-based transport (no seek/volume for a still image) and exposing image-applicable behavior instead, with the action menu (three fingers) and dismiss (four fingers) consistent with video/audio playback.

#### Scenario: Image opens in the viewer
- **WHEN** the opt-in is on, image default-open is enabled, and the user opens an image file
- **THEN** the image displays in the player surface

#### Scenario: Image dismiss is consistent
- **WHEN** the image viewer is open and the user performs the four-finger dismiss
- **THEN** the viewer dismisses exactly as the video/audio player does

### Requirement: Player failures are observable, bounded, and non-blocking
Every player failure (load failure, unsupported format, engine unavailable, decode error) SHALL be classified into a single media-player error taxonomy whose every case yields a clean, user-facing headline, with raw engine/OS text confined to an opt-in copyable details disclosure and never interpolated into a headline. Vendor and OS errors SHALL be mapped into this taxonomy at the engine boundary so the pure core never sees framework error types. A failure SHALL surface as an observable failed state rendered as a bounded, non-blocking card over the player (clean headline, capped length, copyable details behind a disclosure, with retry/dismiss and — where applicable — open-in-libmpv), NEVER as an application-modal alert and NEVER as a silent false success. Dismissing or cancelling the player SHALL NOT be treated as a failure.

#### Scenario: Load failure is a clean bounded card
- **WHEN** an engine fails to load a file
- **THEN** the player shows a bounded, non-blocking card with a clean per-case headline and an opt-in copyable details disclosure, never an application-modal alert and never raw error text in the headline

#### Scenario: Errors map at the engine boundary
- **WHEN** an AVFoundation or libmpv error occurs
- **THEN** it is mapped into the media-player error taxonomy at the engine boundary, so the pure core never references a framework error type

#### Scenario: Dismiss is not a failure
- **WHEN** the user dismisses the player mid-playback
- **THEN** the player tears down normally and no failure state is recorded
