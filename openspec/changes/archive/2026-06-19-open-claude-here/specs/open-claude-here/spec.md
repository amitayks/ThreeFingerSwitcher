## ADDED Requirements

### Requirement: Folder-bound Claude launch item

The system SHALL provide a launch-item kind bound to a single folder chosen at setup that, when fired, opens the user's default terminal at that folder and starts Claude Code. Firing SHALL be one-tap and fire-and-forget: it SHALL NOT present a folder picker or any other modal during gesture resolution. The item SHALL be a first-class, persisted band item — codable in the `Favorites` record and movable between bands like any other authored item — and SHALL persist forward-compatibly so a record written before this kind existed still decodes unchanged.

#### Scenario: Firing opens the terminal at the folder running Claude

- **WHEN** a Claude Project item bound to a folder is fired
- **THEN** the user's default terminal opens at that folder and `claude` starts in it

#### Scenario: No mid-gesture picker

- **WHEN** a Claude Project item is fired
- **THEN** no folder picker or modal appears during gesture resolution; the launch proceeds with the folder configured at setup

#### Scenario: Persists and moves between bands

- **WHEN** the user authors a Claude Project item and relaunches the app, or moves it to another band
- **THEN** the item is restored with its folder intact and belongs to its current band, like any other item

### Requirement: Configurable command with a visible generated script

The Claude Project item SHALL let the user configure the command run in the terminal, editable in the item inspector like a script body, and SHALL default to a bare `claude` session when the command is empty/default. A custom command SHALL be run as written (through the login shell); the default command SHALL run Claude using the resolved binary. The inspector SHALL also present the exact generated launch script read-only, so the user can see what runs under the hood.

#### Scenario: Default command runs a bare Claude session

- **WHEN** a Claude Project item is fired with no custom command set
- **THEN** a bare `claude` session starts in the terminal (using the resolved `claude` binary when available)

#### Scenario: Custom command runs as written

- **WHEN** the user sets a custom command (e.g. `claude --resume`) and the item is fired
- **THEN** that command is run as written in the terminal at the folder

#### Scenario: Generated script is visible in the inspector

- **WHEN** the user edits a Claude Project item in the inspector
- **THEN** the exact generated launch script is shown read-only, reflecting the configured folder and command

### Requirement: Terminal handoff without a new permission

The system SHALL open the terminal by writing an executable, self-deleting temporary command file and opening it via the system default handler, so it uses whatever terminal the user has configured as default and requires NO new permission beyond those the app already holds (in particular, no Apple Events / Automation grant). The temporary file SHALL remove itself before Claude starts so no artifact is left on disk.

#### Scenario: Uses the default terminal

- **WHEN** a Claude Project item is fired
- **THEN** the launch routes through the system default handler for the command file, opening whichever terminal the user has set as default

#### Scenario: No new permission is requested

- **WHEN** a Claude Project item is fired for the first time
- **THEN** the system does not present an Apple Events / Automation (or any other new) permission prompt

#### Scenario: The temporary file self-deletes

- **WHEN** the generated command file runs
- **THEN** it removes itself before Claude starts, leaving no artifact on disk

### Requirement: Robust Claude executable resolution

The system SHALL resolve the `claude` executable so the item works regardless of how Claude was installed (npm-global, the native installer, a version manager such as nvm or fnm, or homebrew). At setup the system SHALL attempt to resolve and store the absolute path to `claude`; when a stored absolute path is available the launch SHALL use it directly, and when none is available the launch SHALL start `claude` through an interactive login shell so shell-profile PATH additions apply. If `claude` cannot be found at setup, the system SHALL surface a clear, bounded error rather than silently authoring a non-working item.

#### Scenario: Resolves at setup and starts via the absolute path

- **WHEN** the user authors a Claude Project item and `claude` is resolvable
- **THEN** the absolute path is stored on the item and used directly when fired

#### Scenario: Falls back to an interactive shell when no path is stored

- **WHEN** a Claude Project item with no stored absolute path is fired
- **THEN** `claude` is started through an interactive login shell so version-manager / homebrew PATH additions apply

#### Scenario: Claude-not-found surfaces a clear error at setup

- **WHEN** the user authors a Claude Project item and `claude` cannot be found
- **THEN** the system surfaces a clear, bounded error and does not silently add a non-working item

### Requirement: Bounded, non-blocking failure surfacing

Failures SHALL map at the boundary into a dedicated error taxonomy and surface bounded and non-blocking — never via an app-modal alert, and never with raw OS or vendor error text in a headline (raw text is allowed only in logs or behind an opt-in details disclosure). A setup-time failure (e.g. `claude` not found) SHALL surface inline in the editor; a runtime handoff failure (e.g. the terminal could not be opened, or the command file could not be written) SHALL surface as a non-blocking notification.

#### Scenario: Runtime handoff failure notifies without blocking

- **WHEN** firing a Claude Project item fails to open the terminal or write the command file
- **THEN** the failure is reported as a non-blocking notification carrying a clean headline, and no app-modal alert appears

#### Scenario: No raw error text in a headline

- **WHEN** any Claude Project failure is presented
- **THEN** the headline is a clean, human-readable message and any raw OS/vendor error text appears only in logs or behind an opt-in details disclosure

#### Scenario: Setup-time failure is inline

- **WHEN** authoring a Claude Project item fails (e.g. `claude` not found)
- **THEN** the error is shown inline in the editor, not as an app-modal alert

### Requirement: General Open-in-Terminal item

The system SHALL provide a general "Open in Terminal" launch item — a sibling of the Claude Project item — bound to a folder and a user-supplied command. Firing it SHALL open the user's default terminal at the folder and run the command through a login+interactive shell (so the user's PATH resolves); an empty command SHALL open an interactive shell in the folder. It SHALL use the same no-new-permission terminal handoff and SHALL NOT perform any binary resolution or validation (no claude dependency). It SHALL be a first-class, persisted, Hub-authored item, addable from an "Open in Terminal" source and editable (folder + command) in the item panel, with the generated script shown read-only.

#### Scenario: Runs a command in the folder

- **WHEN** an Open-in-Terminal item with command `npm run dev` is fired
- **THEN** the user's default terminal opens at the folder and runs `npm run dev`

#### Scenario: Empty command opens a shell

- **WHEN** an Open-in-Terminal item with an empty command is fired
- **THEN** the user's default terminal opens an interactive shell in the folder

#### Scenario: No validation gate when adding

- **WHEN** the user adds an Open-in-Terminal item
- **THEN** the item is added without resolving or validating any binary, and adding never fails for a missing `claude`
