import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the agentic task layer (tasks phase 13.7; spec ai-command-tasks) against `StubLLMRuntime`
/// + fake sinks: each kind produces a schema-valid action OR a clean decline; non-conforming output is
/// repaired/retried and, if still invalid, yields NO action (`.unavailable`) — never a malformed side
/// effect; `execute` fires the side effect ONLY for a confirmed `.action`; calendar / save / open /
/// send each route to their injected sink/store/opener/sender with the right payload; save-to-project
/// appends to a temp-dir note. (EventKit's real prompt + real event creation is in the MANUAL-TEST
/// checklist — the system EventKit prompt is never faked.)
@MainActor
final class TaskDispatcherTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeCalendarSink: CalendarSink {
        private(set) var created: [ParsedCalendarEvent] = []
        var errorToThrow: Error?
        func create(_ event: ParsedCalendarEvent) async throws {
            if let e = errorToThrow { throw e }
            created.append(event)
        }
    }

    private final class FakeProjectStore: ProjectStore {
        private(set) var appended: [(project: String, content: String, source: TaskSource)] = []
        func append(project: String, content: String, source: TaskSource) throws {
            appended.append((project, content, source))
        }
    }

    private final class FakeToolOpener: ToolOpener {
        private(set) var opened: [(tool: String, payload: String)] = []
        func open(tool: String, payload: String) async throws { opened.append((tool, payload)) }
    }

    private final class FakeDestinationSender: DestinationSender {
        private(set) var sent: [(destination: Destination, content: String)] = []
        func send(_ destination: Destination, content: String) async throws {
            sent.append((destination, content))
        }
    }

    /// Build a dispatcher over a scripted stub runtime + the four fakes (created here so the fakes'
    /// main-actor inits aren't evaluated in a nonisolated default-argument context).
    private func makeDispatcher(stub: StubLLMRuntime,
                                calendar: FakeCalendarSink? = nil,
                                projects: FakeProjectStore? = nil,
                                tools: FakeToolOpener? = nil,
                                senders: FakeDestinationSender? = nil) -> TaskDispatcher {
        TaskDispatcher(runtimeProvider: { stub },
                       calendarSink: calendar ?? FakeCalendarSink(),
                       projectStore: projects ?? FakeProjectStore(),
                       toolOpener: tools ?? FakeToolOpener(),
                       destinationSender: senders ?? FakeDestinationSender())
    }

    // MARK: - Calendar: schema-valid action

    func testCalendarProducesSchemaValidAction() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":true,"title":"Sync","start":"2026-06-09T15:00","end":"2026-06-09T16:00","attendees":["sam"],"notes":"weekly"}"#))
        let dispatcher = makeDispatcher(stub: stub)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "meet sam tue 3pm",
                                              source: TaskSource())
        guard case let .action(title, fields, _) = review else {
            return XCTFail("a meeting text should yield an action, got \(review)")
        }
        XCTAssertEqual(title, "Add to Calendar")
        XCTAssertEqual(fields.first(where: { $0.label == "Title" })?.value, "Sync")
        XCTAssertEqual(fields.first(where: { $0.label == "Start" })?.value, "2026-06-09T15:00")
        XCTAssertEqual(fields.first(where: { $0.label == "Attendees" })?.value, "sam")
    }

    // MARK: - Calendar: model declines (typed) → no action

    func testCalendarTypedDeclineYieldsNoAction() async throws {
        let stub = StubLLMRuntime(structuredScript: .decline(reason: "This text is not a meeting"))
        let dispatcher = makeDispatcher(stub: stub)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "just a thought",
                                              source: TaskSource())
        guard case let .declined(reason) = review else {
            return XCTFail("a non-meeting text should decline, got \(review)")
        }
        XCTAssertEqual(reason, "This text is not a meeting")
    }

    // MARK: - Calendar: in-payload applicable:false affordance → decline

    func testCalendarApplicableFalseAffordanceYieldsDecline() async throws {
        // A schema-VALID payload that explicitly marks itself not applicable — honored like a decline.
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":false,"reason":"No meeting described"}"#))
        let dispatcher = makeDispatcher(stub: stub)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "groceries",
                                              source: TaskSource())
        guard case let .declined(reason) = review else {
            return XCTFail("applicable:false should decline, got \(review)")
        }
        XCTAssertEqual(reason, "No meeting described")
    }

    // MARK: - Non-conforming output is repaired, then succeeds

    func testNonConformingRepairedThenSucceeds() async throws {
        // First emission misses the required `applicable` key → validation fails → repair succeeds.
        let stub = StubLLMRuntime(structuredScript: .invalidThenRepaired(
            bad: #"{"title":"Sync"}"#,
            good: #"{"applicable":true,"title":"Sync","start":"2026-06-09T15:00"}"#))
        let dispatcher = makeDispatcher(stub: stub)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "p", source: TaskSource())
        XCTAssertTrue(review.isAction, "the repaired emission yields a valid action")
        XCTAssertEqual(stub.lastAttemptCount, 2, "one repair attempt converged")
    }

    // MARK: - Persistently invalid → unavailable (NO malformed side effect)

    func testPersistentlyInvalidYieldsUnavailableNotMalformedAction() async throws {
        let stub = StubLLMRuntime(structuredScript: .alwaysInvalid(json: #"{"title":"Sync"}"#),
                                  maxRepairAttempts: 3)
        let calendar = FakeCalendarSink()
        let dispatcher = makeDispatcher(stub: stub, calendar: calendar)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "p", source: TaskSource())
        guard case .unavailable = review else {
            return XCTFail("persistently invalid output must be .unavailable, got \(review)")
        }
        // Executing an unavailable review fires nothing.
        try await dispatcher.execute(review)
        XCTAssertTrue(calendar.created.isEmpty, "no event is created for an unavailable review")
    }

    // MARK: - execute fires the side effect ONLY for a confirmed .action

    func testExecuteFiresCalendarSinkForConfirmedAction() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":true,"title":"Sync","start":"2026-06-09T15:00"}"#))
        let calendar = FakeCalendarSink()
        let dispatcher = makeDispatcher(stub: stub, calendar: calendar)
        let review = await dispatcher.prepare(.addToCalendar, resolvedPrompt: "p", source: TaskSource())

        XCTAssertTrue(calendar.created.isEmpty, "prepare alone fires no side effect")
        try await dispatcher.execute(review)
        XCTAssertEqual(calendar.created.count, 1, "execute creates the event for a confirmed action")
        XCTAssertEqual(calendar.created.first?.title, "Sync")
    }

    func testExecuteIsNoOpForDeclinedAndUnavailable() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(json: #"{"applicable":true,"title":"x"}"#))
        let calendar = FakeCalendarSink()
        let dispatcher = makeDispatcher(stub: stub, calendar: calendar)
        try await dispatcher.execute(.declined(reason: "no"))
        try await dispatcher.execute(.unavailable(reason: "no"))
        XCTAssertTrue(calendar.created.isEmpty, "execute is a no-op for non-action reviews")
    }

    // MARK: - Save to project: routes to the store with project + source

    func testSaveToProjectRoutesToStore() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":true,"content":"a refined note"}"#))
        let projects = FakeProjectStore()
        let dispatcher = makeDispatcher(stub: stub, projects: projects)
        let source = TaskSource(appName: "Notes", url: URL(string: "https://x.test"),
                                timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let review = await dispatcher.prepare(.saveToProject(project: "Roadmap"),
                                              resolvedPrompt: "save this", source: source)
        guard case let .action(_, fields, _) = review else {
            return XCTFail("save-to-project should yield an action, got \(review)")
        }
        XCTAssertEqual(fields.first(where: { $0.label == "Project" })?.value, "Roadmap")

        try await dispatcher.execute(review)
        let routed = try XCTUnwrap(projects.appended.first)
        XCTAssertEqual(routed.project, "Roadmap")
        XCTAssertEqual(routed.content, "a refined note")
        XCTAssertEqual(routed.source.appName, "Notes")
    }

    // MARK: - Open tool: routes to the opener with the generated payload

    func testOpenToolRoutesToOpener() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":true,"payload":"generated prompt"}"#))
        let tools = FakeToolOpener()
        let dispatcher = makeDispatcher(stub: stub, tools: tools)
        let review = await dispatcher.prepare(.openToolWithPayload(tool: "MyTool"),
                                              resolvedPrompt: "idea", source: TaskSource())
        try await dispatcher.execute(review)
        let routed = try XCTUnwrap(tools.opened.first)
        XCTAssertEqual(routed.tool, "MyTool")
        XCTAssertEqual(routed.payload, "generated prompt")
    }

    // MARK: - Send to: routes to the sender with the (refined) content

    func testSendToRoutesToSender() async throws {
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":true,"content":"the refined message"}"#))
        let senders = FakeDestinationSender()
        let dispatcher = makeDispatcher(stub: stub, senders: senders)
        let review = await dispatcher.prepare(.sendTo(.shortcut(name: "Log")),
                                              resolvedPrompt: "msg", source: TaskSource())
        try await dispatcher.execute(review)
        let routed = try XCTUnwrap(senders.sent.first)
        XCTAssertEqual(routed.destination, .shortcut(name: "Log"))
        XCTAssertEqual(routed.content, "the refined message")
    }

    // MARK: - Each kind: a clean decline path

    func testEveryKindCanDecline() async throws {
        let kinds: [TaskKind] = [
            .addToCalendar,
            .saveToProject(project: "P"),
            .openToolWithPayload(tool: "T"),
            .sendTo(.urlScheme("x://{content}"))
        ]
        for kind in kinds {
            let stub = StubLLMRuntime(structuredScript: .decline(reason: "not applicable"))
            let dispatcher = makeDispatcher(stub: stub)
            let review = await dispatcher.prepare(kind, resolvedPrompt: "p", source: TaskSource())
            guard case .declined = review else {
                return XCTFail("\(kind) should be able to decline, got \(review)")
            }
        }
    }

    // MARK: - Save-to-project against the REAL on-disk store (temp dir)

    func testDiskProjectStoreAppendsToTempDirNote() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-projects-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiskProjectStore(directory: dir)

        let source = TaskSource(appName: "Safari", url: URL(string: "https://example.test"),
                                timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        try store.append(project: "Roadmap", content: "first note", source: source)
        try store.append(project: "Roadmap", content: "second note", source: source)

        let url = store.noteURL(for: "Roadmap")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("first note"), "the first content is appended")
        XCTAssertTrue(text.contains("second note"), "the second content is appended after the first")
        XCTAssertTrue(text.contains("Safari"), "the source app is recorded")
        XCTAssertTrue(text.contains("https://example.test"), "the source URL is recorded")
        // Ordering: first note appears before second (append, not overwrite).
        let firstRange = try XCTUnwrap(text.range(of: "first note"))
        let secondRange = try XCTUnwrap(text.range(of: "second note"))
        XCTAssertTrue(firstRange.lowerBound < secondRange.lowerBound, "content is appended in order")
    }

    // MARK: - Pure helpers

    func testDiskProjectStoreFileNameSanitizes() {
        XCTAssertEqual(DiskProjectStore.fileName(for: "Roadmap"), "Roadmap.md")
        XCTAssertEqual(DiskProjectStore.fileName(for: "a/b:c"), "a-b-c.md")
        XCTAssertEqual(DiskProjectStore.fileName(for: "   "), "project.md", "empty/blank falls back")
    }

    func testEntryBlockCarriesSourceAndTimestamp() {
        let source = TaskSource(appName: "Mail", url: URL(string: "mailto:x"),
                                timestamp: Date(timeIntervalSince1970: 0))
        let block = DiskProjectStore.entryBlock(content: "hi", source: source)
        XCTAssertTrue(block.contains("hi"))
        XCTAssertTrue(block.contains("from Mail"))
        XCTAssertTrue(block.contains("1970"), "the ISO timestamp is present")
    }

    func testUrlSchemeSubstitution() {
        XCTAssertEqual(
            AdapterDestinationSender.substitute("a b", into: "x://note?text={content}"),
            "x://note?text=a%20b", "content is substituted + percent-encoded into the placeholder")
        XCTAssertEqual(
            AdapterDestinationSender.substitute("z", into: "x://note?text="),
            "x://note?text=z", "with no placeholder, content is appended")
    }

    func testCalendarDateParsing() {
        XCTAssertNotNil(EventKitCalendarSink.parseDate("2026-06-09T15:00"), "local no-tz form parses")
        XCTAssertNotNil(EventKitCalendarSink.parseDate("2026-06-09T15:00:00Z"), "ISO with tz parses")
        XCTAssertNil(EventKitCalendarSink.parseDate(nil))
        XCTAssertNil(EventKitCalendarSink.parseDate("not a date"))
    }

    // MARK: - TaskError carries a human-facing message (guards the raw-enum-string regression)

    func testCalendarPermissionDeniedHasHumanFacingDescription() {
        let description = TaskError.calendarPermissionDenied.errorDescription
        XCTAssertNotNil(description, "the error carries a localized description, not just an enum case")
        XCTAssertTrue(description?.contains("Calendar") ?? false,
                      "the message mentions Calendar (never the raw 'calendarPermissionDenied')")
        XCTAssertNotEqual(description, "calendarPermissionDenied",
                          "the message is human-facing, not the raw enum case name")
    }

    // MARK: - Honesty (D5): a failed tool open is surfaced, not swallowed

    func testWorkspaceToolOpenerSurfacesOpenFailure() async {
        // An injected open handler that fails (stands in for a failed NSWorkspace.open / non-zero
        // `shortcuts run` exit) must propagate as a clean TaskError — never a silent success.
        let opener = WorkspaceToolOpener(openHandler: { _, _ in
            throw TaskError.sinkFailed("Could not open “MyApp”.")
        })
        do {
            try await opener.open(tool: "MyApp.app", payload: "hello")
            XCTFail("a failed open must throw, not silently succeed")
        } catch let e as TaskError {
            guard case let .sinkFailed(message) = e else {
                return XCTFail("expected .sinkFailed, got \(e)")
            }
            XCTAssertEqual(message, "Could not open “MyApp”.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWorkspaceToolOpenerSucceedsWhenOpenLands() async throws {
        var openedWith: (tool: String, file: URL)?
        let opener = WorkspaceToolOpener(openHandler: { tool, file in openedWith = (tool, file) })
        try await opener.open(tool: "MyTool", payload: "payload-text")
        let landed = try XCTUnwrap(openedWith)
        XCTAssertEqual(landed.tool, "MyTool")
        XCTAssertTrue(landed.file.lastPathComponent.hasPrefix("tfs-payload-"), "a payload file was written")
    }

    // MARK: - in-payload applicable:false decline validates for save-to-project (Fix 4)

    func testSaveToProjectApplicableFalseAffordanceYieldsDecline() async throws {
        // A schema-VALID payload (under the loosened required:["applicable"] schema) that explicitly
        // marks itself not applicable — must be honored as a decline, not failed/unavailable.
        let stub = StubLLMRuntime(structuredScript: .valid(
            json: #"{"applicable":false,"reason":"Nothing to save here"}"#))
        let projects = FakeProjectStore()
        let dispatcher = makeDispatcher(stub: stub, projects: projects)
        let review = await dispatcher.prepare(.saveToProject(project: "Roadmap"),
                                              resolvedPrompt: "groceries", source: TaskSource())
        guard case let .declined(reason) = review else {
            return XCTFail("applicable:false should decline (not .unavailable), got \(review)")
        }
        XCTAssertEqual(reason, "Nothing to save here")
        try await dispatcher.execute(review)
        XCTAssertTrue(projects.appended.isEmpty, "a declined save fires no side effect")
    }
}
