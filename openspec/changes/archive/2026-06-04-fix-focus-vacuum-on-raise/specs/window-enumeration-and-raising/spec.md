## ADDED Requirements

### Requirement: Raising never leaves a focus vacuum
Raising a window SHALL deterministically establish a key window — after a raise, exactly one application SHALL be frontmost with a key window, on the current Space or another Space. The raise SHALL always finish with an application activation fallback so a key window is established even if the SkyLight front/key handshake fails, and SHALL NOT leave a process fronted with no key window.

#### Scenario: Current-Space raise leaves a key window
- **WHEN** a current-Space window is committed
- **THEN** its application becomes frontmost with that window as the key window, and clicks/scroll/keyboard reach it without any Mission Control intervention

#### Scenario: Off-Space raise leaves a key window
- **WHEN** an off-Space window is committed
- **THEN** the Space switches once and its application becomes frontmost with a key window; if the SkyLight key handshake fails, the activation fallback still establishes key state

#### Scenario: No system-wide input freeze after repeated switches
- **WHEN** the user commits many window switches in succession across current- and off-Space targets
- **THEN** the system continues to accept clicks, scroll, and keyboard input after every commit (no focus vacuum)

#### Scenario: Key-window handshake reports failure
- **WHEN** the low-level key-window event posts fail
- **THEN** the raise falls back to Accessibility focus plus application activation rather than leaving no key window
