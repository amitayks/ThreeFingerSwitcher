## ADDED Requirements

### Requirement: The AI page hosts the Background autonomy whitelist and audit log
The Hub's **AI** feature page SHALL provide a **Background autonomy** section with two surfaces:

- a **whitelist editor** — add, remove, and review the trusted **folder path prefixes** (picked as **local folders only**) and the trusted **command patterns** that let a parked agent run a `confirm` write automatically. The editor SHALL default empty (a fresh install trusts nothing arbitrary), SHALL **persist** its values with the same keys/defaults/reset semantics as the other AI opt-ins, and SHALL state plainly that whitelisting a folder/command makes matching writes run in the background, and that dangerous operations (delete, overwrite-existing, arbitrary shell) are never made automatic by the whitelist.
- an **audit log viewer** — a reverse-chronological "what your agents did while you were away" ledger of recent background and foreground tool steps, each showing the tool, a redacted arguments summary, the effective tier, the outcome (a failure shown as a clean headline with an opt-in details disclosure), and a timestamp, distinguishing background actions from foreground ones.

Both surfaces SHALL use the shared Liquid Glass presentation consistent with the rest of the Hub. A failure to persist or load the audit log SHALL surface as a **bounded, non-blocking** banner (clean headline, opt-in details), **never** an app-modal alert.

#### Scenario: The Background autonomy section is reachable on the AI page
- **WHEN** the user opens the Hub and selects the AI feature page
- **THEN** a Background autonomy section shows the whitelist editor (trusted folders + command patterns) and the audit log viewer

#### Scenario: Editing the whitelist persists and live-applies
- **WHEN** the user adds a trusted folder or command pattern and removes another
- **THEN** the change persists across launches, is preserved by a reset-to-defaults like the other AI opt-ins, and the agent's effective-tier resolution reflects it on the next step

#### Scenario: Only local folders can be added as trusted prefixes
- **WHEN** the user adds a trusted folder
- **THEN** only a local folder is accepted (network / iCloud-placeholder locations are rejected)

#### Scenario: The audit viewer reads the ledger
- **WHEN** the user opens the audit log viewer after the agent has worked
- **THEN** the recent tool steps appear in reverse-chronological order with their tool, redacted args, effective tier, outcome, and timestamp, marking which ran in the background

#### Scenario: An audit store failure is non-blocking
- **WHEN** loading or persisting the audit log fails
- **THEN** the viewer shows a bounded banner with a clean headline (details behind an opt-in disclosure) and the rest of the page stays usable, with no app-modal alert
