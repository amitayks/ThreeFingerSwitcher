## ADDED Requirements

### Requirement: Two-tier memory — capped core ground truth plus a table of contents of subfiles
The system SHALL maintain agent memory in **two tiers**: a single **CORE** document holding ground-truth
**facts** and a **table of contents** of named subfiles, and a set of named **SUBFILES** holding the
details. The CORE SHALL be read **every session** (injected as context). The CORE SHALL hold **only** facts
and the table-of-contents line for each subfile — **never** a subfile's detail body. Each table-of-contents
entry SHALL name a subfile and carry its one-line summary. The detail behind a fact SHALL live in a subfile
pulled **on demand by relevance**, not in the CORE.

#### Scenario: Core is read every session and holds facts plus a table of contents
- **WHEN** a session begins
- **THEN** the core ground-truth facts and the subfile table of contents are available to the agent, and the subfile detail bodies are not loaded until requested

#### Scenario: Detail lives in a subfile, not in core
- **WHEN** detail content is remembered for a topic
- **THEN** the detail is written into a named subfile and the core holds only a table-of-contents entry (name + summary) pointing at it

#### Scenario: A subfile body is pulled only on demand
- **WHEN** the agent needs the detail behind a table-of-contents entry
- **THEN** that subfile's body is loaded at that point, by relevance, not eagerly with every session

### Requirement: Hard core cap that physically evicts to subfiles
The CORE SHALL have a **hard size cap** (a byte cap and a fact-count cap, whichever binds first) that it
SHALL NOT exceed. When a write would push the CORE past the cap, the system SHALL **evict** the
lowest-value detail-bearing fact(s) into a subfile and replace them in the CORE with a table-of-contents
entry, so the always-read tier stays bounded regardless of how much is written. The eviction selection
SHALL be deterministic. A single fact larger than the entire cap SHALL be routed to a subfile (it is
detail, not a fact) or, if forced into the core, SHALL surface as a clean failure — never silently
truncated and never reported as kept-in-core when it was not.

#### Scenario: A write over the cap evicts to a subfile
- **WHEN** adding a fact would push the core past its cap
- **THEN** the lowest-value existing fact(s) are moved into a subfile, the core gains a table-of-contents entry in their place, and the core stays within the cap

#### Scenario: The cap is never exceeded
- **WHEN** any sequence of writes is applied
- **THEN** the serialized core never exceeds its byte cap or its fact-count cap

#### Scenario: A single oversized fact does not silently break the cap
- **WHEN** a single fact is larger than the whole cap
- **THEN** it is stored as a subfile, or the operation fails with a clean headline, and it is never reported as kept in core when it was not

### Requirement: Promotion to core is proposed, with the cap as the backstop
The agent SHALL NOT silently grow the CORE. Keeping new content as a CORE fact SHALL be a **proposal** the
agent makes (a `memory.promote` step — "keep this in core?"), gated by the write-policy layer, while the
hard cap remains the structural **backstop**: even an approved promotion that would breach the cap SHALL
trigger eviction so the core stays bounded. The user SHALL be able to **override** promotion and eviction by
editing the memory files by hand (adding/removing a fact, moving content between a fact and a subfile).

#### Scenario: The agent proposes a promotion rather than silently filling core
- **WHEN** the agent wants to keep new content as a core fact
- **THEN** it raises a promotion proposal that the policy layer can gate, rather than writing the core fact silently

#### Scenario: The cap backstops an approved promotion
- **WHEN** an approved promotion would push the core past its cap
- **THEN** eviction to a subfile runs so the core stays within the cap

#### Scenario: The user overrides by hand
- **WHEN** the user edits the core document or a subfile directly
- **THEN** the change is honored on reload, including moving content between the fact tier and a subfile

### Requirement: Memory tools — free read, side-effecting writes that are whitelisted-auto and audited
The system SHALL expose memory operations as routed tools: a **read** tool (`memory.read`) that is **free**
(write-policy `auto`, runs even when the session is parked, never escalates) reading the core and retrieving
relevant subfiles; and **side-effecting** tools (`memory.write`, `memory.update`, `memory.forget`,
`memory.promote`). Per the adopted policy, memory writes SHALL be **whitelisted to an effective `auto`
tier**, so they apply **without a confirmation even when the session is parked**, BECAUSE the memory store is
**contained** (it can write only within the memory folder) and **every memory operation is audited**. The
user SHALL be able to turn off the whitelist so memory writes again require a foreground confirmation. A
**dangerous** memory operation (a bulk forget, a destructive core rewrite) SHALL classify as `dangerous`
regardless of the whitelist and escalate to the foreground via the needs-you badge even when parked.

#### Scenario: Read runs free, even when parked
- **WHEN** the agent reads memory while the session is parked
- **THEN** the read runs without a confirmation, returns the core facts and the relevant subfiles, never escalates, and is recorded in the audit log

#### Scenario: A whitelisted write applies auto and is audited
- **WHEN** the agent writes a memory fact or subfile and the memory whitelist is on
- **THEN** the write applies without a foreground confirmation, even if the session is parked, and an audit record is appended

#### Scenario: Disabling the whitelist re-requires confirmation
- **WHEN** the user turns off the memory-write whitelist
- **THEN** a memory write becomes a confirm step requiring foreground approval

#### Scenario: A dangerous memory operation escalates
- **WHEN** the agent attempts a bulk forget or a destructive core rewrite
- **THEN** the operation classifies as dangerous and escalates to the foreground via the needs-you badge, applying nothing until approved

#### Scenario: A memory write that does not land is a failure, never a false success
- **WHEN** a memory write's disk IO fails
- **THEN** the step is reported failed with a clean headline and audited as a failure, never reported done

### Requirement: Memory is editable by the agent by direction and by the user by hand
Memory SHALL be editable **by the agent by direction** ("remember…" → a write, "forget…" → a removal) and
**by the user by hand** (editing the same memory files directly, with no app interaction required). Agent
edits and user edits SHALL converge on the **same** files, and the system SHALL pick up out-of-band user
edits by **watching and reloading** the memory folder off the main thread. A malformed hand-edited subfile
SHALL surface as a bounded, non-blocking problem (excluded from the index, the rest still loaded), never a
crash, never an app-modal alert, and never a silent drop of the whole memory.

#### Scenario: The agent edits by direction
- **WHEN** the user tells the agent to remember or forget something
- **THEN** the agent writes or removes the corresponding fact or subfile

#### Scenario: The user edits by hand and it is picked up
- **WHEN** the user edits the core document or a subfile on disk directly
- **THEN** the change is reloaded off-main and reflected in the memory the agent reads next

#### Scenario: A malformed subfile is bounded, not fatal
- **WHEN** a subfile on disk has malformed front-matter
- **THEN** that subfile is reported as a bounded problem and excluded from the index while the remaining memory loads normally

### Requirement: On-disk store paralleling the project-note store, contained to the memory folder
Memory SHALL be persisted **on disk** in an Application-Support directory paralleling the project-note
store, with a single core document file and a subfiles folder. The store SHALL be **contained**: every
write SHALL be rooted inside the memory folder, and a subfile name SHALL be run through a sanitizer that
prevents path traversal and never yields an empty name, so a memory write can never touch a file outside the
memory folder. The store's table of contents SHALL be **reconciled** against the actual subfiles folder on
load and after every write — a subfile with no table-of-contents entry SHALL gain one, and a
table-of-contents entry with no backing subfile SHALL be dropped — so the always-read core never advertises
a subfile that does not exist.

#### Scenario: Writes stay inside the memory folder
- **WHEN** a memory write names a subfile with traversal characters or slashes
- **THEN** the resolved file path stays rooted inside the memory folder and never escapes it

#### Scenario: The table of contents is reconciled with the subfiles
- **WHEN** the memory is loaded and the subfiles folder and the table of contents disagree
- **THEN** a missing entry is added from the subfile's summary and a stale entry with no backing subfile is dropped, so the core's table of contents matches the subfiles

### Requirement: Memory retrieval reuses the single shared document index
Memory SHALL contribute its documents into the **single shared declarative-document index** (the same
retriever used by skills), tagged with their **kind** (memory-core / memory-subfile), and SHALL NOT define a
second retriever. The combined skills-and-memory table of contents SHALL be **one** enumeration ranked by
**one** retriever, and a memory subfile body SHALL be loaded on demand through that same index. Memory
document identifiers SHALL be namespaced (by a path-relative id and kind, in a separate folder from skills)
so a memory name and a skill identifier cannot collide.

#### Scenario: Memory and skills share one index
- **WHEN** both skill documents and memory documents are present
- **THEN** they appear in one combined index enumeration, each tagged with its kind, ranked by one retriever, with no second memory-specific retriever

#### Scenario: A memory subfile is retrieved and its body loaded on demand
- **WHEN** a query matches a memory subfile
- **THEN** the subfile's summary is ranked among the results and its body is loaded on demand through the shared index

#### Scenario: Memory and skill identifiers cannot collide
- **WHEN** a memory subfile name equals a skill identifier
- **THEN** they remain distinct in the index because memory documents are namespaced by a separate folder and kind
