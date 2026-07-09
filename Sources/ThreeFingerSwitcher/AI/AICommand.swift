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
    /// The current clipboard IMAGE — the live pasteboard image, normalized to PNG — fed to the vision
    /// model (requires a `.vision`-capable model). A distinct source from `.clipboard` (not a
    /// polymorphic text-or-image) so `requiredCapabilities` stays static. On-demand: copying an image
    /// never auto-fires; the user runs a `clipboardImage` command and it reads the clipboard image.
    case clipboardImage
    /// A captured screen region, fed to the vision model (requires a `.vision`-capable model).
    case screenRegion
    /// No input — the prompt template stands alone.
    case none
}

// MARK: - Task / destination targets (built in a later slice; modeled here behind the seam)

/// A side-effecting task the model's structured output is routed to (design D6). The concrete task
/// dispatch is a LATER slice; this slice only carries the kind and routes it to `TaskDispatching`.
enum TaskKind: Codable, Equatable, Hashable, Sendable {
    /// Create a calendar event from the parsed action (EventKit).
    case addToCalendar
    /// Create a reminder/to-do from the parsed action (EventKit reminders).
    case addToReminder
    /// Create a contact card from the parsed action (Contacts).
    case newContact
    /// Append the content to a named project note on disk.
    case saveToProject(project: String)
    /// Generate a payload and open a tool with it (by bundle id / tool name).
    case openToolWithPayload(tool: String)
    /// Route the content to a destination adapter (Shortcut / URL scheme / shell-out).
    case sendTo(Destination)
}

/// A delivery destination for a `sendTo` output / task (design D6). Concrete adapters are a LATER
/// slice; modeled here so commands round-trip and the dispatcher seam has a typed payload.
enum Destination: Codable, Equatable, Hashable, Sendable {
    /// Run a named Shortcuts.app shortcut, fed the content.
    case shortcut(name: String)
    /// Open a URL scheme, with the content substituted into it.
    case urlScheme(String)
    /// Shell out to a command, passing the content on stdin.
    case shell(command: String)
}

// MARK: - Output target

/// Where a command's result goes once committed (spec: "In-place output routing" + design D6).
enum OutputTarget: Codable, Equatable, Hashable, Sendable {
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

// MARK: - Reasoning override

/// An explicit per-command reasoning override (think-before-answering). `nil`/absent ⇒ the command
/// follows the global `aiReasoningEnabled` default; `.on`/`.off` pin it for this command regardless.
enum AIReasoning: String, Codable, Equatable, Sendable, CaseIterable {
    /// Force reasoning ON for this command.
    case on
    /// Force reasoning OFF for this command.
    case off
}

// MARK: - The command

/// One configured AI command. `Codable` (custom, for the legacy-scalar migration) so it persists as a
/// band item inside the `Favorites` record; `Identifiable` (by `id`) so the Bands editor and launcher
/// key on it.
///
/// The command stores *what it's allowed to do*, not *what to do* (change `ai-action-context-resolution`):
/// an **input capability set** (`inputs`) and an **output capability set** (`outputs`), each defaulting
/// all-on. At fire time the executor senses the live environment, activates the highest-priority enabled
/// input channel that is live (`selection ▸ clipboard ▸ clipboardImage`), and derives the commit from the
/// resolved channel (selection → replace, clipboard → paste, image → vision). Toggles are guardrails on
/// that automatic decision. An **empty** `inputs` set means "no input needed" (standalone prompt).
struct AICommand: Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var icon: ItemIcon
    var tint: ItemColor?
    /// The input channels this command MAY consume, resolved dynamically at fire (never a single fixed
    /// source). Empty = standalone prompt (no input). `screenRegion`, when present, makes the command
    /// region-first (the pre-canvas picker), exclusive of the ambient cascade (design D4).
    var inputs: Set<InputSource>
    var promptTemplate: String
    /// The output behaviors this command MAY perform. For an in-place command the commit is derived from
    /// the resolved input (selection→replace when `replaceSelection` on, else `pasteAtCursor`, else
    /// `previewOnly` writes nothing). A single side-effecting `runTask`/`sendTo` member routes through the
    /// accept-step/execute flow instead.
    var outputs: Set<OutputTarget>
    var model: ModelSelector
    /// Whether to show the action-review/confirmation step before committing. Defaults ON when the
    /// outputs contain a side-effecting task/send-to at creation, but the stored value is HONORED thereafter.
    var confirmBeforeRun: Bool
    /// An optional fire-time parameter chosen in the canvas rather than baked into the template
    /// (v1: a target language resolved into `{lang}`). `nil` ⇒ no parameter UI; the command behaves
    /// exactly as before. Optional so old persisted commands (no key) decode with it absent.
    var runtimeParameter: RuntimeParameter?
    /// An explicit per-command reasoning override. `nil` ⇒ follow the global `aiReasoningEnabled`
    /// default; `.on`/`.off` pin it for this command. Optional so old persisted commands (no key)
    /// decode with it absent.
    var reasoning: AIReasoning?

    /// The default input capability set for a freshly created command: the ambient text/image cascade
    /// (screen region is opt-in per command, since it needs the pre-canvas picker).
    static let defaultInputs: Set<InputSource> = [.selection, .clipboard, .clipboardImage]
    /// The default in-place output capability set for a freshly created command: all three on.
    static let defaultOutputs: Set<OutputTarget> = [.replaceSelection, .pasteAtCursor, .previewOnly]

    /// Designated initializer (capability sets). When `confirmBeforeRun` is left `nil`, it is DERIVED
    /// from the outputs (true when they contain a side-effecting task/send-to). An explicit value is
    /// taken verbatim, so a stored `false` survives — the default is computed only at creation.
    init(id: UUID = UUID(),
         name: String,
         icon: ItemIcon,
         tint: ItemColor? = nil,
         inputs: Set<InputSource>,
         promptTemplate: String,
         outputs: Set<OutputTarget>,
         model: ModelSelector = .default,
         confirmBeforeRun: Bool? = nil,
         runtimeParameter: RuntimeParameter? = nil,
         reasoning: AIReasoning? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tint = tint
        self.inputs = inputs
        self.promptTemplate = promptTemplate
        self.outputs = outputs
        self.model = model
        self.confirmBeforeRun = confirmBeforeRun ?? Self.defaultConfirmBeforeRun(for: outputs)
        self.runtimeParameter = runtimeParameter
        self.reasoning = reasoning
    }

    /// Legacy convenience initializer (a single `input`/`output`), mapped to the capability sets via the
    /// same behavior-preserving migration used on decode (design D5). Keeps the catalog, seeding, and
    /// tests authoring commands in the old terse form while the model underneath is set-shaped.
    init(id: UUID = UUID(),
         name: String,
         icon: ItemIcon,
         tint: ItemColor? = nil,
         input: InputSource,
         promptTemplate: String,
         output: OutputTarget,
         model: ModelSelector = .default,
         confirmBeforeRun: Bool? = nil,
         runtimeParameter: RuntimeParameter? = nil,
         reasoning: AIReasoning? = nil) {
        self.init(id: id, name: name, icon: icon, tint: tint,
                  inputs: Self.migrate(input: input), promptTemplate: promptTemplate,
                  outputs: Self.migrate(output: output), model: model,
                  confirmBeforeRun: confirmBeforeRun, runtimeParameter: runtimeParameter,
                  reasoning: reasoning)
    }

    // MARK: - Legacy → set migration (design D5)

    /// Map a legacy single input source to its capability set, behavior-preservingly: `selection` gains
    /// the clipboard fallback it always had (now explicit + honest — it pastes, not replaces); `none`
    /// becomes the empty (standalone) set.
    static func migrate(input: InputSource) -> Set<InputSource> {
        switch input {
        case .selection:      return [.selection, .clipboard]
        case .clipboard:      return [.clipboard]
        case .clipboardImage: return [.clipboardImage]
        case .screenRegion:   return [.screenRegion]
        case .none:           return []
        }
    }

    /// Map a legacy single output target to its capability set: `replaceSelection` gains `pasteAtCursor`
    /// so a no-selection fire pastes rather than fails; everything else is its singleton.
    static func migrate(output: OutputTarget) -> Set<OutputTarget> {
        switch output {
        case .replaceSelection: return [.replaceSelection, .pasteAtCursor]
        case .pasteAtCursor:    return [.pasteAtCursor]
        case .previewOnly:      return [.previewOnly]
        case let .runTask(k):   return [.runTask(k)]
        case let .sendTo(d):    return [.sendTo(d)]
        }
    }

    /// The DEFAULT `confirmBeforeRun` for a set of outputs, used ONLY at command creation: true when the
    /// outputs contain a side-effecting task/send-to. The stored value is honored at run time thereafter.
    static func defaultConfirmBeforeRun(for outputs: Set<OutputTarget>) -> Bool {
        outputs.contains { $0.isSideEffecting }
    }

    /// Resolve whether this command should reason: an explicit `.on`/`.off` override wins; an absent
    /// override (`nil`) follows the global `aiReasoningEnabled` default passed in.
    func resolvedReasoning(globalDefault: Bool) -> Bool {
        switch reasoning {
        case .on: return true
        case .off: return false
        case nil: return globalDefault
        }
    }

    // MARK: - Derived queries

    /// Whether this command requires input before the model may run. An empty `inputs` set = a standalone
    /// prompt that needs nothing; a non-empty set with no live channel surfaces "no input".
    var needsInput: Bool { !inputs.isEmpty }

    /// The single side-effecting output (task / send-to), if this is a side-effecting command; else nil
    /// (an in-place command). Only one such member is meaningful; the first is taken.
    var sideEffect: OutputTarget? { outputs.first { $0.isSideEffecting } }

    /// Whether this is a side-effecting command (its outputs carry a task/send-to).
    var isSideEffecting: Bool { sideEffect != nil }

    /// The **potential** model capabilities this command could need — the UNION over its enabled inputs
    /// (`vision` when any enabled input is an image source, `text` otherwise; `text` when standalone).
    /// This is an INFORMATIONAL hint only (e.g. the editor): the model actually requested is derived from
    /// the input RESOLVED at fire time, not this union (change `ai-action-context-resolution`, design D3).
    var requiredCapabilities: Set<Modality> {
        var caps: Set<Modality> = []
        if inputs.contains(where: { $0 == .clipboardImage || $0 == .screenRegion }) { caps.insert(.vision) }
        if inputs.contains(where: { $0 == .selection || $0 == .clipboard }) { caps.insert(.text) }
        if caps.isEmpty { caps.insert(.text) }   // standalone / empty ⇒ text
        return caps
    }

    // MARK: - In-place commit resolution (pure; unit-tested + used by the executor)

    /// The in-place commit action resolved from the fire (side-effecting outputs are handled separately).
    enum CommitPlan: Equatable, Sendable {
        /// Replace the front app's selection (SelectionService pastes if it isn't settable / is empty).
        case replaceSelection
        /// Paste the result at the insertion point.
        case pasteAtCursor
        /// Write nothing (preview-only / read-only understanding command).
        case preview
    }

    /// Pure resolution of the in-place commit from the resolved input channel + enabled outputs
    /// (design D2): a selection input with `replaceSelection` enabled replaces; else `pasteAtCursor`
    /// pastes; else a lone `replaceSelection` still replaces (SelectionService pastes when no live
    /// selection); else nothing is written.
    static func inPlaceCommitPlan(resolvedWasSelection: Bool, outputs: Set<OutputTarget>) -> CommitPlan {
        if resolvedWasSelection && outputs.contains(.replaceSelection) { return .replaceSelection }
        if outputs.contains(.pasteAtCursor) { return .pasteAtCursor }
        if outputs.contains(.replaceSelection) { return .replaceSelection }
        return .preview
    }
}

// MARK: - Codable (custom: migrates legacy single `input`/`output` scalars into the sets, design D5)

extension AICommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, icon, tint
        case inputs, promptTemplate, outputs, model, confirmBeforeRun, runtimeParameter, reasoning
        case input, output   // legacy scalar keys (decode-only fallback)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(ItemIcon.self, forKey: .icon)
        tint = try c.decodeIfPresent(ItemColor.self, forKey: .tint)
        promptTemplate = try c.decode(String.self, forKey: .promptTemplate)
        model = try c.decodeIfPresent(ModelSelector.self, forKey: .model) ?? .default
        runtimeParameter = try c.decodeIfPresent(RuntimeParameter.self, forKey: .runtimeParameter)
        reasoning = try c.decodeIfPresent(AIReasoning.self, forKey: .reasoning)

        // inputs: prefer the new set; else migrate a legacy scalar; else the all-on default.
        if let ins = try c.decodeIfPresent(Set<InputSource>.self, forKey: .inputs) {
            inputs = ins
        } else if let legacy = try c.decodeIfPresent(InputSource.self, forKey: .input) {
            inputs = AICommand.migrate(input: legacy)
        } else {
            inputs = AICommand.defaultInputs
        }

        // outputs: prefer the new set; else migrate a legacy scalar; else the all-on default.
        if let outs = try c.decodeIfPresent(Set<OutputTarget>.self, forKey: .outputs) {
            outputs = outs
        } else if let legacy = try c.decodeIfPresent(OutputTarget.self, forKey: .output) {
            outputs = AICommand.migrate(output: legacy)
        } else {
            outputs = AICommand.defaultOutputs
        }

        // confirmBeforeRun: honor the stored value; derive from the outputs when absent (never overridden).
        confirmBeforeRun = try c.decodeIfPresent(Bool.self, forKey: .confirmBeforeRun)
            ?? AICommand.defaultConfirmBeforeRun(for: outputs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(promptTemplate, forKey: .promptTemplate)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(model, forKey: .model)
        try c.encode(confirmBeforeRun, forKey: .confirmBeforeRun)
        try c.encodeIfPresent(runtimeParameter, forKey: .runtimeParameter)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
    }
}
