# computer-use-tools Specification

## Purpose
TBD - created by archiving change add-voice-computer-use-agent. Update Purpose after archive.
## Requirements
### Requirement: AX-first reading with bounded, honest snapshots
The system SHALL read windows through the accessibility tree as the primary sense: `read_window` SHALL produce a semantic snapshot — extracted text plus an enumerated element list (role, label, value preview, actionability) — bounded in depth and count, with truncation reported honestly (a `truncated` flag, never a silently-partial tree presented as complete). Reading SHALL run off the main thread with a timeout so a beach-balling target app never freezes a turn. A window that exposes no usable tree SHALL produce an honest "cannot read this window" outcome (vision capture remains the explicit fallback), never a fabricated result.

#### Scenario: A terminal window is read semantically
- **WHEN** `read_window` targets a standard text-bearing window
- **THEN** the step result carries its extracted text and an element list, with no screenshot or vision inference involved

#### Scenario: An AX desert is honest
- **WHEN** `read_window` targets a window exposing no usable accessibility content
- **THEN** the step reports it cannot read the window (clean headline) rather than returning fabricated or coordinate-based content

### Requirement: Acts are constrained to enumerated element IDs — never coordinates, never fabricated
Every acting tool (`click_element`, `type_text`) SHALL accept ONLY a stable element ID that resolves against the most recent snapshot of that window (a per-window epoch). Stale or unknown IDs SHALL fail cleanly (`staleElement`) instructing a re-read — the model can only act on elements that actually exist. The tool schemas SHALL contain NO coordinate parameters, and the system SHALL post no synthetic mouse movement or coordinate clicks. This extends the tool-routing "degrade, never fabricate" rule one level down: an unresolvable target is a clean failure, never a guess.

#### Scenario: A stale ID never mis-clicks
- **WHEN** an act names an element ID from an outdated snapshot after the window changed
- **THEN** the act fails with a stale-element outcome telling the loop to re-read, and nothing is clicked

#### Scenario: No coordinate surface exists
- **WHEN** the acting tools' schemas are inspected
- **THEN** no coordinate/point parameter exists on any of them

### Requirement: Every act verifies, and an unverified act is a failure
After `click_element` / `type_text`, the primitive SHALL re-read the affected element or subtree and report whether the expected change is observable. A side effect that cannot be verified SHALL become a `.failed` step with a clean headline — never a false "Done". Verification SHALL be part of the primitive (not a separate optional tool), so no code path can act without it.

#### Scenario: A click that didn't land is reported
- **WHEN** `click_element` presses an element but the re-read shows no observable change where one was expected
- **THEN** the step settles `.failed` with a clean explanatory headline, and the loop/user sees the truth

### Requirement: Window focus goes through the switcher's own commit path
`focus_window` SHALL resolve targets from the switcher's window enumeration and SHALL raise through the SAME hardened commit path the trackpad and ⌘-Tab use (`raiseCommitted`: SkyLight handshake, minimized restore, Stage Manager guards) — the agent is a third caller of existing machinery, not a parallel raise implementation.

#### Scenario: The agent focuses a background window reliably
- **WHEN** `focus_window` targets a background app's window by app + title hint
- **THEN** the window is raised via the existing commit path and the step reports the focused window's identity

### Requirement: Acts respect the write-policy gate, with a per-conversation auto-approve mode
Reading and focusing SHALL be `.auto`-tier; acting (`click_element`, `type_text`, and turning auto mode ON) SHALL be `.confirm`-tier through the EXISTING approval gate. A per-conversation `autoApprove` grant — set from the initial command's parsed intent, a routable `set_auto_mode` tool, or a visible surface toggle — SHALL lift `.confirm` steps to immediate execution for THAT conversation only. Enabling auto mode SHALL itself always require confirmation (the one approval that cannot be skipped); disabling SHALL be instant. Every auto-executed act SHALL be narrated (spoken when voice is active, always visible in the step list) — silence never hides an act.

#### Scenario: Auto mode executes acts hands-free but narrated
- **WHEN** a conversation has auto-approve granted and the loop routes a `type_text`
- **THEN** the act executes without a pause and its summary is narrated/visible as it happens

#### Scenario: Granting auto mode is itself gated
- **WHEN** the model routes `set_auto_mode(on)` without a prior user grant this conversation
- **THEN** the step pauses at the approval gate; only the user's approval enables it

### Requirement: The agent loop is time-bounded per step and per turn
Each tool dispatch SHALL race a per-step wall-clock timeout (configurable, default 30 s): a timed-out step SHALL cancel its work and settle `.failed` with a clean "timed out" headline (never a misleading network/server error). Each turn SHALL carry a total deadline (configurable, default 180 s) checked between steps; exceeding it SHALL terminate the loop through the existing cap-reached fallback with an honest partial summary. Cancellation (user abort, barge-in) SHALL remain a discard, not a failure.

#### Scenario: A hung tool cannot freeze a turn
- **WHEN** a tool step exceeds the step timeout (e.g. an unresponsive AX target)
- **THEN** the step is cancelled and settles `.failed("… timed out")`, and the loop proceeds to its fallback behavior

#### Scenario: A runaway turn ends honestly
- **WHEN** a turn's accumulated wall-clock exceeds the turn deadline
- **THEN** the loop terminates with the cap-reached fallback and an honest summary of what was and wasn't done

### Requirement: Any human trackpad touch aborts agent action instantly
While the agent is acting (`isActing`), the system SHALL treat ANY human trackpad contact as an immediate abort: the in-flight tool task and turn are cancelled (a discard), synthetic input stops, and the abort is acknowledged (visible, and spoken when voice is active). Agent-posted synthetic keyboard events SHALL be tagged at the event source and ignored by the app's own gesture/event taps, so the agent's typing can never be misread as human gestures or trigger recognizers. A visible indicator SHALL show while the agent has the wheel.

#### Scenario: The human always wins the input
- **WHEN** the user touches the trackpad while the agent is mid-act
- **THEN** the act and turn cancel immediately as a discard, and the indicator clears

#### Scenario: Agent typing never triggers the app's own recognizers
- **WHEN** `type_text` posts synthetic keystrokes
- **THEN** the app's event taps identify and ignore the tagged events (no gesture, no ⌘-Tab interception, no recognizer state change)

### Requirement: Computer-use failures join the single error taxonomy
AX failures SHALL be classified into an `AXActionError` taxonomy (`LocalizedError`, parallel to `FileActionError`): not permitted, app not responding, window gone, stale element, element not actionable, verify failed — mapped at the `AXUIElement` boundary, routed through `AIError.message(for:)`, surfaced bounded + non-blocking. Raw AX/OS error text SHALL appear only as opt-in details.

#### Scenario: A revoked Accessibility grant is a clean failure
- **WHEN** an act runs while the Accessibility permission is missing/revoked
- **THEN** the step settles `.failed` with a clean "not permitted" headline and a pointer to permissions — never raw AX error text, never a modal

### Requirement: The tool surface is flag-gated and additive
The computer-use tools SHALL exist only while the `computerUseEnabled` opt-in (default OFF, under the AI master gate) is on — the registry re-queries contributors live, so toggling takes effect immediately without restart. The tools SHALL be additive: no existing tool, command, or gesture behavior changes when the flag is off.

#### Scenario: Off means absent
- **WHEN** `computerUseEnabled` is off and the route candidates are gathered
- **THEN** no computer-use tool appears among them

