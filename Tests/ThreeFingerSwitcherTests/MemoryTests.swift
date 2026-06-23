import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the `ai-agent-memory` slice (tasks §1–§7): the pure `MemoryDocument` parse/serialize +
/// cap/evict (1.x), `MemorySubfile` parse/serialize + malformed boundary (2.x), reconciliation (3.x),
/// the `MemoryStore` IO/containment/write/forget/reconcile (4.x), the shared-index contribution (5.x),
/// the `MemoryToolProvider` descriptors + invoke + audit (6.x), and `MemoryError` + the one translator
/// (7.x). Everything is MLX-free Core, driven against temp dirs + fakes — no model.
@MainActor
final class MemoryTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-memory-test-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    // MARK: - 1. CORE document model

    func testCoreDocumentRoundTripIsAFixedPoint() {
        let doc = MemoryDocument(
            facts: [MemoryFact("I work at Acme"), MemoryFact("My partner is Dana")],
            contents: [MemoryTOCEntry(name: "acme-migration", summary: "Notes on the Acme migration.")])
        let reparsed = MemoryDocument.parse(doc.serialized())
        XCTAssertEqual(doc, reparsed)
        // serialize is a fixed point.
        XCTAssertEqual(doc.serialized(), reparsed.serialized())
    }

    func testEmptyAndPartialDocumentsParse() {
        XCTAssertEqual(MemoryDocument.parse(""), MemoryDocument())
        let factsOnly = MemoryDocument(facts: [MemoryFact("a")])
        XCTAssertEqual(MemoryDocument.parse(factsOnly.serialized()), factsOnly)
        let tocOnly = MemoryDocument(contents: [MemoryTOCEntry(name: "n", summary: "s")])
        XCTAssertEqual(MemoryDocument.parse(tocOnly.serialized()), tocOnly)
    }

    // MARK: - 1.2 Cap + eviction

    func testFactCapBindsAndEvicts() {
        let cap = MemoryCap(maxBytes: 100_000, maxFacts: 3)
        var doc = MemoryDocument(facts: (0..<3).map { MemoryFact("fact-\($0)") })
        XCTAssertFalse(doc.exceeds(cap))
        doc.facts.append(MemoryFact("fact-4-and-this-is-the-longest-one-so-it-evicts"))
        XCTAssertTrue(doc.exceeds(cap))
        let (kept, evicted) = doc.evicting(toFit: cap)
        XCTAssertFalse(kept.exceeds(cap))
        XCTAssertEqual(evicted.count, 1)
        // Longest fact is the eviction victim (oldest-among-longest).
        XCTAssertEqual(evicted.first?.text, "fact-4-and-this-is-the-longest-one-so-it-evicts")
    }

    func testByteCapBindsBeforeFactCap() {
        let cap = MemoryCap(maxBytes: 80, maxFacts: 1000)
        let doc = MemoryDocument(facts: [MemoryFact(String(repeating: "x", count: 200))])
        XCTAssertTrue(doc.exceeds(cap))
        // A single fact larger than the whole cap cannot be made to fit by eviction.
        let (kept, evicted) = doc.evicting(toFit: cap)
        XCTAssertTrue(kept.facts.isEmpty)
        XCTAssertEqual(evicted.count, 1)
    }

    func testEvictionIsDeterministicOldestAmongLongest() {
        let cap = MemoryCap(maxBytes: 100_000, maxFacts: 2)
        // Two equally-long facts; the OLDER (earlier index) evicts first.
        let doc = MemoryDocument(facts: [MemoryFact("AAAA"), MemoryFact("BBBB"), MemoryFact("c")])
        let (kept, evicted) = doc.evicting(toFit: cap)
        XCTAssertEqual(evicted.first?.text, "AAAA")
        XCTAssertEqual(kept.facts.map(\.text), ["BBBB", "c"])
    }

    func testWouldExceedCap() {
        let cap = MemoryCap(maxBytes: 100_000, maxFacts: 1)
        let doc = MemoryDocument(facts: [MemoryFact("one")])
        XCTAssertTrue(doc.wouldExceedCap(addingFact: MemoryFact("two"), cap: cap))
    }

    // MARK: - 2. Subfile model

    func testSubfileRoundTrip() {
        let sub = MemorySubfile(name: "acme-migration", summary: "Notes on the Acme migration.",
                                keywords: ["acme", "migration"],
                                body: "The Acme migration is targeted for Q3.",
                                updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        guard case let .success(reparsed) = MemorySubfile.parse(sub.serialized(), fallbackName: "x") else {
            return XCTFail("subfile should re-parse")
        }
        XCTAssertEqual(reparsed.name, sub.name)
        XCTAssertEqual(reparsed.summary, sub.summary)
        XCTAssertEqual(reparsed.keywords, sub.keywords)
        XCTAssertEqual(reparsed.body, sub.body)
    }

    func testMalformedSubfileIsBoundedProblem() {
        // Missing front-matter delimiters.
        if case let .failure(e) = MemorySubfile.parse("just a body", fallbackName: "bad") {
            XCTAssertEqual(e, .malformedSubfile(name: "bad", detail: "Missing the `---` front-matter delimiters."))
        } else { XCTFail("should be malformed") }
        // Missing required summary.
        let noSummary = "---\nname: x\n---\nbody"
        if case let .failure(e) = MemorySubfile.parse(noSummary, fallbackName: "x") {
            if case .malformedSubfile = e {} else { XCTFail("expected malformedSubfile") }
        } else { XCTFail("should be malformed") }
    }

    // MARK: - 3. Reconciliation

    func testReconcileDropsStaleTOCAddsMissing() {
        let doc = MemoryDocument(
            facts: [MemoryFact("keep me")],
            contents: [MemoryTOCEntry(name: "ghost", summary: "no backing file"),
                       MemoryTOCEntry(name: "real", summary: "stale summary")])
        let subfiles = [
            MemorySubfile(name: "real", summary: "fresh summary", body: "b"),
            MemorySubfile(name: "orphan", summary: "no toc entry", body: "b")]
        let result = doc.reconciled(withSubfiles: subfiles)
        XCTAssertEqual(result.facts, doc.facts)   // facts untouched
        let names = result.contents.map(\.name)
        XCTAssertFalse(names.contains("ghost"))   // dropped
        XCTAssertTrue(names.contains("real"))
        XCTAssertTrue(names.contains("orphan"))   // re-added
        // summary refreshed from the subfile front-matter.
        XCTAssertEqual(result.contents.first { $0.name == "real" }?.summary, "fresh summary")
    }

    func testReconcileConsistentIsNoOp() {
        let subfiles = [MemorySubfile(name: "a", summary: "s", body: "b")]
        let doc = MemoryDocument(contents: [MemoryTOCEntry(name: "a", summary: "s")])
        XCTAssertEqual(doc.reconciled(withSubfiles: subfiles).contents,
                       [MemoryTOCEntry(name: "a", summary: "s")])
    }

    // MARK: - 4. MemoryStore IO + containment

    func testStoreCreatesDirectoryAndContainsHostileName() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .subfile, name: "../../escape/etc", summary: "s", content: "secret")
        // The subfile landed INSIDE the memory folder (containment), not at the traversal target.
        let subfilesDir = dir.appendingPathComponent("subfiles")
        let files = try FileManager.default.contentsOfDirectory(at: subfilesDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        // The file is rooted under the subfiles folder (compare resolved paths to dodge the
        // /var ↔ /private/var temp-dir symlink).
        XCTAssertTrue(files[0].resolvingSymlinksInPath().path
            .hasPrefix(subfilesDir.resolvingSymlinksInPath().path))
        XCTAssertFalse(files[0].path.contains("/etc"))
    }

    func testFactWriteOverCapEvictsToSubfile() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        let cap = MemoryCap(maxBytes: 100_000, maxFacts: 2)
        _ = try store.write(scope: .fact, name: nil, summary: nil, content: "short identity fact", cap: cap)
        _ = try store.write(scope: .fact, name: nil, summary: nil, content: "another short fact", cap: cap)
        let outcome = try store.write(scope: .fact, name: nil, summary: nil,
                                      content: "a third much longer detail-bearing fact line here", cap: cap)
        XCTAssertNotNil(outcome.evictedToSubfile)
        let core = try store.loadCore()
        XCTAssertFalse(core.exceeds(cap))
        // The eviction subfile exists and shows in the TOC.
        XCTAssertTrue(core.contents.contains { $0.name == MemoryStore.evictionSubfileName })
    }

    func testSingleFactOverCapPromoteIsCapExceeded() {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        let cap = MemoryCap(maxBytes: 50, maxFacts: 100)
        XCTAssertThrowsError(try store.promote(content: String(repeating: "x", count: 200), cap: cap)) { err in
            XCTAssertEqual(err as? MemoryError, .capExceeded)
        }
    }

    func testSingleFactOverCapWriteRoutesToSubfile() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        let cap = MemoryCap(maxBytes: 50, maxFacts: 100)
        let outcome = try store.write(scope: .fact, name: nil, summary: nil,
                                      content: String(repeating: "y", count: 200), cap: cap)
        XCTAssertNotNil(outcome.evictedToSubfile)   // routed to a subfile, NOT kept in core
        XCTAssertTrue(try store.loadCore().facts.isEmpty)
    }

    func testSubfileWriteAddsTOCEntry() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .subfile, name: "acme", summary: "Acme notes", content: "detail")
        let core = try store.loadCore()
        XCTAssertTrue(core.contents.contains { $0.name == "acme" && $0.summary == "Acme notes" })
    }

    func testUpdateMissingSubfileThrows() {
        let store = MemoryStore(directory: tempDir())
        XCTAssertThrowsError(try store.update(name: "nope", content: "x", summary: nil)) { err in
            XCTAssertEqual(err as? MemoryError, .subfileNotFound(name: "nope"))
        }
    }

    func testForgetSingleSubfileAndBulkDangerous() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .subfile, name: "acme-one", summary: "acme thing", content: "a")
        _ = try store.write(scope: .subfile, name: "acme-two", summary: "acme thing", content: "b")
        _ = try store.write(scope: .subfile, name: "dana", summary: "partner", content: "c")

        // Single targeted forget — not dangerous.
        let single = try store.forget(scope: .subfile, name: "dana", match: nil)
        XCTAssertEqual(single.removedCount, 1)
        XCTAssertFalse(single.dangerous)
        XCTAssertFalse(try store.loadCore().contents.contains { $0.name == "dana" })

        // Broad match hitting many → dangerous.
        let bulk = try store.forget(scope: nil, name: nil, match: "acme")
        XCTAssertEqual(bulk.removedCount, 2)
        XCTAssertTrue(bulk.dangerous)

        // No-match forget is a clean no-op.
        let none = try store.forget(scope: nil, name: nil, match: "zzz-nothing")
        XCTAssertEqual(none.removedCount, 0)
        XCTAssertFalse(none.dangerous)
    }

    func testWatchReloadPicksUpExternalEdit() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .fact, name: nil, summary: nil, content: "first")
        // Simulate an out-of-band user hand-edit of core.md.
        let core = dir.appendingPathComponent("core.md")
        let edited = MemoryDocument(facts: [MemoryFact("first"), MemoryFact("hand added")])
        try Data(edited.serialized().utf8).write(to: core, options: .atomic)
        // A fresh load reflects the external change.
        XCTAssertTrue(try store.loadCore().facts.contains(MemoryFact("hand added")))
    }

    // MARK: - 5. Shared-index contribution

    func testMemoryDocsMergeWithSkillsInOneIndex() throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .fact, name: nil, summary: nil, content: "I work at Acme")
        _ = try store.write(scope: .subfile, name: "acme-migration",
                            summary: "Notes on the Acme migration project deadline.",
                            content: "Targeted for Q3. Dana owns schema.")
        let (memDocs, memBodies) = try store.indexedDocs()

        // A skill doc, merged into the SAME snapshot (no second retriever).
        let skillDoc = IndexedDoc(id: "fix-grammar", title: "Fix Grammar",
                                  summary: "Correct grammar.", keywords: ["grammar"],
                                  kind: .skill, bodyPath: dir)
        var allDocs = memDocs; allDocs.append(skillDoc)
        var allBodies = memBodies; allBodies["fix-grammar"] = "fix it"
        let index = InMemoryDocIndex(docs: allDocs, bodies: allBodies)

        // The memory core + subfile both appear in the one TOC.
        let kinds = Set(index.allSummaries().map(\.kind))
        XCTAssertTrue(kinds.contains(.memoryCore))
        XCTAssertTrue(kinds.contains(.memorySubfile))
        XCTAssertTrue(kinds.contains(.skill))

        // A memory subfile is selectable + body-loadable through the one retriever.
        let hits = index.retrieve(query: "acme migration deadline", limit: 5)
        let subID = MemorySubfile.docID(for: "acme-migration")
        XCTAssertTrue(hits.contains { $0.id == subID })
        XCTAssertEqual(try index.body(of: subID), "Targeted for Q3. Dana owns schema.")

        // Namespaced ids: a memory subfile named "fix-grammar" cannot collide with the skill id.
        XCTAssertNotEqual(MemorySubfile.docID(for: "fix-grammar"), "fix-grammar")
    }

    // MARK: - 6. MemoryToolProvider descriptors + invoke + audit

    func testDescriptorTiersMatchTable() {
        let descriptors = MemoryToolProvider.allDescriptors
        func tier(_ name: String) -> WritePolicyTier? { descriptors.first { $0.name == name }?.writePolicy }
        XCTAssertEqual(tier(MemoryToolProvider.read), .auto)        // read is free
        XCTAssertEqual(tier(MemoryToolProvider.write), .confirm)    // default confirm (whitelist → auto)
        XCTAssertEqual(tier(MemoryToolProvider.update), .confirm)
        XCTAssertEqual(tier(MemoryToolProvider.forget), .confirm)
        XCTAssertEqual(tier(MemoryToolProvider.promote), .confirm)
        XCTAssertEqual(descriptors.count, 5)
    }

    func testInvokeReadIsFreeAndAudited() async throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .fact, name: nil, summary: nil, content: "I prefer metric units")
        let audit = RecordingAudit()
        let provider = MemoryToolProvider(store: store, audit: audit, isBackground: true)
        let result = await provider.invoke(tool: MemoryToolProvider.read, argumentsJSON: "{}")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.summary.contains("I prefer metric units"))
        XCTAssertEqual(audit.records.count, 1)
        XCTAssertEqual(audit.records[0].policy, .auto)
        XCTAssertTrue(audit.records[0].wasBackground)
    }

    func testInvokeWriteAppliesAndRedactsAudit() async throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        let audit = RecordingAudit()
        let provider = MemoryToolProvider(store: store, audit: audit)
        let args = "{\"scope\":\"subfile\",\"name\":\"secret-note\",\"content\":\"the password is hunter2\"}"
        let result = await provider.invoke(tool: MemoryToolProvider.write, argumentsJSON: args)
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(try store.loadCore().contents.contains { $0.name == "secret-note" })
        // The audit summary is REDACTED — the raw secret never appears.
        let summary = audit.records[0].argumentsSummary
        XCTAssertFalse(summary.contains("hunter2"))
        XCTAssertTrue(summary.contains("content len="))
    }

    func testInvokeFailedWriteIsFailedNeverFalseDone() async {
        // A store rooted at a path that cannot be created (a file masquerading as the parent dir).
        let badParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-mem-blocked-\(UUID().uuidString)")
        try? Data("x".utf8).write(to: badParent)   // a FILE where the store wants a DIRECTORY
        let store = MemoryStore(directory: badParent.appendingPathComponent("memory"))
        let audit = RecordingAudit()
        let provider = MemoryToolProvider(store: store, audit: audit)
        let args = "{\"scope\":\"subfile\",\"name\":\"x\",\"content\":\"y\"}"
        let result = await provider.invoke(tool: MemoryToolProvider.write, argumentsJSON: args)
        if case .failed = result.status {} else { XCTFail("a non-landing write must be .failed") }
        if case .failed = audit.records.last?.outcome {} else { XCTFail("the failure must be audited") }
    }

    func testInvokeMalformedArgsDeclines() async {
        let store = MemoryStore(directory: tempDir())
        let provider = MemoryToolProvider(store: store)
        let result = await provider.invoke(tool: MemoryToolProvider.write, argumentsJSON: "{}")
        if case .declined = result.status {} else { XCTFail("missing content should decline") }
    }

    func testInvokeBulkForgetIsDangerousPolicyInAudit() async throws {
        let dir = tempDir()
        let store = MemoryStore(directory: dir)
        _ = try store.write(scope: .subfile, name: "acme-a", summary: "acme", content: "a")
        _ = try store.write(scope: .subfile, name: "acme-b", summary: "acme", content: "b")
        let audit = RecordingAudit()
        let provider = MemoryToolProvider(store: store, audit: audit)
        let result = await provider.invoke(tool: MemoryToolProvider.forget, argumentsJSON: "{\"match\":\"acme\"}")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(audit.records.last?.policy, .dangerous)
    }

    // MARK: - 7. Error taxonomy + translator

    func testMemoryErrorDescriptionsAreClean() {
        let errors: [MemoryError] = [
            .unreadableCore(detail: "NSError raw blah"),
            .writeFailed(detail: "EPERM raw blah"),
            .subfileNotFound(name: "acme"),
            .capExceeded,
            .malformedSubfile(name: "bad", detail: "YAML exploded raw blah")]
        for e in errors {
            let headline = e.errorDescription ?? ""
            XCTAssertFalse(headline.isEmpty)
            XCTAssertFalse(headline.contains("raw blah"))   // raw text never in the headline
        }
    }

    func testTranslatorRoutesMemoryError() {
        let presented = AIError.message(for: MemoryError.writeFailed(detail: "EPERM raw detail"))
        XCTAssertEqual(presented.headline, "That memory couldn't be saved.")
        XCTAssertFalse(presented.headline.contains("EPERM"))
        XCTAssertEqual(presented.details, "EPERM raw detail")   // raw text only in opt-in details
        // A clean case with no extra detail.
        let clean = AIError.message(for: MemoryError.capExceeded)
        XCTAssertNil(clean.details)
    }
}

/// A recording `MemoryAuditing` fake (the durable conformer is owned by `ai-background-autonomy`).
private final class RecordingAudit: MemoryAuditing, @unchecked Sendable {
    private(set) var records: [MemoryAuditRecord] = []
    func record(_ record: MemoryAuditRecord) { records.append(record) }
}
