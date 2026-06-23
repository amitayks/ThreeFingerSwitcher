## ADDED Requirements

### Requirement: Shared declarative-document index
The system SHALL provide a single **declarative-document index** seam (`DocIndex` over `IndexedDoc`) shared by skills and memory, so there is exactly **one** retriever and not two. An `IndexedDoc` SHALL carry a stable path-relative **id**, a **title**, a **summary** (its table-of-contents line), **keywords**, a **kind** (skill / memory-core / memory-subfile), a **body location** loaded lazily, and an **updated-at** timestamp. The index SHALL be **kind-agnostic** when ranking, so a combined skills-and-memory table of contents is one enumeration. The skills capability OWNS this seam; the memory capability SHALL CONSUME it and SHALL NOT define a second retriever.

#### Scenario: Skills and memory share one index
- **WHEN** both skill documents and memory documents are present
- **THEN** they appear in one combined index enumeration, each tagged with its kind, ranked by one retriever

#### Scenario: A document carries a table-of-contents summary
- **WHEN** an indexed document is inspected
- **THEN** it exposes a one-line summary, keywords, a kind, and a lazily-loadable body location

### Requirement: Progressive disclosure (table of contents always, body on demand)
The index SHALL expose a cheap **table of contents** — every document's summary line — that the router always sees, and SHALL load a document's **full body only on demand** when that document is selected. Selecting and reading a body SHALL be a **routed tool step** (a retrieve/read tool), not an eager bulk load, so the routing prompt is bounded to the one-line summaries regardless of corpus size. The retriever SHALL also offer a **ranked query** that returns the best-matching summaries for on-demand expansion. Ranking SHALL be deterministic.

#### Scenario: The router sees summaries, not full bodies
- **WHEN** the router scans available capabilities
- **THEN** it receives the per-document summary lines (the table of contents), not the full document bodies

#### Scenario: A body is loaded only when selected
- **WHEN** a document is selected via the retrieve/read tool
- **THEN** its full body is loaded at that point, not before

#### Scenario: A query returns ranked summaries deterministically
- **WHEN** a query is run against the index
- **THEN** it returns the best-matching document summaries in a deterministic order, and a query with no matches returns an empty (or score-floored) list without error

### Requirement: Pure synchronous index over an off-main snapshot
The retriever SHALL be a **pure, synchronous** state machine over an in-memory snapshot of indexed documents, and SHALL NOT perform file IO for enumeration or ranking. Building the snapshot and loading document bodies SHALL be bridged **off-main** by the owning store (the synchronous-model-with-async-cache pattern), so the pure index is unit-testable headless. This mirrors the existing column-navigator pattern where a pure model reads a cache that an async lister populates.

#### Scenario: Enumeration and ranking never block on IO
- **WHEN** the table of contents is enumerated or a query is ranked
- **THEN** the operation is synchronous over the in-memory snapshot and performs no file IO

#### Scenario: Snapshot building and body loads are off-main
- **WHEN** the index snapshot is built or a body is loaded
- **THEN** the file IO is performed off the main thread by the owning store and the result is published back, not done inline in the pure index
