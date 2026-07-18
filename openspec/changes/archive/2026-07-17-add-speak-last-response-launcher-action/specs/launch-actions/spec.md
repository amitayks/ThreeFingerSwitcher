# Delta: launch-actions — add-speak-last-response-launcher-action

## ADDED Requirements

### Requirement: Speak-last-response is a launcher system action
The system SHALL offer "Speak Last Response" as a one-shot launcher system action (System category): firing it SHALL resolve the frontmost window, read its text via accessibility, extract the final assistant reply (model-assisted when the model is resident; the last visible lines otherwise), and speak it aloud — identical behavior to the menu-bar trigger, reachable from any launcher band via the existing favorites editor. The action SHALL be dispatched through an injected seam (the launcher never references the AI coordinator directly), and a failure SHALL surface as one spoken line — bounded, never a modal.

#### Scenario: Fired from a band
- **WHEN** the user fires a "Speak Last Response" item from a launcher band with a terminal frontmost
- **THEN** the terminal's last assistant reply is read aloud, exactly as the menu-bar item does

#### Scenario: Present in the action picker
- **WHEN** the favorites editor lists system actions
- **THEN** "Speak Last Response" appears in the System category and can be added to any band
