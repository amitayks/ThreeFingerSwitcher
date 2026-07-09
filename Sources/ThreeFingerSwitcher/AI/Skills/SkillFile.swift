import Foundation

/// Parse / serialize a `.skill.md` file (design D1) — a front-matter block delimited by `---`, then a
/// markdown body that IS the prompt template. The sink (`OutputTarget`) is encoded as a flat,
/// colon-tagged string (e.g. `runTask:saveToProject:Inbox`, `sendTo:shortcut:My Shortcut`) — simpler and
/// more round-trip-stable than nested YAML (the front-matter grammar was an open question; this is the
/// chosen hand-rolled subset). Parse failures map at the boundary into `SkillError` (the store wraps them
/// into a bounded `SkillProblem`). MLX-free Core.
enum SkillFile {

    /// Parse a `.skill.md` document into a `SkillManifest` (origin `.user` — built-ins are projected from
    /// the catalog, not parsed). Returns a typed `SkillError` on any malformation.
    static func parse(_ text: String, origin: SkillOrigin = .user) -> Result<SkillManifest, SkillError> {
        guard let (frontMatter, body) = splitFrontMatter(text) else {
            return .failure(.malformedFrontMatter(detail: "Missing the `---` front-matter delimiters."))
        }
        let fields = parseFields(frontMatter)

        guard let id = fields["id"], !id.isEmpty else { return .failure(.missingRequiredField(name: "id")) }
        guard let title = fields["title"], !title.isEmpty else { return .failure(.missingRequiredField(name: "title")) }
        guard let summary = fields["summary"], !summary.isEmpty else { return .failure(.missingRequiredField(name: "summary")) }
        // Inputs / outputs are capability SETS (change `ai-action-context-resolution`): the new
        // comma-joined `inputs:`/`outputs:` fields, falling back to a legacy single `input:`/`output:`
        // line (migrated into the set), so pre-existing `.skill.md` files still parse.
        let inputs: Set<InputSource>
        switch parseInputSet(new: fields["inputs"], legacy: fields["input"]) {
        case let .success(set): inputs = set
        case let .failure(err): return .failure(err)
        }
        let outputs: Set<OutputTarget>
        switch parseOutputSet(new: fields["outputs"], legacy: fields["output"]) {
        case let .success(set): outputs = set
        case let .failure(err): return .failure(err)
        }

        let confirm = fields["confirmBeforeRun"].flatMap { Bool($0) }
        let reasoning: AIReasoning?
        switch fields["reasoning"] {
        case nil, "null": reasoning = nil
        case "on": reasoning = .on
        case "off": reasoning = .off
        case let other?: return .failure(.unknownEnumValue(field: "reasoning", value: other))
        }
        let runtimeParameter = parseRuntimeParameter(fields["runtimeParameter"])

        let command = AICommand(
            name: title,
            icon: parseIcon(fields["icon"]),
            tint: parseTint(fields["tint"]),
            inputs: inputs,
            promptTemplate: body,
            outputs: outputs,
            confirmBeforeRun: confirm,
            runtimeParameter: runtimeParameter,
            reasoning: reasoning)

        let manifest = SkillManifest(
            id: id, origin: origin, title: title, summary: summary,
            keywords: parseList(fields["keywords"]),
            category: fields["category"],
            command: command,
            toolNames: parseList(fields["tools"]),
            claudeHandoff: parseHandoff(fields["claudeHandoff"]))
        return .success(manifest)
    }

    /// Serialize a manifest back to `.skill.md` text. `parse(serialize(m))` is a fixed point for
    /// parsed-origin values (round-trip stable).
    static func serialize(_ m: SkillManifest) -> String {
        var lines = ["---"]
        lines.append("id: \(m.id)")
        lines.append("title: \(m.title)")
        lines.append("summary: \(m.summary)")
        if !m.keywords.isEmpty { lines.append("keywords: [\(m.keywords.joined(separator: ", "))]") }
        if let category = m.category { lines.append("category: \(category)") }
        lines.append("icon: \(serializeIcon(m.command.icon))")
        if let tint = m.command.tint { lines.append("tint: \(serializeTint(tint))") }
        lines.append("inputs: \(serializeInputs(m.command.inputs))")
        lines.append("outputs: \(serializeOutputs(m.command.outputs))")
        lines.append("confirmBeforeRun: \(m.command.confirmBeforeRun)")
        if let rp = serializeRuntimeParameter(m.command.runtimeParameter) { lines.append("runtimeParameter: \(rp)") }
        if let r = m.command.reasoning { lines.append("reasoning: \(r.rawValue)") }
        if !m.toolNames.isEmpty { lines.append("tools: [\(m.toolNames.joined(separator: ", "))]") }
        if let h = serializeHandoff(m.claudeHandoff) { lines.append("claudeHandoff: \(h)") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + m.command.promptTemplate
    }

    // MARK: - Front-matter splitting + field parsing

    private static func splitFrontMatter(_ text: String) -> (frontMatter: [String], body: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let firstDelim = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let rest = lines[(firstDelim + 1)...]
        guard let closeOffset = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let fm = Array(lines[(firstDelim + 1)..<closeOffset])
        let body = lines[(closeOffset + 1)...].joined(separator: "\n")
        return (fm, body.trimmingCharacters(in: .newlines))
    }

    private static func parseFields(_ lines: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    private static func parseList(_ value: String?) -> [String] {
        guard let value, value.hasPrefix("["), value.hasSuffix("]") else { return [] }
        return value.dropFirst().dropLast()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Enum / sink encodings

    static func parseOutput(_ value: String) -> OutputTarget? {
        switch value {
        case "replaceSelection": return .replaceSelection
        case "pasteAtCursor": return .pasteAtCursor
        case "previewOnly": return .previewOnly
        default: break
        }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let (head, rest) = (parts[0], parts[1])
        if head == "runTask" {
            let kindParts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            switch kindParts[0] {
            case "addToCalendar": return .runTask(.addToCalendar)
            case "addToReminder": return .runTask(.addToReminder)
            case "newContact": return .runTask(.newContact)
            case "saveToProject" where kindParts.count == 2: return .runTask(.saveToProject(project: kindParts[1]))
            case "openToolWithPayload" where kindParts.count == 2: return .runTask(.openToolWithPayload(tool: kindParts[1]))
            default: return nil
            }
        }
        if head == "sendTo" {
            let d = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard d.count == 2 else { return nil }
            switch d[0] {
            case "shortcut": return .sendTo(.shortcut(name: d[1]))
            case "urlScheme": return .sendTo(.urlScheme(d[1]))
            case "shell": return .sendTo(.shell(command: d[1]))
            default: return nil
            }
        }
        return nil
    }

    static func serializeOutput(_ output: OutputTarget) -> String {
        switch output {
        case .replaceSelection: return "replaceSelection"
        case .pasteAtCursor: return "pasteAtCursor"
        case .previewOnly: return "previewOnly"
        case let .runTask(kind):
            switch kind {
            case .addToCalendar: return "runTask:addToCalendar"
            case .addToReminder: return "runTask:addToReminder"
            case .newContact: return "runTask:newContact"
            case let .saveToProject(project): return "runTask:saveToProject:\(project)"
            case let .openToolWithPayload(tool): return "runTask:openToolWithPayload:\(tool)"
            case let .sendTo(dest): return "sendTo:\(serializeDestination(dest))"   // nested sendTo task
            }
        case let .sendTo(dest): return "sendTo:\(serializeDestination(dest))"
        }
    }

    private static func serializeDestination(_ d: Destination) -> String {
        switch d {
        case let .shortcut(name): return "shortcut:\(name)"
        case let .urlScheme(scheme): return "urlScheme:\(scheme)"
        case let .shell(command): return "shell:\(command)"
        }
    }

    // MARK: - Capability-set encodings (change `ai-action-context-resolution`)

    /// Parse the input capability set: the new comma-joined `inputs:` (raw `InputSource` values), else a
    /// legacy single `input:` line migrated into its set. An empty `inputs:` value is a valid empty
    /// (standalone) set; neither field present is a missing-field error.
    static func parseInputSet(new: String?, legacy: String?) -> Result<Set<InputSource>, SkillError> {
        if let new {
            var set: Set<InputSource> = []
            for raw in tokens(new) {
                guard let s = InputSource(rawValue: raw) else {
                    return .failure(.unknownEnumValue(field: "inputs", value: raw))
                }
                set.insert(s)
            }
            return .success(set)
        }
        if let legacy {
            guard let s = InputSource(rawValue: legacy) else {
                return .failure(.unknownEnumValue(field: "input", value: legacy))
            }
            return .success(AICommand.migrate(input: s))
        }
        return .failure(.missingRequiredField(name: "inputs"))
    }

    /// Parse the output capability set: the new `outputs:` value — tried FIRST as a single output (a
    /// side-effecting encoding carries internal `:`/`,`), else a comma list of simple in-place tokens —
    /// else a legacy single `output:` line migrated into its set. Must resolve to a non-empty set.
    static func parseOutputSet(new: String?, legacy: String?) -> Result<Set<OutputTarget>, SkillError> {
        if let new {
            if let single = parseOutput(new) { return .success([single]) }   // side-effecting / lone token
            var set: Set<OutputTarget> = []
            for tok in tokens(new) {
                guard let o = parseOutput(tok) else {
                    return .failure(.unknownEnumValue(field: "outputs", value: tok))
                }
                set.insert(o)
            }
            guard !set.isEmpty else { return .failure(.missingRequiredField(name: "outputs")) }
            return .success(set)
        }
        if let legacy {
            guard let o = parseOutput(legacy) else {
                return .failure(.unknownEnumValue(field: "output", value: legacy))
            }
            return .success(AICommand.migrate(output: o))
        }
        return .failure(.missingRequiredField(name: "outputs"))
    }

    /// Serialize the input set as a deterministic comma-joined list of raw values (empty set ⇒ "").
    static func serializeInputs(_ inputs: Set<InputSource>) -> String {
        inputs.map(\.rawValue).sorted().joined(separator: ", ")
    }

    /// Serialize the output set as a deterministic comma-joined list of `serializeOutput` tokens (a lone
    /// side-effecting output serializes to just itself, so `parseOutputSet`'s single-value path round-trips).
    static func serializeOutputs(_ outputs: Set<OutputTarget>) -> String {
        outputs.map(serializeOutput).sorted().joined(separator: ", ")
    }

    /// Split a comma-separated field value into trimmed, non-empty tokens.
    private static func tokens(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func parseIcon(_ value: String?) -> ItemIcon {
        guard let value, !value.isEmpty else { return .sfSymbol("sparkles") }
        if value == "appDefault" { return .appDefault }
        if value == "fileIcon" { return .fileIcon }
        if value.hasPrefix("emoji:") { return .emoji(String(value.dropFirst("emoji:".count))) }
        return .sfSymbol(value)
    }

    private static func serializeIcon(_ icon: ItemIcon) -> String {
        switch icon {
        case .appDefault: return "appDefault"
        case .fileIcon: return "fileIcon"
        case let .sfSymbol(name): return name
        case let .emoji(e): return "emoji:\(e)"
        }
    }

    private static func parseTint(_ value: String?) -> ItemColor? {
        guard let value, value.hasPrefix("#"), value.count == 7 else { return nil }
        let hex = value.dropFirst()
        guard let n = Int(hex, radix: 16) else { return nil }
        return ItemColor(red: Double((n >> 16) & 0xFF) / 255.0,
                         green: Double((n >> 8) & 0xFF) / 255.0,
                         blue: Double(n & 0xFF) / 255.0)
    }

    private static func serializeTint(_ c: ItemColor) -> String {
        let r = Int((c.red * 255).rounded()), g = Int((c.green * 255).rounded()), b = Int((c.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func parseRuntimeParameter(_ value: String?) -> RuntimeParameter? {
        guard let value, value != "null" else { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "language": return .language(default: parts[1])
        case "codeLanguage": return .codeLanguage(default: parts[1])
        default: return nil
        }
    }

    private static func serializeRuntimeParameter(_ p: RuntimeParameter?) -> String? {
        guard case let .languageChoice(def, options)? = p else { return nil }
        return options == AILanguages.all ? "language:\(def)" : "codeLanguage:\(def)"
    }

    private static func parseHandoff(_ value: String?) -> ClaudeHandoffConfig? {
        guard let value, value != "null" else { return nil }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let mode = HandoffConfirmMode(rawValue: parts[0]) ?? .confirm
        let maxPerDay = parts.count == 2 ? Int(parts[1]) : nil
        return ClaudeHandoffConfig(confirmMode: mode, maxPerDay: maxPerDay)
    }

    private static func serializeHandoff(_ h: ClaudeHandoffConfig?) -> String? {
        guard let h else { return nil }
        if let max = h.maxPerDay { return "\(h.confirmMode.rawValue):\(max)" }
        return h.confirmMode.rawValue
    }
}
