import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the `ai-skills-as-files` slice (tasks §1–§7): the pure `SkillManifest`/`SkillFile`
/// parse↔serialize round-trip + sink encoding (1.x/2.x), the shared `InMemoryDocIndex` retrieval
/// (3.x), the `SkillStore` built-in projection + shadowing + problem collection (4.x), the
/// `SkillToolProvider` descriptor projection + `run()` outcome mapping (5.x), and the `SkillError`
/// taxonomy + the one translator (6.x). Everything here is MLX-free Core, driven by scripted fakes —
/// no model, no live filesystem events.
@MainActor
final class SkillsTests: XCTestCase {

    // MARK: - 1/2. SkillFile parse → serialize → parse round-trip

    /// A fixture exercising hex tint + a `language` runtimeParameter is a fixed point: parse,
    /// serialize, re-parse, and the manifest is stable.
    func testSkillFileRoundTripIsAFixedPoint() {
        let fixture = """
        ---
        id: fix-grammar
        title: Fix Grammar
        summary: Correct spelling and grammar in the selected text, returning only the fixed text.
        keywords: [grammar, spelling, proofread]
        category: Writing
        icon: text.badge.checkmark
        tint: #40B866
        input: selection
        output: replaceSelection
        confirmBeforeRun: false
        runtimeParameter: language:English
        ---
        Fix the spelling and grammar of the following text in {lang}. Return only the corrected text:

        {input}
        """
        guard case let .success(first) = SkillFile.parse(fixture) else {
            return XCTFail("the fixture should parse")
        }
        // The hex tint decoded to the right ItemColor.
        let tint = first.command.tint
        XCTAssertNotNil(tint)
        XCTAssertEqual(tint.map { Int(($0.red * 255).rounded()) }, 0x40)
        XCTAssertEqual(tint.map { Int(($0.green * 255).rounded()) }, 0xB8)
        XCTAssertEqual(tint.map { Int(($0.blue * 255).rounded()) }, 0x66)
        // The language runtimeParameter survived.
        XCTAssertEqual(first.command.runtimeParameter?.languageDefault, "English")
        XCTAssertEqual(first.command.runtimeParameter?.options, AILanguages.all)

        // serialize → re-parse is a fixed point.
        let serialized = SkillFile.serialize(first)
        guard case let .success(second) = SkillFile.parse(serialized) else {
            return XCTFail("the serialized form should re-parse")
        }
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.title, second.title)
        XCTAssertEqual(first.summary, second.summary)
        XCTAssertEqual(first.keywords, second.keywords)
        XCTAssertEqual(first.category, second.category)
        // The embedded AICommand is a fixed point in every field EXCEPT its per-instance `id` (minted
        // fresh on each parse — the file `id` string is the skill identity, the AICommand.id is the
        // per-band-instance identity, exactly the copy(of:) stencil rule).
        var aligned = second.command
        aligned.id = first.command.id
        XCTAssertEqual(first.command, aligned, "the embedded AICommand round-trips in every field but its fresh id")
        XCTAssertNotEqual(first.command.id, second.command.id, "each parse mints a fresh AICommand.id")

        // Idempotent: serializing the re-parsed value yields the same text.
        XCTAssertEqual(serialized, SkillFile.serialize(second))
    }

    /// Every `OutputTarget` case round-trips through the flat colon encoding.
    func testEveryOutputTargetRoundTripsThroughTheColonEncoding() {
        let cases: [OutputTarget] = [
            .replaceSelection,
            .pasteAtCursor,
            .previewOnly,
            .runTask(.addToCalendar),
            .runTask(.addToReminder),
            .runTask(.newContact),
            .runTask(.saveToProject(project: "Inbox")),
            .runTask(.openToolWithPayload(tool: "com.example.tool")),
            .sendTo(.shortcut(name: "My Shortcut")),
            .sendTo(.urlScheme("x-callback://run")),
            .sendTo(.shell(command: "pbcopy")),
        ]
        for output in cases {
            let encoded = SkillFile.serializeOutput(output)
            let decoded = SkillFile.parseOutput(encoded)
            XCTAssertEqual(decoded, output, "OutputTarget \(output) should round-trip via \(encoded)")
        }
    }

    /// A malformed fixture yields exactly one `SkillProblem` (no crash) — exercised through the store's
    /// per-file mapping (missing front-matter, missing required field, unknown enum value).
    func testMalformedFixturesEachYieldExactlyOneProblem() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        write("no-frontmatter.skill.md", "just a body, no delimiters", to: folder)
        write("missing-id.skill.md", """
        ---
        title: No Id
        summary: missing the id field
        input: selection
        output: previewOnly
        ---
        body
        """, to: folder)
        write("bad-input.skill.md", """
        ---
        id: bad-input
        title: Bad Input
        summary: an unknown input enum value
        input: telepathy
        output: previewOnly
        ---
        body
        """, to: folder)

        let (skills, problems) = SkillStore.loadUserFolder(folder)
        XCTAssertTrue(skills.isEmpty, "no malformed file parses into a skill")
        XCTAssertEqual(problems.count, 3, "exactly one problem per malformed file, no crash, no silent drop")
        for problem in problems {
            XCTAssertFalse(problem.headline.isEmpty, "every problem carries a clean headline")
            XCTAssertFalse(problem.headline.contains("SkillError"), "the headline is never a raw enum dump")
        }
    }

    // MARK: - 3. InMemoryDocIndex

    private func doc(_ id: String, summary: String, keywords: [String]) -> IndexedDoc {
        IndexedDoc(id: id, title: id, summary: summary, keywords: keywords, kind: .skill,
                   bodyPath: URL(fileURLWithPath: "/tmp/\(id).skill.md"))
    }

    func testInMemoryDocIndexAllSummariesAndDeterministicRetrieve() {
        let docs = [
            doc("fix-grammar", summary: "Correct spelling and grammar in text.", keywords: ["grammar", "spelling"]),
            doc("add-calendar", summary: "Create a meeting from the text.", keywords: ["calendar", "meeting"]),
            doc("summarize", summary: "Summarize the text into a short paragraph.", keywords: ["summary"]),
        ]
        let bodies = ["fix-grammar": "FIX BODY", "add-calendar": "CAL BODY", "summarize": "SUM BODY"]
        let index = InMemoryDocIndex(docs: docs, bodies: bodies)

        XCTAssertEqual(index.allSummaries().map(\.id), ["fix-grammar", "add-calendar", "summarize"],
                       "allSummaries returns the full TOC in snapshot order")

        // Keyword match ranks first.
        let hits = index.retrieve(query: "schedule a meeting on my calendar", limit: 5)
        XCTAssertEqual(hits.first?.id, "add-calendar", "the keyword-matching doc ranks first")

        // No-hit returns [] (the router falls back to the full TOC; never throws).
        XCTAssertTrue(index.retrieve(query: "zzz totally unrelated qqq", limit: 5).isEmpty,
                      "a no-hit query returns an empty list")

        // body(of:) returns the right body.
        XCTAssertEqual(try index.body(of: "summarize"), "SUM BODY")
        XCTAssertThrowsError(try index.body(of: "ghost"), "an unknown id throws, never returns junk")
    }

    func testIndexedDocCodableRoundTrip() throws {
        let original = doc("fix-grammar", summary: "Fix grammar.", keywords: ["grammar"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IndexedDoc.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - 4. SkillStore

    func testBuiltInProjectionMatchesCatalog() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SkillStore(userFolder: folder)
        let result = await store.loadAll()

        XCTAssertTrue(result.problems.isEmpty, "an empty user folder yields no problems")
        XCTAssertEqual(result.skills.count, AICommandCatalog.entries.count,
                       "one built-in skill per catalog preset")

        // Categories are preserved on the projected skills.
        let projectedCategories = Set(result.skills.compactMap(\.category))
        let catalogCategories = Set(AICommandCatalog.Category.allCases.map(\.rawValue))
        XCTAssertEqual(projectedCategories, catalogCategories, "every catalog category survives the projection")

        // Each built-in skill carries an AICommand equal to its catalog command (reused verbatim).
        let firstEntry = AICommandCatalog.entries[0]
        let firstSkill = result.skills[0]
        XCTAssertEqual(firstSkill.command, firstEntry.command)
        XCTAssertEqual(firstSkill.origin, .builtIn)
    }

    func testUserFileShadowsBuiltInByID() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // The built-in "Fix Grammar" projects to id `fix-grammar`. Shadow it with a user file.
        XCTAssertTrue(SkillStore.builtInManifests().contains { $0.id == "fix-grammar" },
                      "the catalog projects a fix-grammar built-in")
        write("fix-grammar.skill.md", """
        ---
        id: fix-grammar
        title: My Fixed Grammar
        summary: A user-authored override of the built-in.
        input: selection
        output: previewOnly
        ---
        USER OVERRIDE BODY
        """, to: folder)

        let store = SkillStore(userFolder: folder)
        let result = await store.loadAll()
        XCTAssertEqual(result.skills.count, AICommandCatalog.entries.count,
                       "a shadow replaces in place — not a duplicate, count unchanged")
        guard let shadowed = result.skills.first(where: { $0.id == "fix-grammar" }) else {
            return XCTFail("the shadowed id is still present")
        }
        XCTAssertEqual(shadowed.origin, .user, "origin flips to .user")
        XCTAssertEqual(shadowed.title, "My Fixed Grammar")
        // The body served by the index is the user's body.
        XCTAssertEqual(try store.index().body(of: "fix-grammar"), "USER OVERRIDE BODY")
    }

    func testDuplicateUserIDIsOneProblemAndRestSucceed() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Two user files share an id (and a distinct valid user skill rides alongside).
        write("a-dup.skill.md", userSkill(id: "dup", title: "First", body: "A"), to: folder)
        write("b-dup.skill.md", userSkill(id: "dup", title: "Second", body: "B"), to: folder)
        write("solo.skill.md", userSkill(id: "solo-skill", title: "Solo", body: "S"), to: folder)

        let (skills, problems) = SkillStore.loadUserFolder(folder)
        XCTAssertEqual(problems.count, 1, "the duplicate is exactly one problem")
        XCTAssertEqual(Set(skills.map(\.id)), ["dup", "solo-skill"],
                       "the first-by-filename dup wins and the unrelated skill still loads")
        // Deterministic winner: a-dup.skill.md sorts before b-dup.skill.md.
        XCTAssertEqual(skills.first(where: { $0.id == "dup" })?.title, "First")
    }

    func testEmptyOrAbsentFolderIsNotAnError() async throws {
        let absent = URL(fileURLWithPath: "/tmp/three-finger-skills-\(UUID().uuidString)")
        let (skills, problems) = SkillStore.loadUserFolder(absent)
        XCTAssertTrue(skills.isEmpty)
        XCTAssertTrue(problems.isEmpty, "an absent folder is idle, not a failure")
    }

    // MARK: - 4.4 Watch + coalesced reload

    /// The pure coalescer collapses a burst: a check scheduled for an early event declines once a
    /// newer event has pushed `lastEvent` forward, and only fires once the window has truly settled.
    func testReloadCoalescerCollapsesABurst() {
        let coalescer = ReloadCoalescer(interval: 0.25)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)

        // A single event: the check one window later is settled.
        XCTAssertTrue(coalescer.isSettled(lastEvent: t0, now: t0.addingTimeInterval(0.25)))

        // A burst: the check scheduled for t0 fires at t0+0.25, but a newer event landed at t0+0.20,
        // so `lastEvent` is t0+0.20 and only 0.05s has elapsed → not settled (the burst keeps collapsing).
        let newer = t0.addingTimeInterval(0.20)
        XCTAssertFalse(coalescer.isSettled(lastEvent: newer, now: t0.addingTimeInterval(0.25)))

        // The window after the LAST event of the burst is settled → exactly one reload fires.
        XCTAssertTrue(coalescer.isSettled(lastEvent: newer, now: newer.addingTimeInterval(0.25)))

        // Just-before the window is not yet settled.
        XCTAssertFalse(coalescer.isSettled(lastEvent: t0, now: t0.addingTimeInterval(0.10)))
    }

    /// The watcher's coalesced-reload path re-runs `loadAll()` off-main and republishes the fresh
    /// result on the main actor (driven by the manual trigger — the live FS event is user-run-verify).
    /// A file dropped after the watcher started shows up in the republished snapshot, proving
    /// `loadAll()` is idempotent (re-call picks up the new file).
    func testWatcherReloadPicksUpANewFileAndRepublishes() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = SkillStore(userFolder: folder)
        _ = await store.loadAll()   // initial: built-ins only, no user skill

        let exp = expectation(description: "republished")
        let republished = UncheckedBox<SkillLoadResult?>(nil)
        let watcher = SkillFolderWatcher(store: store) { result in
            republished.value = result
            exp.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        // Drop a new user skill, then drive the coalesced reload manually.
        write("dropped-in.skill.md", userSkill(id: "dropped-in", title: "Dropped In", body: "B"), to: folder)
        watcher.triggerReloadForTesting()

        await fulfillment(of: [exp], timeout: 5)
        let result = republished.value
        XCTAssertNotNil(result, "the reload republished a fresh snapshot")
        XCTAssertTrue(result?.skills.contains { $0.id == "dropped-in" } ?? false,
                      "loadAll() is idempotent — the re-run picked up the new file")
        // The store's own snapshot also reflects the reload (manifest(id:) resolves it).
        XCTAssertNotNil(store.manifest(id: "dropped-in"))
    }

    // MARK: - 5. SkillToolProvider descriptor projection

    func testCalendarSkillProjectsParsedCalendarSchemaAndConfirm() {
        let cmd = AICommand(name: "Add to Calendar", icon: .sfSymbol("calendar"),
                            input: .selection, promptTemplate: "{input}", output: .runTask(.addToCalendar))
        let manifest = SkillManifest(id: "add-to-calendar", origin: .builtIn, title: "Add to Calendar",
                                     summary: "Create a meeting from the selected text.", command: cmd)
        let descriptor = SkillToolProvider.descriptor(for: manifest)
        XCTAssertEqual(descriptor.name, "add-to-calendar")
        XCTAssertEqual(descriptor.summary, "Create a meeting from the selected text.")
        XCTAssertEqual(descriptor.argsSchema, ParsedCalendarEvent.schema,
                       "a calendar skill projects the ParsedCalendarEvent schema")
        XCTAssertEqual(descriptor.writePolicy, .confirm, "a side-effecting sink defaults to .confirm")
    }

    func testGrammarSkillProjectsTextSchemaAndAuto() {
        let cmd = AICommand(name: "Fix Grammar", icon: .sfSymbol("textformat"),
                            input: .selection, promptTemplate: "{input}", output: .replaceSelection)
        let manifest = SkillManifest(id: "fix-grammar", origin: .builtIn, title: "Fix Grammar",
                                     summary: "Correct spelling and grammar.", command: cmd)
        let descriptor = SkillToolProvider.descriptor(for: manifest)
        XCTAssertEqual(descriptor.argsSchema.name, "text_result", "an in-place sink projects the minimal text schema")
        XCTAssertEqual(descriptor.writePolicy, .auto, "an in-place sink is .auto")
    }

    // MARK: - 5.2 SkillToolProvider.run() outcome mapping

    func testRunInPlaceSkillReturnsDone() async {
        let cmd = AICommand(name: "Fix Grammar", icon: .sfSymbol("textformat"),
                            input: .selection, promptTemplate: "Fix: {input}", output: .replaceSelection)
        let manifest = SkillManifest(id: "fix-grammar", origin: .builtIn, title: "Fix Grammar",
                                     summary: "Correct grammar.", command: cmd)
        let runtime = StubLLMRuntime(scriptedTokens: ["Fixed ", "text."])
        let provider = SkillToolProvider(manifests: [manifest], runtime: runtime,
                                         dispatcher: FakeDispatcher())
        let result = await provider.run(call(for: manifest), gate: ScriptedApprovalGate())
        XCTAssertEqual(result.status, .done, "an in-place skill returns .done")
        XCTAssertEqual(result.summary, "Fixed text.", "the generated text is the step outcome")
    }

    func testRunSideEffectingDeclineReturnsDeclined() async {
        let cmd = AICommand(name: "Add to Calendar", icon: .sfSymbol("calendar"),
                            input: .selection, promptTemplate: "{input}", output: .runTask(.addToCalendar))
        let manifest = SkillManifest(id: "add-to-calendar", origin: .builtIn, title: "Add to Calendar",
                                     summary: "Create a meeting.", command: cmd)
        let dispatcher = FakeDispatcher()
        dispatcher.reviewToReturn = .declined(reason: "not a meeting")
        let provider = SkillToolProvider(manifests: [manifest], runtime: StubLLMRuntime(),
                                         dispatcher: dispatcher)
        let result = await provider.run(call(for: manifest), gate: ScriptedApprovalGate([.approve]))
        XCTAssertEqual(result.status, .declined(reason: "not a meeting"))
        XCTAssertEqual(dispatcher.executed, 0, "a declined review fires no side effect")
    }

    func testRunSideEffectingSinkFailureReturnsFailedNotFalseDone() async {
        let cmd = AICommand(name: "Add to Calendar", icon: .sfSymbol("calendar"),
                            input: .selection, promptTemplate: "{input}", output: .runTask(.addToCalendar))
        let manifest = SkillManifest(id: "add-to-calendar", origin: .builtIn, title: "Add to Calendar",
                                     summary: "Create a meeting.", command: cmd)
        let dispatcher = FakeDispatcher()
        dispatcher.executeError = TaskError.calendarPermissionDenied
        let provider = SkillToolProvider(manifests: [manifest], runtime: StubLLMRuntime(),
                                         dispatcher: dispatcher)
        let result = await provider.run(call(for: manifest), gate: ScriptedApprovalGate([.approve]))
        guard case let .failed(headline) = result.status else {
            return XCTFail("a sink that didn't land is .failed, never a false Done")
        }
        XCTAssertTrue(headline.contains("Calendar"), "the clean TaskError headline, not a raw dump")
    }

    // MARK: - 6. SkillError + the one translator

    func testSkillErrorHeadlinesAreCleanAndBounded() {
        let errors: [SkillError] = [
            .malformedFrontMatter(detail: "raw parser dump xyz"),
            .missingRequiredField(name: "id"),
            .unknownEnumValue(field: "input", value: "telepathy"),
            .duplicateID(id: "dup"),
            .unreadable(detail: "/private/var/secret/path"),
        ]
        for error in errors {
            let presented = AIError.message(for: error)
            XCTAssertFalse(presented.headline.isEmpty)
            XCTAssertFalse(presented.headline.contains("SkillError"), "no reflected enum dump in the headline")
            XCTAssertFalse(presented.headline.contains("detail:"), "no raw associated-value name leaks")
        }
        // The raw detail rides on `details`, never the headline.
        let unreadable = AIError.message(for: SkillError.unreadable(detail: "/private/var/secret/path"))
        XCTAssertFalse(unreadable.headline.contains("/private/var/secret"),
                       "the raw path stays out of the headline")
    }

    // MARK: - Catalog unchanged sanity

    func testCatalogProjectionPreservesSeededNamesAndOrder() {
        // The migration keeps AICommandCatalog as the source of truth; confirm it is unchanged.
        XCTAssertEqual(AICommandCatalog.seeded().map(\.name),
                       ["Fix Grammar", "Make Concise", "Improve Writing", "Translate",
                        "Explain", "Summarize", "Draft a Reply", "Add to Calendar"])
    }

    // MARK: - Fakes (mirroring ToolRoutingTests)

    private func call(for m: SkillManifest) -> RoutedCall {
        RoutedCall(descriptor: SkillToolProvider.descriptor(for: m),
                   route: ToolRoute(tool: m.id, argumentsJSON: "{}"),
                   userText: "the input text", source: TaskSource())
    }

    private final class FakeDispatcher: TaskDispatching {
        var reviewToReturn: TaskReview = .action(
            title: "Event",
            fields: [ReviewField("Title", "Lunch")],
            payload: .openTool(tool: "x", action: ParsedOpenTool(applicable: true, reason: nil, payload: "p")))
        var executeError: Error?
        private(set) var executed = 0
        func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource, reasoning: Bool) async -> TaskReview {
            reviewToReturn
        }
        func execute(_ review: TaskReview) async throws {
            if let executeError { throw executeError }
            executed += 1
        }
    }

    private final class ScriptedApprovalGate: ApprovalGate, @unchecked Sendable {
        private var decisions: [ApprovalDecision]
        private let lock = NSLock()
        init(_ decisions: [ApprovalDecision] = []) { self.decisions = decisions }
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
            lock.lock(); defer { lock.unlock() }
            return decisions.isEmpty ? .approve : decisions.removeFirst()
        }
    }

    /// A tiny mutable box for capturing a value out of a `@Sendable` republish closure in a test.
    private final class UncheckedBox<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: - Temp-folder helpers

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("three-finger-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, _ contents: String, to folder: URL) {
        try? contents.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func userSkill(id: String, title: String, body: String) -> String {
        """
        ---
        id: \(id)
        title: \(title)
        summary: A user-authored skill named \(title).
        input: selection
        output: previewOnly
        ---
        \(body)
        """
    }
}
