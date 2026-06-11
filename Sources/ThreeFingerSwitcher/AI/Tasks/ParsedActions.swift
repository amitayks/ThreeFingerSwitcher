import Foundation

/// Per-kind PARSED ACTION types and their JSON Schemas (tasks phase 13.1; spec "Tasks use
/// schema-targeted structured output"). Each kind is described by a `StructuredSchema` the model
/// targets via `runtime.structured(...)`; the runtime validates + repairs/retries the emission and
/// may DECLINE ("not applicable") rather than fabricate a value (design D2).
///
/// Each schema carries an explicit `applicable` boolean as a DECLINE AFFORDANCE: the model can mark
/// `applicable: false` (with a `reason`) to refuse a task whose input doesn't fit — e.g. text that
/// describes no meeting yields `applicable: false`, not an invented event. The dispatcher treats a
/// non-applicable parsed action exactly like the runtime's first-class `.declined` outcome, so the
/// decline path is honored whether the model expresses it as a typed decline or as a payload field.
///
/// The parsed types are pure `Decodable & Sendable` value types with no AppKit dependency, so the
/// whole task layer is unit-testable headless against `StubLLMRuntime`.

// MARK: - Decline affordance

/// The shared decline shape every parsed action embeds: `applicable == false` means "the model
/// refuses this task for this input" and carries an optional human-readable `reason`.
protocol DeclinableAction: Decodable, Sendable {
    /// Whether the model considers the task applicable to the input. `false` ⇒ a decline.
    var applicable: Bool { get }
    /// The reason the model declined (only meaningful when `applicable == false`).
    var declineReason: String? { get }
}

// MARK: - Calendar

/// The parsed action for an "add to calendar" task: the event the model extracted from the input.
struct ParsedCalendarEvent: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    var title: String?
    /// ISO-8601 (or model-emitted) start timestamp string. Carried as a string so the parse layer
    /// never fails on a slightly-off format; the sink resolves it to a `Date`.
    var start: String?
    var end: String?
    var attendees: [String]?
    var notes: String?

    var declineReason: String? { reason }

    /// The JSON Schema the model targets. `applicable` + `title` + `start` are required so a usable
    /// event always carries a title and a start; a decline sets `applicable:false` and may omit them
    /// only by also being routed through the runtime's typed decline (see `TaskDispatcher`).
    static let schema = StructuredSchema(
        name: "calendar_event",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean", "description": "false if the text describes no meeting" },
            "reason": { "type": "string" },
            "title": { "type": "string" },
            "start": { "type": "string", "description": "ISO-8601 start, e.g. 2026-06-08T15:00" },
            "end": { "type": "string", "description": "ISO-8601 end" },
            "attendees": { "type": "array", "items": { "type": "string" } },
            "notes": { "type": "string" }
          }
        }
        """#
    )
}

// MARK: - Reminder

/// The parsed action for an "add to reminders" task: the to-do the model extracted from the input.
/// Mirrors `ParsedCalendarEvent` (EventKit), but targets reminders rather than timed events.
struct ParsedReminder: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    var title: String?
    /// ISO-8601 (or model-emitted) due timestamp string; carried as a string so the parse layer never
    /// fails on a slightly-off format — the sink resolves it to date components.
    var due: String?
    var notes: String?
    /// EventKit reminder priority (0 = none, 1 = high … 9 = low). Optional; omitted ⇒ no priority.
    var priority: Int?

    var declineReason: String? { reason }

    static let schema = StructuredSchema(
        name: "reminder",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean", "description": "false if the text describes no task" },
            "reason": { "type": "string" },
            "title": { "type": "string" },
            "due": { "type": "string", "description": "ISO-8601 due date/time, e.g. 2026-06-08T15:00" },
            "notes": { "type": "string" },
            "priority": { "type": "integer", "description": "0 none, 1 high … 9 low" }
          }
        }
        """#
    )
}

// MARK: - Contact

/// The parsed action for a "new contact" task: the contact card the model extracted from the input
/// (e.g. an email signature). The model may decline when the input carries no contact details.
struct ParsedContact: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    var name: String?
    var email: String?
    var phone: String?
    var organization: String?
    var notes: String?

    var declineReason: String? { reason }

    static let schema = StructuredSchema(
        name: "contact",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean", "description": "false if the text has no contact details" },
            "reason": { "type": "string" },
            "name": { "type": "string", "description": "the person's full name" },
            "email": { "type": "string" },
            "phone": { "type": "string" },
            "organization": { "type": "string" },
            "notes": { "type": "string" }
          }
        }
        """#
    )
}

// MARK: - Save to project

/// The parsed action for a "save to project" task: the (optionally model-refined) content to append
/// to the project note. `project` is carried from the task config, not the model, and filled in by
/// the dispatcher; the model only refines the body.
struct ParsedSaveToProject: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    /// The body to append (the model may refine the raw input; otherwise it echoes it).
    var content: String?

    var declineReason: String? { reason }

    static let schema = StructuredSchema(
        name: "save_to_project",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean" },
            "reason": { "type": "string" },
            "content": { "type": "string", "description": "the note body to append" }
          }
        }
        """#
    )
}

// MARK: - Open tool with payload

/// The parsed action for an "open tool with this payload" task: the generated payload to hand the
/// tool. The target `tool` is carried from the task config (not invented by the model).
struct ParsedOpenTool: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    /// The payload (e.g. a generated prompt) the tool is opened with.
    var payload: String?

    var declineReason: String? { reason }

    static let schema = StructuredSchema(
        name: "open_tool",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean" },
            "reason": { "type": "string" },
            "payload": { "type": "string", "description": "the payload to open the tool with" }
          }
        }
        """#
    )
}

// MARK: - Send to destination

/// The parsed action for a "send to destination" task: the (optionally refined) content to deliver.
/// The destination itself is carried from the task config (not invented by the model).
struct ParsedSendTo: DeclinableAction, Equatable {
    var applicable: Bool
    var reason: String?
    /// The content delivered to the destination (the model may refine it).
    var content: String?

    var declineReason: String? { reason }

    static let schema = StructuredSchema(
        name: "send_to",
        json: #"""
        {
          "type": "object",
          "required": ["applicable"],
          "properties": {
            "applicable": { "type": "boolean" },
            "reason": { "type": "string" },
            "content": { "type": "string", "description": "the content to deliver" }
          }
        }
        """#
    )
}
