import Foundation

/// The value model for one AI command (spec: "AI command value model and persistence", design D5).
///
/// An `AICommand` is *configuration*, not a Favorites item: it describes how to acquire input, what
/// prompt to run it through, and where the model's output goes. It is a pure value type with no
/// AppKit/SwiftUI dependency, reusing the launcher's `ItemIcon` / `ItemColor` so it renders in the
/// same icon grid (the synthetic AI band is projected from these on launcher open — a later slice).
///
/// `confirmBeforeRun` DEFAULTS to true for side-effecting outputs (task / send-to) at creation time
/// — but the STORED value is always honored at run time and never force-overridden (design D6): a
/// user may turn confirmation off for a trusted task.

// MARK: - Input source

/// Where a command's input text (or image) comes from at fire time.
enum InputSource: String, Codable, Equatable, Sendable, CaseIterable {
    /// The front app's currently selected text (with a clipboard fallback when empty).
    case selection
    /// The current clipboard contents.
    case clipboard
    /// A captured screen region, fed to the vision model (requires a `.vision`-capable model).
    case screenRegion
    /// No input — the prompt template stands alone.
    case none
}

// MARK: - Task / destination targets (built in a later slice; modeled here behind the seam)

/// A side-effecting task the model's structured output is routed to (design D6). The concrete task
/// dispatch is a LATER slice; this slice only carries the kind and routes it to `TaskDispatching`.
enum TaskKind: Codable, Equatable, Sendable {
    /// Create a calendar event from the parsed action (EventKit).
    case addToCalendar
    /// Append the content to a named project note on disk.
    case saveToProject(project: String)
    /// Generate a payload and open a tool with it (by bundle id / tool name).
    case openToolWithPayload(tool: String)
    /// Route the content to a destination adapter (Shortcut / URL scheme / shell-out).
    case sendTo(Destination)
}

/// A delivery destination for a `sendTo` output / task (design D6). Concrete adapters are a LATER
/// slice; modeled here so commands round-trip and the dispatcher seam has a typed payload.
enum Destination: Codable, Equatable, Sendable {
    /// Run a named Shortcuts.app shortcut, fed the content.
    case shortcut(name: String)
    /// Open a URL scheme, with the content substituted into it.
    case urlScheme(String)
    /// Shell out to a command, passing the content on stdin.
    case shell(command: String)
}

// MARK: - Output target

/// Where a command's result goes once committed (spec: "In-place output routing" + design D6).
enum OutputTarget: Codable, Equatable, Sendable {
    /// Replace the front app's selected text with the result.
    case replaceSelection
    /// Paste the result at the insertion point.
    case pasteAtCursor
    /// Show the result in the preview canvas only; write nothing into the app.
    case previewOnly
    /// Route a schema-targeted structured result to a side-effecting task.
    case runTask(TaskKind)
    /// Route the result to a destination adapter.
    case sendTo(Destination)

    /// Whether committing this output has an irreversible side effect outside the front app's text —
    /// the set for which `confirmBeforeRun` defaults ON (task / send-to).
    var isSideEffecting: Bool {
        switch self {
        case .runTask, .sendTo: return true
        case .replaceSelection, .pasteAtCursor, .previewOnly: return false
        }
    }
}

// MARK: - Model selector

/// Which model a command runs on. v1 ships only on-device Gemma 4; `cloud` is RESERVED behind the
/// same seam (a later, consent-gated alternate — design D1/non-goals) so a command can round-trip a
/// future cloud choice without a model-layer change.
enum ModelSelector: Codable, Equatable, Sendable {
    /// On-device Gemma 4. `modelID == nil` means "the registry default"; a non-nil id pins a model.
    case onDevice(modelID: String?)
    /// RESERVED: a named cloud model (not served in v1).
    case cloud(provider: String, model: String)

    /// The default selector for a freshly-created command: on-device, registry default model.
    static let `default` = ModelSelector.onDevice(modelID: nil)
}

// MARK: - The command

/// One configured AI command. `Codable` so it persists as a band item inside the `Favorites` record
/// (configuration-hub fold-in); `Identifiable` (by `id`) so the Bands editor and the launcher key on it.
struct AICommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var icon: ItemIcon
    var tint: ItemColor?
    var input: InputSource
    var promptTemplate: String
    var output: OutputTarget
    var model: ModelSelector
    /// Whether to show the action-review/confirmation step before committing. Defaults ON for
    /// side-effecting outputs at creation (see `init`), but the stored value is HONORED thereafter.
    var confirmBeforeRun: Bool

    /// Designated initializer. When `confirmBeforeRun` is left `nil`, it is DERIVED from the output
    /// (true for side-effecting task/send-to, false otherwise). An explicit value is taken verbatim,
    /// so a stored `false` survives — the default is computed only at creation, never re-imposed.
    init(id: UUID = UUID(),
         name: String,
         icon: ItemIcon,
         tint: ItemColor? = nil,
         input: InputSource,
         promptTemplate: String,
         output: OutputTarget,
         model: ModelSelector = .default,
         confirmBeforeRun: Bool? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tint = tint
        self.input = input
        self.promptTemplate = promptTemplate
        self.output = output
        self.model = model
        self.confirmBeforeRun = confirmBeforeRun ?? Self.defaultConfirmBeforeRun(for: output)
    }

    /// The DEFAULT `confirmBeforeRun` for a given output, used ONLY at command creation: true for
    /// side-effecting outputs (task / send-to), false for in-place ones. The stored value is honored
    /// at run time and never recomputed from this (design D6).
    static func defaultConfirmBeforeRun(for output: OutputTarget) -> Bool {
        output.isSideEffecting
    }

    /// The runtime capabilities this command needs (drives capability-based model selection in the
    /// executor): a `screenRegion` input requires a `.vision` model; everything else is `.text`.
    var requiredCapabilities: Set<Modality> {
        switch input {
        case .screenRegion: return [.vision]
        case .selection, .clipboard, .none: return [.text]
        }
    }
}
