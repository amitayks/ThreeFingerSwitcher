import Foundation

/// A resolved window target for the computer-use tools: produced by the coordinator's resolver over
/// the SWITCHER'S OWN enumeration (`WindowService.snapshot()` matching) — the tools never enumerate
/// windows themselves (switcher-as-API, design D6).
public struct ComputerUseWindowTarget: Equatable, Sendable {
    public var pid: pid_t
    public var title: String
    public var appName: String
    public init(pid: pid_t, title: String, appName: String) {
        self.pid = pid
        self.title = title
        self.appName = appName
    }
}

/// The computer-use tools (`add-voice-computer-use-agent`, design D6): `read_window` /
/// `focus_window` (.auto) + `click_element` / `type_text` (.confirm, auto-mode liftable via the
/// gate). AX-first, constrained element IDs only — the schemas contain NO coordinate parameter, and
/// an unresolvable target is a clean failure, never a guess. Acts run inside the arbiter's acting
/// scope (human-touch kill switch + tagged synthetic input) and verify-after-act.
struct ComputerUseToolContributor: ToolContributor {

    /// Live opt-in (thread-safe read — the registry re-queries per turn, so toggling is immediate).
    let enabled: @Sendable () -> Bool
    /// Resolve app/title hints against the switcher's enumeration (main-actor).
    let resolveWindow: @MainActor (String?, String?) -> ComputerUseWindowTarget?
    /// Raise through the EXISTING hardened commit path (`raiseCommitted` — the third caller).
    let focusWindow: @MainActor (ComputerUseWindowTarget) -> Bool
    let performer: AXActionPerformer
    let arbiter: AgentActionArbiter
    /// Narration hook: spoken when voice is active, always visible (spec: silence never hides an act).
    let narrate: @MainActor (String) -> Void

    // MARK: - Descriptors

    static let readWindowName = "read_window"
    static let focusWindowName = "focus_window"
    static let clickElementName = "click_element"
    static let typeTextName = "type_text"

    private static let windowArgs = """
    {"type":"object","properties":{"app":{"type":"string","description":"App name (fuzzy)"},\
    "title":{"type":"string","description":"Window title hint (optional)"}}}
    """
    private static let clickArgs = """
    {"type":"object","required":["element_id"],"properties":{"app":{"type":"string"},\
    "title":{"type":"string"},"element_id":{"type":"string","description":"An id from read_window"}}}
    """
    private static let typeArgs = """
    {"type":"object","required":["text"],"properties":{"app":{"type":"string"},"title":{"type":"string"},\
    "element_id":{"type":"string"},"text":{"type":"string"},"submit":{"type":"boolean"}}}
    """

    func descriptors() -> [ToolDescriptor] {
        guard enabled() else { return [] }   // off = ABSENT (spec: "Off means absent")
        return [
            ToolDescriptor(name: Self.readWindowName,
                           summary: "Read a window's visible text and interactive elements (accessibility, no screenshot).",
                           argsSchema: StructuredSchema(name: Self.readWindowName, json: Self.windowArgs),
                           writePolicy: .auto,
                           keywords: ["read", "window", "screen", "look", "see", "text", "terminal", "content"]),
            ToolDescriptor(name: Self.focusWindowName,
                           summary: "Bring an app's window to the front (the switcher's own raise).",
                           argsSchema: StructuredSchema(name: Self.focusWindowName, json: Self.windowArgs),
                           writePolicy: .auto,
                           keywords: ["focus", "switch", "window", "front", "go", "open", "move"]),
            ToolDescriptor(name: Self.clickElementName,
                           summary: "Press a button/link in a window, by an element id from read_window.",
                           argsSchema: StructuredSchema(name: Self.clickElementName, json: Self.clickArgs),
                           writePolicy: .confirm,
                           keywords: ["click", "press", "button", "tap", "select"]),
            ToolDescriptor(name: Self.typeTextName,
                           summary: "Type text into a window (optionally into a specific field, optionally press Return).",
                           argsSchema: StructuredSchema(name: Self.typeTextName, json: Self.typeArgs),
                           writePolicy: .confirm,
                           keywords: ["type", "write", "enter", "send", "reply", "input", "text"]),
        ]
    }

    func canHandle(_ tool: String) -> Bool {
        [Self.readWindowName, Self.focusWindowName, Self.clickElementName, Self.typeTextName]
            .contains(tool)
    }

    // MARK: - Args

    private struct Args: Decodable {
        var app: String?
        var title: String?
        var element_id: String?
        var text: String?
        var submit: Bool?
    }

    private func parseArgs(_ json: String) -> Args {
        guard let data = json.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else { return Args() }
        return args
    }

    // MARK: - Run

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        guard enabled() else {
            return ToolStepResult(tool: call.descriptor.name,
                                  status: .failed(headline: "Computer use is turned off."),
                                  summary: "Computer use is turned off.")
        }
        let args = parseArgs(call.route.argumentsJSON)
        let tool = call.descriptor.name

        guard let target = await resolveTarget(args) else {
            let headline = "Couldn't find that window."
            return ToolStepResult(tool: tool, status: .failed(headline: headline),
                                  summary: "\(headline) Asked for app “\(args.app ?? "frontmost")”.")
        }

        do {
            switch tool {
            case Self.readWindowName:
                return try await readWindow(target)
            case Self.focusWindowName:
                return await focusWindowStep(target)
            case Self.clickElementName:
                return try await clickElement(target, args: args, gate: gate, call: call)
            case Self.typeTextName:
                return try await typeText(target, args: args, gate: gate, call: call)
            default:
                return ToolStepResult(tool: tool, status: .failed(headline: "That tool isn't available."),
                                      summary: "Unknown tool: \(tool).")
            }
        } catch {
            let presented = AIError.message(for: error)
            return ToolStepResult(tool: tool, status: .failed(headline: presented.headline),
                                  summary: presented.headline)
        }
    }

    private func resolveTarget(_ args: Args) async -> ComputerUseWindowTarget? {
        await MainActor.run { resolveWindow(args.app, args.title) }
    }

    // MARK: - The four tools

    private func readWindow(_ target: ComputerUseWindowTarget) async throws -> ToolStepResult {
        let snapshot = try await performer.snapshot(pid: target.pid, titleHint: target.title)
        var lines: [String] = []
        lines.append("Window: \(snapshot.appName) — “\(snapshot.title)”\(snapshot.truncated ? " (content truncated)" : "")")
        let text = snapshot.joinedText
        if !text.isEmpty {
            lines.append("Text:\n\(String(text.prefix(4_000)))")
        }
        if !snapshot.elements.isEmpty {
            lines.append("Interactive elements (use these ids with click_element/type_text):")
            for element in snapshot.elements.prefix(60) {
                let label = element.label.isEmpty ? element.valuePreview : element.label
                lines.append("- [\(element.id)] \(element.role) “\(String(label.prefix(60)))”")
            }
        }
        return ToolStepResult(tool: Self.readWindowName, status: .done,
                              summary: lines.joined(separator: "\n"))
    }

    private func focusWindowStep(_ target: ComputerUseWindowTarget) async -> ToolStepResult {
        let raised = await MainActor.run { focusWindow(target) }
        if raised {
            return ToolStepResult(tool: Self.focusWindowName, status: .done,
                                  summary: "Focused \(target.appName) — “\(target.title)”.")
        }
        return ToolStepResult(tool: Self.focusWindowName,
                              status: .failed(headline: "Couldn't raise that window."),
                              summary: "Couldn't raise \(target.appName) — “\(target.title)”.")
    }

    private func clickElement(_ target: ComputerUseWindowTarget, args: Args,
                              gate: ApprovalGate, call: RoutedCall) async throws -> ToolStepResult {
        guard let elementID = args.element_id else {
            return ToolStepResult(tool: Self.clickElementName,
                                  status: .failed(headline: "No element was named."),
                                  summary: "click_element needs an element_id from read_window.")
        }
        let review = TaskReview.action(
            title: "Click in \(target.appName)",
            fields: [ReviewField("Window", target.title),
                     ReviewField("Element", elementID)],
            payload: .openTool(tool: Self.clickElementName,
                               action: ParsedOpenTool(applicable: true, reason: nil, payload: elementID)))
        switch await gate.awaitDecision(for: review) {
        case .approve:
            let verification = try await arbiter.acting {
                try await performer.press(pid: target.pid, titleHint: target.title, elementID: elementID)
            }
            let summary = "Clicked in \(target.appName): \(verification.detail)."
            await MainActor.run { narrate(summary) }
            return ToolStepResult(tool: Self.clickElementName, status: .done, summary: summary)
        case .skip:
            return ToolStepResult(tool: Self.clickElementName, status: .declined(reason: "skipped"),
                                  summary: "Skipped the click.")
        case .cancel:
            return ToolStepResult(tool: Self.clickElementName,
                                  status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                  summary: "Cancelled.")
        }
    }

    private func typeText(_ target: ComputerUseWindowTarget, args: Args,
                          gate: ApprovalGate, call: RoutedCall) async throws -> ToolStepResult {
        guard let text = args.text, !text.isEmpty else {
            return ToolStepResult(tool: Self.typeTextName,
                                  status: .failed(headline: "There's no text to type."),
                                  summary: "type_text needs non-empty text.")
        }
        let submit = args.submit ?? false
        let review = TaskReview.action(
            title: "Type in \(target.appName)",
            fields: [ReviewField("Window", target.title),
                     ReviewField("Text", String(text.prefix(200))),
                     ReviewField("Press Return", submit ? "yes" : "no")],
            payload: .openTool(tool: Self.typeTextName,
                               action: ParsedOpenTool(applicable: true, reason: nil, payload: text)))
        switch await gate.awaitDecision(for: review) {
        case .approve:
            // Assert focus first so the text lands where the preview said it would.
            _ = await MainActor.run { focusWindow(target) }
            let verification = try await arbiter.acting {
                try await performer.typeText(pid: target.pid, titleHint: target.title,
                                             elementID: args.element_id, text: text, submit: submit)
            }
            let summary = "Typed into \(target.appName)\(submit ? " and pressed Return" : ""): \(verification.detail)."
            await MainActor.run { narrate(summary) }
            return ToolStepResult(tool: Self.typeTextName, status: .done, summary: summary)
        case .skip:
            return ToolStepResult(tool: Self.typeTextName, status: .declined(reason: "skipped"),
                                  summary: "Skipped typing.")
        case .cancel:
            return ToolStepResult(tool: Self.typeTextName,
                                  status: .declined(reason: TaskKindToolContributor.cancelledReason),
                                  summary: "Cancelled.")
        }
    }
}
