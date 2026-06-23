## ADDED Requirements

### Requirement: Agent context-length setting with cost surfaced
With the AI commands opt-in on, the settings SHALL expose the agent's **context length** as a user-adjustable choice: a **preset** (a balanced default, a long option, and a maximum option equal to the model's architectural maximum) and a **"compact long contexts" (8-bit key/value)** toggle. The chosen context length SHALL be persisted, SHALL be **clamped to the selected model's maximum context**, and SHALL default to the **balanced** preset with the compact-context toggle **off**. The settings SHALL **surface the cost** of the choice — the estimated memory footprint, the resulting number of concurrent background sessions, and a relative speed note — so the user sees the RAM/speed trade-off when growing context, rather than the system silently running out of memory. These settings SHALL be included in **reset-to-defaults**, SHALL apply immediately when changed, and settings saved before this feature SHALL load with the balanced default and the toggle off.

#### Scenario: Defaults are balanced with compaction off
- **WHEN** the app loads with no prior agent-context settings
- **THEN** the context preset is the balanced default and the compact-context toggle is off

#### Scenario: Context choice shows its RAM and concurrency cost
- **WHEN** the user changes the context preset or the compact-context toggle with the AI opt-in on
- **THEN** the settings show the estimated memory footprint, the resulting concurrent-session count, and a relative speed note for that choice

#### Scenario: Context is clamped to the selected model's maximum
- **WHEN** the user selects the maximum preset
- **THEN** the persisted context length equals the selected model's maximum and never exceeds it

#### Scenario: Context setting persists and applies immediately
- **WHEN** the user changes the context preset and relaunches
- **THEN** the chosen preset is retained, and changing it while running takes effect on the next turn without a restart

#### Scenario: Reset returns context to the balanced default
- **WHEN** the user resets settings to defaults
- **THEN** the context preset returns to balanced and the compact-context toggle returns to off

#### Scenario: Older settings load with the balanced default
- **WHEN** settings saved before this feature are loaded
- **THEN** they decode successfully with the balanced context default and the compact-context toggle off, and existing settings are not reset
