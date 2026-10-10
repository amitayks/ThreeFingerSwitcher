## MODIFIED Requirements

### Requirement: The curtain blocks the outside world while agents work
In Curtain mode, once armed, the guard SHALL swallow every input event that is not from a trusted app, so it never reaches any app, while trusted input passes. Where Touch ID is available, the guard SHALL listen for the owner's finger with no visible prompt; a person's input SHALL NOT open a prompt (the fingerprint icon MAY show). The owner's finger SHALL end the session with no lock. An unrecognized finger SHALL open the system prompt with a password option; while it is open only keys and clicks inside the prompt SHALL pass. A failed prompt SHALL keep the curtain up and resume silent listening. Without Touch ID the visible prompt opens on the first blocked input. If the curtain cannot be installed, the guard SHALL fall back to the passive monitor and an input-path stop SHALL lock.

#### Scenario: A stranger behind the curtain
- **WHEN** a curtain session is armed and a person clicks, types or swipes
- **THEN** nothing reaches any app and no prompt or message appears

#### Scenario: The owner returns
- **WHEN** the owner rests an enrolled finger on Touch ID
- **THEN** the session ends without a lock screen and without a prompt

#### Scenario: Finger not recognized
- **WHEN** a finger on Touch ID is not recognized
- **THEN** the system prompt opens and offers the password

#### Scenario: The agent keeps working
- **WHEN** the listener holds focus and the trusted agent types
- **THEN** focus returns to the agent's app and its keys arrive there in order
