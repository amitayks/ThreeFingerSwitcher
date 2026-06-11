import Foundation

/// The value the UI / executor consumes after `TaskDispatcher.prepare(...)` (tasks phase 13.2). It is
/// the boundary between "the model produced (or refused) a parsed action" and "the side effect fires
/// on commit". Slice 5's armed-confirmation overlay BINDS to `.action`'s `fields` to render the
/// concrete preview; this slice builds the value and the execute path, not the overlay.
///
/// Three terminal shapes:
/// - `.action`        — a validated, parsed action ready to fire; carries display `fields` for the
///                      confirmation preview and an opaque `payload` the dispatcher executes.
/// - `.declined`      — the model judged the input "not applicable" (design D2); nothing will fire.
/// - `.unavailable`   — the bounded repair/retry loop exhausted without a valid action (or a
///                      precondition failed); NO malformed side effect is ever dispatched.
enum TaskReview: Sendable {
    /// A ready-to-fire action: a label for the task, the rendered `fields` for the preview, and the
    /// `payload` the dispatcher consumes in `execute`.
    case action(title: String, fields: [ReviewField], payload: PreparedAction)
    /// The model declined the task as not applicable.
    case declined(reason: String)
    /// No valid action could be produced (validation exhausted), or a precondition was unmet.
    case unavailable(reason: String)

    /// Convenience: the prepared payload if this is an `.action`, else nil.
    var preparedAction: PreparedAction? {
        if case let .action(_, _, payload) = self { return payload }
        return nil
    }

    var isAction: Bool {
        if case .action = self { return true }
        return false
    }

    /// Compare two reviews by their OBSERVABLE preview surface (discriminant + title + fields, and the
    /// reason for non-action shapes). The `payload` is opaque (it wraps non-Equatable closures-free but
    /// intentionally hidden parsed actions), so it is deliberately excluded. Used for `State` equality
    /// in tests / the UI, which only ever observe the preview.
    static func previewEqual(_ lhs: TaskReview, _ rhs: TaskReview) -> Bool {
        switch (lhs, rhs) {
        case let (.action(t1, f1, _), .action(t2, f2, _)):
            return t1 == t2 && f1 == f2
        case let (.declined(r1), .declined(r2)):
            return r1 == r2
        case let (.unavailable(r1), .unavailable(r2)):
            return r1 == r2
        default:
            return false
        }
    }
}

/// One `(label, value)` row rendered in the action-review preview (tasks phase 13.2). Pure value type
/// so the preview is unit-testable without any UI.
struct ReviewField: Equatable, Sendable {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// The opaque, validated payload the dispatcher executes for a confirmed `.action`. It pairs the
/// typed parsed action with the concrete config carried from the command (project name, tool, send-to
/// destination), so `execute` routes to the right sink/store/opener/sender with the right values.
enum PreparedAction: Sendable {
    case calendar(ParsedCalendarEvent)
    case reminder(ParsedReminder)
    case contact(ParsedContact)
    case saveToProject(project: String, action: ParsedSaveToProject, source: TaskSource)
    case openTool(tool: String, action: ParsedOpenTool)
    case sendTo(Destination, action: ParsedSendTo)
}

/// The provenance recorded alongside saved/sent content (spec: save-to-project appends content "with
/// its source app/URL and a timestamp"). Captured at fire time from the command's `FireContext`.
struct TaskSource: Equatable, Sendable {
    var appName: String?
    var url: URL?
    var timestamp: Date

    init(appName: String? = nil, url: URL? = nil, timestamp: Date = Date()) {
        self.appName = appName
        self.url = url
        self.timestamp = timestamp
    }
}
