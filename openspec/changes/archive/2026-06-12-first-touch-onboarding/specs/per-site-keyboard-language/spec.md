# per-site-keyboard-language — spec delta

## MODIFIED Requirements

### Requirement: Rides the master opt-in by default, gated by its own sub-toggle
Per-site behavior SHALL be controlled by a "per-site language in browsers" sub-toggle beneath the existing keyboard-language feature. The sub-toggle SHALL default **on** — the default (Accessibility) host reader needs no new permission, so enabling the keyboard-language master opt-in brings per-site behavior in browsers with it; only the Apple-Events "allow browser control" reader remains a separate, off-by-default opt-in. The sub-feature SHALL remain fully inert while the parent feature is off. While the sub-toggle is off (or the parent feature is off), browsers SHALL behave exactly as the per-app feature does, and the system SHALL NOT poll or read browser hosts. Toggling the sub-toggle SHALL take effect immediately — starting or stopping the browser host monitor in the running session with no app relaunch.

#### Scenario: Enabling the master brings per-site along
- **WHEN** the user enables the keyboard-language feature with the sub-toggle at its default
- **THEN** per-site behavior is active in supported browsers using the Accessibility host reader, with no new permission prompt

#### Scenario: Disabled sub-feature leaves browsers as per-app
- **WHEN** the per-site sub-toggle is off
- **THEN** no browser host is read or polled, and a browser is remembered by bundle identifier like any other app

#### Scenario: Toggling takes effect without relaunch
- **WHEN** the user turns the per-site sub-toggle on or off (with the parent feature on)
- **THEN** the browser host monitor starts or stops immediately in the running session

#### Scenario: Turning the sub-feature off stops monitoring
- **WHEN** the user turns the per-site sub-toggle off
- **THEN** the browser host monitor stops and no further host reads occur
