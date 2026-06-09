import SwiftUI
import AppKit

/// The AI-command authoring editor: a master/detail surface that mirrors `FavoritesEditorView`'s
/// `ItemInspector` pattern. A left list shows the configured commands (add / reorder / delete); the
/// right pane is a per-command inspector that edits every field — name, icon/tint, input source,
/// prompt template (with the `{input}` / `{date}` / `{app}` / `{url}` tokens documented and
/// insertable), output target (+ task kind / destination), model, and `confirmBeforeRun`.
///
/// Every edit writes straight through `AICommandStore` (which persists immediately via its `mutate`
/// funnel), so the synthetic AI band reflects changes on its next launcher open. The store is the
/// single source of truth; the inspector reads its fields back from the store on every render.
struct AICommandEditorView: View {
    @ObservedObject var store: AICommandStore

    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            commandList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            if selectedID == nil { selectedID = store.commands.first?.id }
        }
    }

    // MARK: - Command list

    private var commandList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(store.commands) { command in
                    AICommandRow(command: command) { delete(command) }
                        .tag(command.id)
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack {
                Button { add() } label: { Label("Command", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .background(.background)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let command = store.command(withID: id) {
            AICommandInspector(store: store, command: command).id(command.id)
        } else {
            AIContentUnavailable("No command selected",
                                 systemImage: "wand.and.stars",
                                 caption: "Select a command on the left, or add one.")
        }
    }

    private func add() {
        let new = AICommand(
            name: "New Command",
            icon: .sfSymbol("wand.and.stars"),
            input: .selection,
            promptTemplate: "{input}",
            output: .previewOnly
        )
        store.add(new)
        selectedID = new.id
    }

    private func delete(_ command: AICommand) {
        let wasSelected = selectedID == command.id
        store.remove(command.id)
        if wasSelected { selectedID = store.commands.first?.id }
    }
}

private struct AICommandRow: View {
    let command: AICommand
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AICommandIconView(icon: command.icon, tint: command.tint, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.name)
                Text(outputLabel(command.output)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete command")
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Inspector

/// Per-command inspector. Holds local `@State` only for the free-text fields (name / prompt) so the
/// `TextEditor` cursor doesn't reset on every keystroke; structural pickers read+write the store
/// directly. Every change funnels through the store, which persists immediately.
private struct AICommandInspector: View {
    @ObservedObject var store: AICommandStore
    let command: AICommand

    @State private var name: String
    @State private var prompt: String

    init(store: AICommandStore, command: AICommand) {
        self.store = store
        self.command = command
        _name = State(initialValue: command.name)
        _prompt = State(initialValue: command.promptTemplate)
    }

    /// The live command (re-read each render so structural edits reflect immediately).
    private var live: AICommand { store.command(withID: command.id) ?? command }

    var body: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { update { $0.name = name } }
                    AICommandAppearanceEditor(
                        icon: Binding(get: { live.icon }, set: { ic in update { $0.icon = ic } }),
                        tint: Binding(get: { live.tint }, set: { t in update { $0.tint = t } }))
                }

                Section("Input") {
                    Picker("Input source", selection: Binding(
                        get: { live.input },
                        set: { src in update { $0.input = src } })) {
                        ForEach(InputSource.allCases, id: \.self) { Text(inputLabel($0)).tag($0) }
                    }
                    Text(inputHelp(live.input)).font(.caption).foregroundStyle(.secondary)
                }

                Section("Prompt") {
                    TokenBar { token in insert(token) }
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .border(.quaternary)
                        .onChange(of: prompt) { update { $0.promptTemplate = prompt } }
                    Text("Tokens are substituted at fire time: {input} the acquired text, {date} today, {app} the front app, {url} the front document URL. Unknown braces are left as-is.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Output") {
                    outputEditor
                }

                Section("Model") {
                    modelEditor
                }

                Section("Confirmation") {
                    Toggle("Confirm before running", isOn: Binding(
                        get: { live.confirmBeforeRun },
                        set: { on in update { $0.confirmBeforeRun = on } }))
                    Text(live.output.isSideEffecting
                         ? "This output has a side effect; confirmation defaults on, but you can turn it off for a trusted command."
                         : "In-place edits don't ask by default; turn this on to review the result before it's applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
    }

    // MARK: Output editor (target + task kind / destination)

    private enum OutputChoice: String, CaseIterable, Identifiable {
        case replaceSelection, pasteAtCursor, previewOnly, runTask, sendTo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .replaceSelection: return "Replace selection"
            case .pasteAtCursor: return "Paste at cursor"
            case .previewOnly: return "Preview only"
            case .runTask: return "Run a task"
            case .sendTo: return "Send to…"
            }
        }
    }

    @ViewBuilder
    private var outputEditor: some View {
        Picker("Output target", selection: Binding(
            get: { outputChoice(live.output) },
            set: { setOutputChoice($0) })) {
            ForEach(OutputChoice.allCases) { Text($0.label).tag($0) }
        }
        Text(outputLabel(live.output)).font(.caption).foregroundStyle(.secondary)

        if case let .runTask(kind) = live.output {
            taskKindEditor(kind)
        }
        if case let .sendTo(dest) = live.output {
            destinationEditor(dest) { newDest in update { $0.output = .sendTo(newDest) } }
        }
    }

    private enum TaskChoice: String, CaseIterable, Identifiable {
        case addToCalendar, saveToProject, openToolWithPayload, sendTo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .addToCalendar: return "Add to Calendar"
            case .saveToProject: return "Save to project"
            case .openToolWithPayload: return "Open tool with payload"
            case .sendTo: return "Send to destination"
            }
        }
    }

    @ViewBuilder
    private func taskKindEditor(_ kind: TaskKind) -> some View {
        Picker("Task", selection: Binding(
            get: { taskChoice(kind) },
            set: { setTaskChoice($0) })) {
            ForEach(TaskChoice.allCases) { Text($0.label).tag($0) }
        }
        switch kind {
        case .addToCalendar:
            Text("Parses an event from the result and adds it to Calendar (asks for permission the first time).")
                .font(.caption).foregroundStyle(.secondary)
        case let .saveToProject(project):
            TextField("Project", text: Binding(
                get: { project },
                set: { p in update { $0.output = .runTask(.saveToProject(project: p)) } }))
        case let .openToolWithPayload(tool):
            TextField("Tool (app or shortcut name)", text: Binding(
                get: { tool },
                set: { t in update { $0.output = .runTask(.openToolWithPayload(tool: t)) } }))
        case let .sendTo(dest):
            destinationEditor(dest) { newDest in update { $0.output = .runTask(.sendTo(newDest)) } }
        }
    }

    private enum DestinationChoice: String, CaseIterable, Identifiable {
        case shortcut, urlScheme, shell
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shortcut: return "Shortcut"
            case .urlScheme: return "URL scheme"
            case .shell: return "Shell command"
            }
        }
    }

    @ViewBuilder
    private func destinationEditor(_ dest: Destination, onChange: @escaping (Destination) -> Void) -> some View {
        Picker("Destination", selection: Binding(
            get: { destinationChoice(dest) },
            set: { onChange(blankDestination(for: $0, from: dest)) })) {
            ForEach(DestinationChoice.allCases) { Text($0.label).tag($0) }
        }
        switch dest {
        case let .shortcut(n):
            TextField("Shortcut name", text: Binding(get: { n }, set: { onChange(.shortcut(name: $0)) }))
        case let .urlScheme(s):
            TextField("URL scheme (use {content})", text: Binding(get: { s }, set: { onChange(.urlScheme($0)) }))
        case let .shell(c):
            TextField("Shell command (content on stdin)", text: Binding(get: { c }, set: { onChange(.shell(command: $0)) }))
        }
    }

    // MARK: Model editor

    @ViewBuilder
    private var modelEditor: some View {
        let registry = ModelRegistry.standard
        Picker("Model", selection: Binding(
            get: { selectedModelID(live.model) },
            set: { id in update { $0.model = .onDevice(modelID: id) } })) {
            Text("Registry default").tag(String?.none)
            ForEach(registry.models) { m in
                Text(m.displayName).tag(Optional(m.id))
            }
        }
        Text("On-device Gemma 4. \"Registry default\" tracks the recommended model; pin a specific one only if you need it.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Choice <-> model mapping

    private func outputChoice(_ o: OutputTarget) -> OutputChoice {
        switch o {
        case .replaceSelection: return .replaceSelection
        case .pasteAtCursor: return .pasteAtCursor
        case .previewOnly: return .previewOnly
        case .runTask: return .runTask
        case .sendTo: return .sendTo
        }
    }

    /// Switch the output target, carrying the most sensible default payload for task / send-to. Also
    /// re-derives `confirmBeforeRun` to the new output's default ONLY when crossing the side-effecting
    /// boundary, so a freshly-chosen task confirms by default while an explicit toggle is preserved
    /// within the same side-effecting family.
    private func setOutputChoice(_ choice: OutputChoice) {
        let newOutput: OutputTarget
        switch choice {
        case .replaceSelection: newOutput = .replaceSelection
        case .pasteAtCursor: newOutput = .pasteAtCursor
        case .previewOnly: newOutput = .previewOnly
        case .runTask: newOutput = .runTask(.addToCalendar)
        case .sendTo: newOutput = .sendTo(.shortcut(name: ""))
        }
        let crossedBoundary = live.output.isSideEffecting != newOutput.isSideEffecting
        update {
            $0.output = newOutput
            if crossedBoundary {
                $0.confirmBeforeRun = AICommand.defaultConfirmBeforeRun(for: newOutput)
            }
        }
    }

    private func taskChoice(_ k: TaskKind) -> TaskChoice {
        switch k {
        case .addToCalendar: return .addToCalendar
        case .saveToProject: return .saveToProject
        case .openToolWithPayload: return .openToolWithPayload
        case .sendTo: return .sendTo
        }
    }

    private func setTaskChoice(_ choice: TaskChoice) {
        let kind: TaskKind
        switch choice {
        case .addToCalendar: kind = .addToCalendar
        case .saveToProject: kind = .saveToProject(project: "")
        case .openToolWithPayload: kind = .openToolWithPayload(tool: "")
        case .sendTo: kind = .sendTo(.shortcut(name: ""))
        }
        update { $0.output = .runTask(kind) }
    }

    private func destinationChoice(_ d: Destination) -> DestinationChoice {
        switch d {
        case .shortcut: return .shortcut
        case .urlScheme: return .urlScheme
        case .shell: return .shell
        }
    }

    /// A blank destination of the chosen variety (used when switching variety in the picker).
    private func blankDestination(for choice: DestinationChoice, from current: Destination) -> Destination {
        switch choice {
        case .shortcut: if case .shortcut = current { return current }; return .shortcut(name: "")
        case .urlScheme: if case .urlScheme = current { return current }; return .urlScheme("")
        case .shell: if case .shell = current { return current }; return .shell(command: "")
        }
    }

    private func selectedModelID(_ m: ModelSelector) -> String? {
        switch m {
        case let .onDevice(id): return id
        case .cloud: return nil
        }
    }

    // MARK: Mutation + prompt insertion

    private func update(_ block: (inout AICommand) -> Void) {
        var copy = live
        block(&copy)
        store.update(copy)
    }

    private func insert(_ token: String) {
        prompt += token
        update { $0.promptTemplate = prompt }
    }
}

// MARK: - Token bar

private struct TokenBar: View {
    let onInsert: (String) -> Void
    private let tokens = ["{input}", "{date}", "{app}", "{url}"]

    var body: some View {
        HStack(spacing: 6) {
            Text("Insert:").font(.caption).foregroundStyle(.secondary)
            ForEach(tokens, id: \.self) { token in
                Button(token) { onInsert(token) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
    }
}

// MARK: - Appearance editor (self-contained; reuses the module's curated symbol/emoji lists)

/// Icon + tint editor for a command. Standalone (the Favorites one is `private`) but reuses the
/// shared `curatedSFSymbols` / `curatedEmojis` and the `ItemColor(_:Color)` bridge.
private struct AICommandAppearanceEditor: View {
    @Binding var icon: ItemIcon
    @Binding var tint: ItemColor?

    private enum Mode: Hashable { case symbol, emoji }
    private var mode: Mode {
        switch icon {
        case .sfSymbol: return .symbol
        case .emoji: return .emoji
        case .appDefault, .fileIcon: return .symbol
        }
    }

    var body: some View {
        Picker("Icon", selection: Binding(get: { mode }, set: { setMode($0) })) {
            Text("SF Symbol").tag(Mode.symbol)
            Text("Emoji").tag(Mode.emoji)
        }
        switch icon {
        case .sfSymbol: AISymbolPickerRow(icon: $icon)
        case .emoji: AIEmojiPickerRow(icon: $icon)
        case .appDefault, .fileIcon: EmptyView()
        }
        ColorPicker("Tint", selection: Binding(
            get: { tint.map(Color.init) ?? .accentColor },
            set: { tint = ItemColor($0) }))
    }

    private func setMode(_ m: Mode) {
        switch m {
        case .symbol: if case .sfSymbol = icon {} else { icon = .sfSymbol("wand.and.stars") }
        case .emoji:  if case .emoji = icon {} else { icon = .emoji("✨") }
        }
    }
}

private struct AISymbolPickerRow: View {
    @Binding var icon: ItemIcon
    @State private var showing = false
    @State private var search = ""

    private var name: String { if case .sfSymbol(let n) = icon { return n } else { return "" } }
    private var filtered: [String] {
        search.isEmpty ? curatedSFSymbols : curatedSFSymbols.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: name.isEmpty ? "questionmark.square.dashed" : name)
                .frame(width: 22, height: 22)
            TextField("Symbol name", text: Binding(get: { name }, set: { icon = .sfSymbol($0) }))
            Button("Choose…") { showing = true }
                .popover(isPresented: $showing, arrowEdge: .bottom) { picker }
        }
    }

    private var picker: some View {
        VStack(spacing: 8) {
            TextField("Search symbols", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 7), spacing: 6) {
                    ForEach(filtered, id: \.self) { sym in
                        Button { icon = .sfSymbol(sym); showing = false } label: {
                            Image(systemName: sym).font(.system(size: 18)).frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(name == sym ? Color.accentColor.opacity(0.30) : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(sym)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 330, height: 360)
    }
}

private struct AIEmojiPickerRow: View {
    @Binding var icon: ItemIcon
    @State private var showing = false

    private var glyph: String { if case .emoji(let g) = icon { return g } else { return "" } }

    var body: some View {
        HStack(spacing: 8) {
            Text(glyph.isEmpty ? "—" : glyph).font(.system(size: 18)).frame(width: 22, height: 22)
            TextField("Emoji", text: Binding(get: { glyph }, set: { icon = .emoji($0) }))
            Button("Choose…") { showing = true }
                .popover(isPresented: $showing, arrowEdge: .bottom) { picker }
            Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "face.smiling") }
                .help("Open the macOS emoji & symbols viewer")
        }
    }

    private var picker: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 8), spacing: 6) {
                ForEach(curatedEmojis, id: \.self) { e in
                    Button { icon = .emoji(e); showing = false } label: {
                        Text(e).font(.system(size: 22)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 320, height: 300)
    }
}

// MARK: - Icon view

/// Renders an `AICommand`'s icon (SF Symbol / emoji), tinted, for the command list / band preview.
struct AICommandIconView: View {
    let icon: ItemIcon
    let tint: ItemColor?
    var size: CGFloat = 24

    var body: some View {
        Group {
            switch icon {
            case .sfSymbol(let n):
                Image(systemName: n).resizable().scaledToFit()
                    .foregroundStyle(tint.map(Color.init) ?? .accentColor)
            case .emoji(let g):
                Text(g).font(.system(size: size * 0.82))
            case .appDefault, .fileIcon:
                Image(systemName: "wand.and.stars").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Content unavailable placeholder

private struct AIContentUnavailable: View {
    let title: String, systemImage: String, caption: String
    init(_ title: String, systemImage: String, caption: String) {
        self.title = title; self.systemImage = systemImage; self.caption = caption
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(caption).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Labels + choice mapping helpers

private func inputLabel(_ s: InputSource) -> String {
    switch s {
    case .selection: return "Selected text"
    case .clipboard: return "Clipboard"
    case .screenRegion: return "Screen region (vision)"
    case .none: return "No input"
    }
}

private func inputHelp(_ s: InputSource) -> String {
    switch s {
    case .selection: return "The front app's selected text (falls back to the clipboard when nothing is selected)."
    case .clipboard: return "The current clipboard contents."
    case .screenRegion: return "A captured screen region, fed to a vision-capable model."
    case .none: return "No input — the prompt template stands alone."
    }
}

private func outputLabel(_ o: OutputTarget) -> String {
    switch o {
    case .replaceSelection: return "Replace the selected text with the result."
    case .pasteAtCursor: return "Paste the result at the cursor."
    case .previewOnly: return "Show the result in the preview only; write nothing back."
    case let .runTask(kind): return "Run task: \(taskLabel(kind))."
    case let .sendTo(dest): return "Send to \(destinationLabel(dest))."
    }
}

private func taskLabel(_ k: TaskKind) -> String {
    switch k {
    case .addToCalendar: return "Add to Calendar"
    case let .saveToProject(p): return "Save to project \(p.isEmpty ? "…" : p)"
    case let .openToolWithPayload(t): return "Open \(t.isEmpty ? "tool" : t) with payload"
    case let .sendTo(d): return "Send to \(destinationLabel(d))"
    }
}

private func destinationLabel(_ d: Destination) -> String {
    switch d {
    case let .shortcut(n): return "Shortcut \(n.isEmpty ? "…" : n)"
    case let .urlScheme(s): return "URL \(s.isEmpty ? "…" : s)"
    case let .shell(c): return "Shell \(c.isEmpty ? "…" : c)"
    }
}

