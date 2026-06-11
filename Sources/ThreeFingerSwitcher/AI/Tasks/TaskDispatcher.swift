import Foundation

/// The concrete agentic task layer (tasks phase 13.2): turns a `TaskKind` + a resolved prompt into a
/// `TaskReview` via schema-targeted structured output, and fires the reviewed side effect on commit.
///
/// It depends only on small injectable seams — a runtime provider and four sinks (`CalendarSink`,
/// `ProjectStore`, `ToolOpener`, `DestinationSender`) — so the whole flow unit-tests headless against
/// `StubLLMRuntime` + fakes. Production wires the EventKit / on-disk / launch / adapter implementations.
///
/// Contract (design D2/D6, spec ai-command-tasks):
/// - `prepare` validates + repairs/retries via `runtime.structured(...)`; a typed decline OR an
///   `applicable:false` parsed action → `.declined`; an exhausted repair loop → `.unavailable`
///   (NEVER a malformed side effect); success → `.action` with preview `fields` + payload.
/// - `execute` fires the side effect for a confirmed `.action` ONLY — and routes calendar/save/open/
///   send to the right sink with the right payload.
@MainActor
final class TaskDispatcher: TaskDispatching {

    /// Resolves a `.text`-capable runtime to drive `structured(...)`. In production this is
    /// `{ try await modelManager.runtime(requiring: [.text]) }`; tests inject a stub directly.
    private let runtimeProvider: () async throws -> LLMRuntime
    private let calendarSink: CalendarSink
    private let reminderSink: ReminderSink
    private let contactSink: ContactSink
    private let projectStore: ProjectStore
    private let toolOpener: ToolOpener
    private let destinationSender: DestinationSender

    init(runtimeProvider: @escaping () async throws -> LLMRuntime,
         calendarSink: CalendarSink,
         reminderSink: ReminderSink,
         contactSink: ContactSink,
         projectStore: ProjectStore,
         toolOpener: ToolOpener,
         destinationSender: DestinationSender) {
        self.runtimeProvider = runtimeProvider
        self.calendarSink = calendarSink
        self.reminderSink = reminderSink
        self.contactSink = contactSink
        self.projectStore = projectStore
        self.toolOpener = toolOpener
        self.destinationSender = destinationSender
    }

    /// Convenience production wiring: drive structured output off the `ModelManager`'s text runtime and
    /// use the EventKit / Contacts / on-disk / workspace / adapter sinks. Calendar, Reminders, and
    /// Contacts permissions are each requested lazily at first use of the corresponding task.
    convenience init(modelManager: ModelManager, permissions: PermissionsService) {
        self.init(
            runtimeProvider: { try await modelManager.runtime(requiring: [.text]) },
            calendarSink: EventKitCalendarSink(permissions: permissions),
            reminderSink: EventKitReminderSink(permissions: permissions),
            contactSink: ContactsSink(permissions: permissions),
            projectStore: DiskProjectStore(),
            toolOpener: WorkspaceToolOpener(),
            destinationSender: AdapterDestinationSender()
        )
    }

    // MARK: - Prepare

    func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource,
                 reasoning: Bool) async -> TaskReview {
        switch kind {
        case .addToCalendar:
            return await prepareCalendar(resolvedPrompt: resolvedPrompt, reasoning: reasoning)
        case .addToReminder:
            return await prepareReminder(resolvedPrompt: resolvedPrompt, reasoning: reasoning)
        case .newContact:
            return await prepareContact(resolvedPrompt: resolvedPrompt, reasoning: reasoning)
        case let .saveToProject(project):
            return await prepareSaveToProject(project: project, resolvedPrompt: resolvedPrompt,
                                              source: source, reasoning: reasoning)
        case let .openToolWithPayload(tool):
            return await prepareOpenTool(tool: tool, resolvedPrompt: resolvedPrompt, reasoning: reasoning)
        case let .sendTo(destination):
            return await prepareSendTo(destination: destination, resolvedPrompt: resolvedPrompt,
                                       reasoning: reasoning)
        }
    }

    private func prepareCalendar(resolvedPrompt: String, reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedCalendarEvent.schema, as: ParsedCalendarEvent.self,
                    reasoning: reasoning) { event in
            // A usable event must carry a title; a missing one is not a valid action.
            guard let title = event.title, !title.isEmpty else {
                return .unavailable(reason: "The action was missing a title.")
            }
            var fields: [ReviewField] = [ReviewField("Title", title)]
            if let start = event.start { fields.append(ReviewField("Start", start)) }
            if let end = event.end { fields.append(ReviewField("End", end)) }
            if let attendees = event.attendees, !attendees.isEmpty {
                fields.append(ReviewField("Attendees", attendees.joined(separator: ", ")))
            }
            if let notes = event.notes, !notes.isEmpty { fields.append(ReviewField("Notes", notes)) }
            return .action(title: "Add to Calendar", fields: fields, payload: .calendar(event))
        }
    }

    private func prepareReminder(resolvedPrompt: String, reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedReminder.schema, as: ParsedReminder.self,
                    reasoning: reasoning) { reminder in
            guard let title = reminder.title, !title.isEmpty else {
                return .unavailable(reason: "The action was missing a title.")
            }
            var fields: [ReviewField] = [ReviewField("Title", title)]
            if let due = reminder.due { fields.append(ReviewField("Due", due)) }
            if let priority = reminder.priority { fields.append(ReviewField("Priority", String(priority))) }
            if let notes = reminder.notes, !notes.isEmpty { fields.append(ReviewField("Notes", notes)) }
            return .action(title: "Add to Reminders", fields: fields, payload: .reminder(reminder))
        }
    }

    private func prepareContact(resolvedPrompt: String, reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedContact.schema, as: ParsedContact.self,
                    reasoning: reasoning) { contact in
            // A usable contact needs at least a name or a reachable handle.
            let hasAny = [contact.name, contact.email, contact.phone, contact.organization]
                .contains { ($0?.isEmpty == false) }
            guard hasAny else {
                return .unavailable(reason: "The action had no contact details.")
            }
            var fields: [ReviewField] = []
            if let name = contact.name, !name.isEmpty { fields.append(ReviewField("Name", name)) }
            if let org = contact.organization, !org.isEmpty { fields.append(ReviewField("Organization", org)) }
            if let email = contact.email, !email.isEmpty { fields.append(ReviewField("Email", email)) }
            if let phone = contact.phone, !phone.isEmpty { fields.append(ReviewField("Phone", phone)) }
            if let notes = contact.notes, !notes.isEmpty { fields.append(ReviewField("Notes", notes)) }
            return .action(title: "New Contact", fields: fields, payload: .contact(contact))
        }
    }

    private func prepareSaveToProject(project: String, resolvedPrompt: String,
                                      source: TaskSource, reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedSaveToProject.schema, as: ParsedSaveToProject.self,
                    reasoning: reasoning) { action in
            guard let content = action.content, !content.isEmpty else {
                return .unavailable(reason: "The action had no content to save.")
            }
            let fields = [ReviewField("Project", project), ReviewField("Content", content)]
            return .action(title: "Save to Project",
                           fields: fields,
                           payload: .saveToProject(project: project, action: action, source: source))
        }
    }

    private func prepareOpenTool(tool: String, resolvedPrompt: String, reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedOpenTool.schema, as: ParsedOpenTool.self,
                    reasoning: reasoning) { action in
            guard let payload = action.payload, !payload.isEmpty else {
                return .unavailable(reason: "The action produced no payload.")
            }
            let fields = [ReviewField("Tool", tool), ReviewField("Payload", payload)]
            return .action(title: "Open Tool", fields: fields, payload: .openTool(tool: tool, action: action))
        }
    }

    private func prepareSendTo(destination: Destination, resolvedPrompt: String,
                              reasoning: Bool) async -> TaskReview {
        await parse(resolvedPrompt, schema: ParsedSendTo.schema, as: ParsedSendTo.self,
                    reasoning: reasoning) { action in
            guard let content = action.content, !content.isEmpty else {
                return .unavailable(reason: "There was no content to send.")
            }
            let fields = [ReviewField("Destination", Self.describe(destination)),
                          ReviewField("Content", content)]
            return .action(title: "Send", fields: fields, payload: .sendTo(destination, action: action))
        }
    }

    /// Shared parse pipeline: call `runtime.structured(...)` with the kind's schema, map a typed
    /// decline OR an `applicable:false` affordance to `.declined`, a couldNotProduceValid /
    /// runtime-failure to `.unavailable` (NO action), and a valid + applicable value to `build(...)`.
    private func parse<A: DeclinableAction>(_ prompt: String,
                                            schema: StructuredSchema,
                                            as type: A.Type,
                                            reasoning: Bool,
                                            build: (A) -> TaskReview) async -> TaskReview {
        let runtime: LLMRuntime
        do {
            runtime = try await runtimeProvider()
        } catch {
            return .unavailable(reason: TaskDispatcher.message(for: error))
        }
        do {
            let outcome = try await runtime.structured(LLMRequest(prompt: prompt, reasoning: reasoning), schema: schema, as: type)
            switch outcome {
            case let .declined(reason):
                return .declined(reason: reason)
            case let .value(action):
                // The in-payload decline affordance is honored exactly like a typed decline.
                guard action.applicable else {
                    return .declined(reason: action.declineReason ?? "Not applicable to this input.")
                }
                return build(action)
            }
        } catch let error as RuntimeError {
            if case .couldNotProduceValid = error {
                return .unavailable(reason: "Couldn't produce a valid action.")
            }
            return .unavailable(reason: TaskDispatcher.message(for: error))
        } catch {
            return .unavailable(reason: TaskDispatcher.message(for: error))
        }
    }

    // MARK: - Execute

    func execute(_ review: TaskReview) async throws {
        guard case let .action(_, _, payload) = review else { return }
        switch payload {
        case let .calendar(event):
            try await calendarSink.create(event)
        case let .reminder(reminder):
            try await reminderSink.create(reminder)
        case let .contact(contact):
            try await contactSink.create(contact)
        case let .saveToProject(project, action, source):
            let content = action.content ?? ""
            try projectStore.append(project: project, content: content, source: source)
        case let .openTool(tool, action):
            try await toolOpener.open(tool: tool, payload: action.payload ?? "")
        case let .sendTo(destination, action):
            try await destinationSender.send(destination, content: action.content ?? "")
        }
    }

    // MARK: - Helpers

    /// A human-readable description of a destination for the review preview.
    static func describe(_ destination: Destination) -> String {
        switch destination {
        case let .shortcut(name): return "Shortcut: \(name)"
        case let .urlScheme(scheme): return "URL: \(scheme)"
        case let .shell(command): return "Shell: \(command)"
        }
    }

    /// Map any error to a clean `.unavailable` reason via the single central translator (`AIError`), so
    /// a task-prepare failure shows the same clean headline as every other AI surface. (The exhausted
    /// repair loop — `couldNotProduceValid` — is intercepted by the caller with a task-specific phrasing
    /// before this is reached.)
    private static func message(for error: Error) -> String {
        AIError.message(for: error).headline
    }
}
