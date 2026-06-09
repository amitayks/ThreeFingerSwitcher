import Foundation
import EventKit
import os
#if canImport(AppKit)
import AppKit
#endif

/// Breadcrumbs for side-effect failures. Raw OS errors are logged here (and only here) so a clean,
/// human-facing `TaskError.sinkFailed` message can be surfaced without leaking the raw text to the UI
/// (spec: "Diagnostic logging of the original error at the boundary is permitted and encouraged").
private let taskSinkLog = Logger(subsystem: "ThreeFingerSwitcher", category: "TaskSinks")

/// The SMALL injectable seams behind which each task's side effect lives (tasks phase 13.3–13.6), so
/// the `TaskDispatcher` is unit-testable headless: tests inject fakes that record what they were
/// asked to do; production injects the real EventKit / on-disk note / launch / destination adapters.
///
/// A side effect ONLY fires through one of these, and ONLY for a confirmed `.action` — never on
/// `prepare`, never for a `.declined` / `.unavailable` review.

// MARK: - Errors

/// Failures a task side effect can report (surfaced to the executor's `.failed` state).
enum TaskError: Error, Equatable {
    /// Calendar (EventKit) access was denied or restricted (spec: "Permission denied is handled").
    case calendarPermissionDenied
    /// The parsed action was missing a field the side effect requires (defensive; prepare guards this).
    case missingField(String)
    /// A sink/store/opener/sender failed to apply the effect.
    case sinkFailed(String)
}

/// Human-facing messages so the executor's `.failed` state shows a readable string rather than the
/// raw enum case name (e.g. "calendarPermissionDenied").
extension TaskError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .calendarPermissionDenied:
            return "Calendar access is required. Open System Settings ▸ Privacy & Security ▸ Calendars to allow it."
        case let .missingField(field):
            return "The action was missing a required field: \(field)."
        case let .sinkFailed(detail):
            return detail
        }
    }
}

// MARK: - Calendar

/// Creates a calendar event. Production uses EventKit; tests record the event without touching the
/// system. `create` is called ONLY after a confirmed review (and, in prod, a granted permission).
@MainActor
protocol CalendarSink {
    func create(_ event: ParsedCalendarEvent) async throws
}

// MARK: - Project note store

/// Appends content (with source + timestamp) to a per-project note on disk. Production writes under
/// Application Support, mirroring `ClipboardStore`'s on-disk pattern; tests use a temp dir.
@MainActor
protocol ProjectStore {
    func append(project: String, content: String, source: TaskSource) throws
}

// MARK: - Tool opener

/// Opens a target tool with a generated payload. Production writes a payload file + opens via the
/// launch mechanism; tests record the (tool, payload) pair.
@MainActor
protocol ToolOpener {
    func open(tool: String, payload: String) async throws
}

// MARK: - Destination sender

/// Delivers content to a configured destination (Shortcut / URL scheme / shell-out). Tests record
/// the (destination, content) pair.
@MainActor
protocol DestinationSender {
    func send(_ destination: Destination, content: String) async throws
}

// MARK: - Production: EventKit calendar sink

/// The production `CalendarSink`: maps `{title,start,end,attendees,notes}` to an `EKEvent` and saves
/// it. Requires Calendar permission, requested lazily by `PermissionsService` before `create` runs.
@MainActor
final class EventKitCalendarSink: CalendarSink {
    private let store: EKEventStore
    private let permissions: PermissionsService

    init(store: EKEventStore = EKEventStore(), permissions: PermissionsService) {
        self.store = store
        self.permissions = permissions
    }

    func create(_ event: ParsedCalendarEvent) async throws {
        // Lazy first-use permission (never at launch / opt-in — see permissions-onboarding).
        let granted = await permissions.requestCalendarAccess()
        guard granted else { throw TaskError.calendarPermissionDenied }

        guard let title = event.title, !title.isEmpty else { throw TaskError.missingField("title") }
        let start = Self.parseDate(event.start) ?? Date()
        let end = Self.parseDate(event.end) ?? start.addingTimeInterval(3600)

        let ek = EKEvent(eventStore: store)
        ek.title = title
        ek.startDate = start
        ek.endDate = end
        ek.notes = Self.composedNotes(for: event)
        ek.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(ek, span: .thisEvent)
        } catch {
            // Clean prefix only; the raw OS error goes to the log, never into the user-facing message
            // (spec: "No raw error text in user-facing strings").
            taskSinkLog.error("calendar save failed: \(String(describing: error), privacy: .public)")
            throw TaskError.sinkFailed("Could not save the event to your calendar.")
        }
    }

    /// Fold attendees into the notes body (EventKit can't add arbitrary attendees without invites).
    private static func composedNotes(for event: ParsedCalendarEvent) -> String? {
        var parts: [String] = []
        if let notes = event.notes, !notes.isEmpty { parts.append(notes) }
        if let attendees = event.attendees, !attendees.isEmpty {
            parts.append("Attendees: " + attendees.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Best-effort ISO-8601 parse (with and without seconds / timezone) — never throws; nil on miss.
    static func parseDate(_ string: String?) -> Date? {
        guard let s = string, !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // Tolerate a local "yyyy-MM-dd'T'HH:mm" without a timezone.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Production: on-disk project note store

/// The production `ProjectStore`: appends a timestamped, sourced block to a per-project Markdown note
/// under Application Support, mirroring `ClipboardStore.defaultDirectory()` (separate from Favorites).
@MainActor
final class DiskProjectStore: ProjectStore {
    private let directory: URL

    /// Test/seam initializer: inject an isolated directory (e.g. a temp dir).
    init(directory: URL) {
        self.directory = directory
    }

    /// Default: `~/Library/Application Support/ThreeFingerSwitcher/projects`.
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/projects", isDirectory: true)
    }

    convenience init() { self.init(directory: Self.defaultDirectory()) }

    func append(project: String, content: String, source: TaskSource) throws {
        // Map FileManager/FileHandle throws (disk full, permission, read-only volume) into a clean
        // TaskError at this IO boundary — like the calendar sink — so a raw NSError never reaches the
        // executor's fallback and dumps into the canvas (spec: "Errors are mapped at the boundary").
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = noteURL(for: project)
            let block = Self.entryBlock(content: content, source: source)
            let data = Data(block.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                // First write: create the file (atomic), seeding it with the block.
                try data.write(to: url, options: .atomic)
            }
        } catch {
            taskSinkLog.error("project note write failed: \(String(describing: error), privacy: .public)")
            throw TaskError.sinkFailed("Could not save the note to “\(project)”.")
        }
    }

    /// A safe, deterministic note filename for a project name (sanitized; never empty).
    func noteURL(for project: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: project))
    }

    static func fileName(for project: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(project.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "project" : cleaned
        return "\(base).md"
    }

    /// Pure: the appended block (content + source app/URL + timestamp). Unit-testable without disk.
    nonisolated static func entryBlock(content: String, source: TaskSource) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        var header = "## " + df.string(from: source.timestamp)
        var meta: [String] = []
        if let app = source.appName, !app.isEmpty { meta.append("from \(app)") }
        if let url = source.url { meta.append(url.absoluteString) }
        if !meta.isEmpty { header += " — " + meta.joined(separator: " · ") }
        return "\n\(header)\n\n\(content)\n"
    }
}

// MARK: - Production: tool opener

/// The production `ToolOpener`: writes the payload to a temp file and opens the target tool with it
/// via `NSWorkspace`/the launch mechanism (a bundle id, app path, or a `shortcuts run` for a named
/// Shortcut). Kept thin; the decision of HOW to open lives in `LaunchService` for real tools, this is
/// the task-side entry that hands off a payload file path.
@MainActor
final class WorkspaceToolOpener: ToolOpener {
    /// Injected so the AppKit `open` is testable/replaceable; defaults to opening via `NSWorkspace`.
    /// THROWS so a failed open is surfaced (not swallowed) — a tool that didn't actually open must
    /// produce a `.failed` state, never a false "Done" (spec: "Failure is never silent").
    private let openHandler: @MainActor (_ tool: String, _ payloadFile: URL) async throws -> Void

    init(openHandler: @escaping @MainActor (_ tool: String, _ payloadFile: URL) async throws -> Void = WorkspaceToolOpener.defaultOpen) {
        self.openHandler = openHandler
    }

    func open(tool: String, payload: String) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-payload-\(UUID().uuidString).txt")
        do {
            try Data(payload.utf8).write(to: file, options: .atomic)
        } catch {
            taskSinkLog.error("payload write failed: \(String(describing: error), privacy: .public)")
            throw TaskError.sinkFailed("Could not write the payload for “\(tool)”.")
        }
        try await openHandler(tool, file)
    }

    /// Default open: a named Shortcut runs via `shortcuts run`; an app id/path opens the payload file
    /// in that app. (Wired against the same primitives `LaunchService` uses.) Surfaces a real failure
    /// (launch error, non-zero exit) as `TaskError.sinkFailed` rather than discarding it.
    @MainActor
    static func defaultOpen(_ tool: String, _ payloadFile: URL) async throws {
        #if canImport(AppKit)
        if tool.contains("/") || tool.hasSuffix(".app") {
            // Treat as a bundle id or app path: open the payload file with that app. A bare dot
            // (e.g. a Shortcut named "My.Workflow") is NOT treated as an app path.
            try await openFile(payloadFile, withAppAt: URL(fileURLWithPath: tool))
        } else {
            // Treat as a named Shortcut: run it (the payload file path is available to it).
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", tool, "--input-path", payloadFile.path]
            do {
                try p.run()
            } catch {
                taskSinkLog.error("shortcuts run failed to launch: \(String(describing: error), privacy: .public)")
                throw TaskError.sinkFailed("Could not run “\(tool)”.")
            }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw TaskError.sinkFailed("“\(tool)” reported an error (exit code \(p.terminationStatus)).")
            }
        }
        #endif
    }
}

#if canImport(AppKit)
private extension WorkspaceToolOpener {
    /// Open `payloadFile` with the app at `appURL`, awaiting the result so a failed open is surfaced
    /// (the old fire-and-forget completion-handler form reported success unconditionally).
    static func openFile(_ payloadFile: URL, withAppAt appURL: URL) async throws {
        let config = NSWorkspace.OpenConfiguration()
        do {
            _ = try await NSWorkspace.shared.open([payloadFile], withApplicationAt: appURL,
                                                  configuration: config)
        } catch {
            taskSinkLog.error("NSWorkspace.open failed: \(String(describing: error), privacy: .public)")
            throw TaskError.sinkFailed("Could not open “\(appURL.lastPathComponent)”.")
        }
    }
}
#endif

// MARK: - Production: destination sender

/// The production `DestinationSender`: routes content to a `Destination` adapter — a named Shortcut
/// (`shortcuts run`), a URL scheme (content substituted into `{content}` / appended), or a shell-out
/// (content on stdin). Mirrors `LaunchService`'s subprocess pattern.
@MainActor
final class AdapterDestinationSender: DestinationSender {
    func send(_ destination: Destination, content: String) async throws {
        switch destination {
        case let .shortcut(name):
            try runProcess("/usr/bin/shortcuts", ["run", name], stdin: content)
        case let .urlScheme(template):
            #if canImport(AppKit)
            let urlString = Self.substitute(content, into: template)
            guard let url = URL(string: urlString) else {
                throw TaskError.sinkFailed("The destination URL was malformed.")
            }
            guard NSWorkspace.shared.open(url) else {
                throw TaskError.sinkFailed("Nothing could open the destination URL.")
            }
            #endif
        case let .shell(command):
            try runProcess("/bin/zsh", ["-c", command], stdin: content)
        }
    }

    /// Substitute the content into a URL-scheme template: replace `{content}` if present, else append
    /// it as a percent-encoded query-friendly suffix. Pure; unit-testable.
    nonisolated static func substitute(_ content: String, into template: String) -> String {
        let encoded = content.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? content
        if template.contains("{content}") {
            return template.replacingOccurrences(of: "{content}", with: encoded)
        }
        return template + encoded
    }

    private func runProcess(_ executable: String, _ args: [String], stdin: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardInput = pipe
        do {
            try p.run()
        } catch {
            taskSinkLog.error("destination adapter failed to launch: \(String(describing: error), privacy: .public)")
            throw TaskError.sinkFailed("Could not run the destination.")
        }
        // The child may exit before we finish writing, so a blocking `write` can raise a broken-pipe
        // failure — tolerate it (the adapter legitimately may not read stdin). The authoritative
        // success signal is the exit STATUS below, not whether stdin was fully delivered.
        if let data = stdin.data(using: .utf8) {
            do {
                try pipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                // Broken pipe / early exit: the input couldn't be delivered, but the process ran.
            }
        }
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        // A non-zero exit means the destination did NOT do its job — surface it, don't report "Done".
        if p.terminationStatus != 0 {
            throw TaskError.sinkFailed("The destination reported an error (exit code \(p.terminationStatus)).")
        }
    }
}
