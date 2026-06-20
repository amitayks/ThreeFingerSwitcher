import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The favorites "small IDE": a left **sources** sidebar that browses candidates by type and adds
/// them to the active band, and a **canvas** (bands list + the selected band's items) that arranges
/// everything exactly as the launcher shows it. Every edit writes straight through `FavoritesStore`,
/// which persists immediately, so the launcher reflects changes on its next activation.
///
/// The selected band on the canvas IS the active add target — picking a sourced item drops it there.
/// Hosted full-bleed in the Hub's Bands page (it was formerly a standalone Favorites window).
struct BandsCanvas: View {
    @ObservedObject var store: FavoritesStore

    @State private var selectedBandID: UUID?
    @State private var selectedItemID: UUID?
    /// Set to a just-added item's id so its inspector lands the cursor on the first field for fast entry.
    @State private var autoFocusItemID: UUID?

    var body: some View {
        HSplitView {
            // One merged column: bands list → click a band to expose its source picker inline, with the
            // band's settings pinned at the bottom.
            BandsColumn(store: store, selectedBandID: $selectedBandID,
                        selectedItemID: $selectedItemID, autoFocusItemID: $autoFocusItemID)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)

            // The selected band's items — always visible in their own column.
            ItemsPane(store: store, bandID: activeBandID,
                      selectedItemID: $selectedItemID, autoFocusItemID: $autoFocusItemID)
                .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The active band — the current selection if it still exists, else none (no auto-fallback, so nothing
    /// is highlighted on first open or after deselecting).
    private var activeBandID: UUID? {
        guard let id = selectedBandID, store.favorites.bands.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

// MARK: - Sources sidebar

private enum SourceCategory: String, CaseIterable, Identifiable {
    case apps = "Applications"
    case shortcuts = "Shortcuts"
    case paths = "Files & Folders"
    case urls = "URLs"
    case scripts = "Scripts"
    case actions = "Actions"
    case aiCommands = "AI Command"
    case claudeProject = "Claude Project"
    case terminal = "Open in Terminal"
    case claudeProjectPrompt = "Claude (Pick Folder)"
    case terminalPrompt = "Terminal (Pick Folder)"
    case presets = "Presets"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .apps: return "app.fill"
        case .shortcuts: return "bolt.fill"
        case .paths: return "folder.fill"
        case .urls: return "link"
        case .scripts: return "terminal.fill"
        case .actions: return "bolt.horizontal.fill"
        case .aiCommands: return "wand.and.stars"
        case .claudeProject: return "sparkles"
        case .terminal: return "terminal"
        case .claudeProjectPrompt: return "sparkles"
        case .terminalPrompt: return "terminal"
        case .presets: return "square.stack.3d.up.fill"
        }
    }
    /// The tile sublabel: immediate-add categories say "Add", browsable ones say "Browse".
    var hint: String {
        switch self {
        case .urls, .scripts, .paths, .claudeProject, .terminal, .claudeProjectPrompt, .terminalPrompt: return "Add"
        case .apps, .shortcuts, .actions, .aiCommands, .presets: return "Browse"
        }
    }
}

/// A category / candidate icon rendered like a `LaunchItemIconView` symbol (accent-tinted, square) so
/// source tiles match the band's item tiles.
private struct SourceSymbol: View {
    let name: String
    var body: some View {
        Image(systemName: name).resizable().scaledToFit()
            .foregroundStyle(Color.accentColor).frame(width: 40, height: 40)
    }
}

/// The per-band item-source picker, shown inline under an expanded band: a category index (Applications,
/// Shortcuts, Files & Folders, URLs, Scripts, Actions, AI Command, Presets) that drills into a candidate
/// browser, or — for URLs/Scripts/Files — adds an item immediately. Everything it adds goes straight into
/// `targetBandID`. The browser drill-in is height-bounded so its own list scrolls (not the bands column).
private struct SourcePicker: View {
    @ObservedObject var store: FavoritesStore
    let targetBandID: UUID
    @Binding var selectedItemID: UUID?
    @Binding var autoFocusItemID: UUID?
    @State private var category: SourceCategory?
    /// Open-Claude-Here setup state: resolving `claude` after a folder pick, and the bounded inline
    /// error (e.g. claude-not-found) shown in the category index — never an `NSAlert`.
    @State private var resolvingClaude = false
    @State private var claudeError: ClaudeLaunchError?

    var body: some View {
        if let category {
            categoryBrowser(category)
        } else {
            categoryIndex
        }
    }

    private var categoryIndex: some View {
        VStack(spacing: 8) {
            if resolvingClaude { claudeResolvingBanner }
            if let claudeError { claudeErrorBanner(claudeError) }
            LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                ForEach(SourceCategory.allCases) { cat in
                    Button { activate(cat) } label: {
                        GridTile(title: cat.rawValue, subtitle: cat.hint) { SourceSymbol(name: cat.symbol) }
                    }
                    .buttonStyle(PickTileButtonStyle())
                }
            }
        }
        .padding(12)
    }

    private var claudeResolvingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for the “claude” command…").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private func claudeErrorBanner(_ error: ClaudeLaunchError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.errorDescription ?? "Couldn't add the Claude Project.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Dismiss") { claudeError = nil }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    /// URLs / Scripts / Files / Claude Project add an item immediately (Files & Claude Project pick a
    /// folder/path first, since they need one); the rest drill into a browser of candidates.
    private func activate(_ cat: SourceCategory) {
        switch cat {
        case .urls:    add(.newLink(), focus: true)
        case .scripts: add(.newScript(), focus: true)
        case .paths:   choosePath()
        case .claudeProject: chooseClaudeFolder()
        case .terminal: chooseTerminalFolder()
        case .claudeProjectPrompt: addClaudePromptItem()
        case .terminalPrompt: addTerminalPromptItem()
        default:       category = cat
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            add(LaunchItem(title: url.lastPathComponent, icon: .fileIcon, kind: .path(url)), focus: true)
        }
    }

    /// Pick a project folder, then resolve `claude` off-main before adding the item — so we don't
    /// silently add a non-working item. Claude-not-found surfaces as a bounded inline banner.
    private func chooseClaudeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a project folder to open in Claude."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        claudeError = nil
        resolvingClaude = true
        Task {
            let path = await Task.detached { ClaudeLauncher.resolveClaudePath() }.value
            resolvingClaude = false
            guard let path else { claudeError = .claudeNotFound; return }
            add(ClaudeLauncher.makeItem(folder: folder, claudePath: path), focus: true)
        }
    }

    /// Pick a folder and add a general Open-in-Terminal item — no resolution / validation; the command
    /// is typed in the item panel afterward (blank = just open a shell there).
    private func chooseTerminalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to open in a terminal."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        add(TerminalLauncher.makeItem(folder: folder, command: ""), focus: true)
    }

    /// Add a choose-folder-at-launch Claude item — no setup folder (the folder is picked each time it
    /// runs). Resolve `claude` off-main like the fixed variant so we don't add a non-working item.
    private func addClaudePromptItem() {
        claudeError = nil
        resolvingClaude = true
        Task {
            let path = await Task.detached { ClaudeLauncher.resolveClaudePath() }.value
            resolvingClaude = false
            guard let path else { claudeError = .claudeNotFound; return }
            add(ClaudeLauncher.makePromptItem(claudePath: path), focus: true)
        }
    }

    /// Add a choose-folder-at-launch Open-in-Terminal item — no setup folder, no resolution.
    private func addTerminalPromptItem() {
        add(TerminalLauncher.makePromptItem(), focus: true)
    }

    @ViewBuilder
    private func categoryBrowser(_ cat: SourceCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { category = nil } label: { Label("All sources", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Group {
                switch cat {
                case .apps:      AppBrowser { add($0) }
                case .shortcuts: ShortcutBrowser { add($0) }
                case .actions:   ActionBrowser { add($0) }
                case .aiCommands: AICommandSource(store: store) { add($0) }
                case .presets:   PresetComposer(store: store) { add($0) }
                // Immediate-add sources never drill in (handled by `activate`); never reached.
                case .urls, .scripts, .paths, .claudeProject, .terminal, .claudeProjectPrompt, .terminalPrompt: EmptyView()
                }
            }
            .frame(height: 320)   // bound the inner browser so IT scrolls, not the outer bands column
        }
    }

    private func add(_ item: LaunchItem, focus: Bool = false) {
        // Run the insertion in the wizard's settle spring so the new tile *grows* into the band grid
        // (the band cell carries a scale transition; this transaction is what animates it).
        withAnimation(WizardMotion.arrival) {
            store.addItem(item, toBand: targetBandID)
            selectedItemID = item.id   // select the freshly added item so its inspector shows in the items column
        }
        if focus { autoFocusItemID = item.id }   // and land the cursor on its first field
    }
}

// MARK: - Source browsers

private struct AppBrowser: View {
    let onPick: (LaunchItem) -> Void
    @State private var apps: [AppCandidate] = []
    @State private var filter = ""
    @State private var loading = true

    private var shown: [AppCandidate] {
        filter.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter apps", text: $filter).textFieldStyle(.roundedBorder).padding(8)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                        ForEach(shown) { app in
                            Button {
                                onPick(LaunchItem(title: app.name, icon: .appDefault,
                                                  kind: .app(bundleURL: app.url, strategy: nil)))
                            } label: {
                                GridTile(title: app.name, subtitle: "App") {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable()
                                        .frame(width: 44, height: 44)
                                }
                            }
                            .buttonStyle(PickTileButtonStyle())
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task { apps = await loadInstalledApps(); loading = false }
    }
}

private struct ShortcutBrowser: View {
    let onPick: (LaunchItem) -> Void
    @State private var names: [String] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if names.isEmpty {
                ContentUnavailable("No shortcuts found", systemImage: "bolt.slash",
                                   caption: "Create shortcuts in the Shortcuts app, or check that the `shortcuts` CLI is available.")
            } else {
                ScrollView {
                    LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                        ForEach(names, id: \.self) { name in
                            Button {
                                onPick(LaunchItem(title: name, icon: .sfSymbol("bolt.fill"), kind: .shortcut(name: name)))
                            } label: {
                                GridTile(title: name, subtitle: "Shortcut") { SourceSymbol(name: "bolt.fill") }
                            }
                            .buttonStyle(PickTileButtonStyle())
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task { names = await loadShortcutNames(); loading = false }
    }
}

/// Normalize a typed address into a URL, defaulting a bare host to `https://`. `nil` when empty/invalid.
private func normalizedURL(_ s: String) -> URL? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let withScheme = trimmed.contains("://") || trimmed.contains(":") ? trimmed : "https://\(trimmed)"
    return URL(string: withScheme)
}

/// The placeholder URL a freshly-added, not-yet-filled link carries (the URL field shows it as empty).
private let blankLinkURL = URL(string: "about:blank")!

private extension LaunchItem {
    /// A blank link to drop into a band and edit in the item panel (URL / open-with / window).
    static func newLink() -> LaunchItem {
        LaunchItem(title: "", icon: .sfSymbol("link"), kind: .url(blankLinkURL))
    }
    /// A blank shell script to drop into a band and edit in the item panel.
    static func newScript() -> LaunchItem {
        LaunchItem(title: "", icon: .sfSymbol("terminal.fill"), kind: .script(.shell("")))
    }
}

/// The three script-body shapes, for the inspector's Type picker.
private enum ScriptKind: String, CaseIterable, Identifiable {
    case shell = "Shell", appleScript = "AppleScript", file = "Script file"
    var id: String { rawValue }
    init(_ body: ScriptBody) {
        switch body {
        case .shell: self = .shell
        case .appleScript: self = .appleScript
        case .file: self = .file
        }
    }
}

private struct ActionBrowser: View {
    let onPick: (LaunchItem) -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(SystemAction.Category.allCases) { category in
                    Text(category.rawValue).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 4)
                    LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                        ForEach(SystemAction.allCases.filter { $0.category == category }) { action in
                            Button {
                                onPick(LaunchItem(title: action.title, icon: .sfSymbol(action.symbol), kind: .action(action)))
                            } label: {
                                GridTile(title: action.title, subtitle: "Action") { SourceSymbol(name: action.symbol) }
                            }
                            .buttonStyle(PickTileButtonStyle())
                            .help(action.detail)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Source for AI commands: a CATALOG BROWSER over `AICommandCatalog`, mirroring `ActionBrowser` — a
/// `List` with one `Section` per `Category`, each preset a row that adds a fresh copy (`copy(of:)`
/// mints a new id) to the active band and auto-selects it so its inspector (right pane) opens for
/// editing. Each section header carries an "Add all as a band" affordance that creates a new band
/// named after the category (carrying its color) populated with that category's presets. A trailing
/// "Custom command" entry adds the blank editable command. Authoring lives inline in the item
/// inspector (configuration-hub fold-in; the standalone AI-command editor is gone).
private struct AICommandSource: View {
    @ObservedObject var store: FavoritesStore
    let onPick: (LaunchItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(AICommandCatalog.Category.allCases) { category in
                    HStack {
                        Label(category.title, systemImage: category.sfSymbol).font(.caption)
                        Spacer()
                        Button("Add all as a band") { addCategoryAsBand(category) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.caption)
                            .help("Create a new \"\(category.title)\" band populated with these presets.")
                    }
                    .padding(.horizontal, 12).padding(.top, 4)
                    LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                        ForEach(AICommandCatalog.commands(in: category)) { preset in
                            Button {
                                onPick(AIBand.item(for: AICommandCatalog.copy(of: preset)))
                            } label: {
                                GridTile(title: preset.name, subtitle: "AI Command") { SourceSymbol(name: symbolName(preset.icon)) }
                            }
                            .buttonStyle(PickTileButtonStyle())
                            .help(preset.promptTemplate)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                LazyVGrid(columns: sourceGridColumns, spacing: 12) {
                    Button {
                        let cmd = AICommand(name: "New Command", icon: .sfSymbol("wand.and.stars"),
                                            input: .selection, promptTemplate: "{input}", output: .previewOnly)
                        onPick(AIBand.item(for: cmd))
                    } label: {
                        GridTile(title: "Custom command", subtitle: "AI Command") { SourceSymbol(name: "wand.and.stars") }
                    }
                    .buttonStyle(PickTileButtonStyle())
                    .help("Add a blank AI command, then edit its prompt, input, and output on the right.")
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
        }
    }

    /// Create a new band named after the category (carrying its color), populated with that category's
    /// presets — each a fresh copy (`copy(of:)`). Appending is correct even if a same-named band exists
    /// (no dedupe/merge). Does not require the AI opt-in.
    private func addCategoryAsBand(_ category: AICommandCatalog.Category) {
        let items = AICommandCatalog.commands(in: category)
            .map { AIBand.item(for: AICommandCatalog.copy(of: $0)) }
        let band = ContextBand(name: category.title, color: category.tint,
                               icon: .sfSymbol(category.sfSymbol), items: items)
        store.mutate { $0.bands.append(band) }
    }

    /// The SF Symbol name behind a preset's `ItemIcon` (presets are always `.sfSymbol`; fall back to the
    /// AI glyph for any non-symbol icon a future preset might carry).
    private func symbolName(_ icon: ItemIcon) -> String {
        if case let .sfSymbol(name) = icon { return name }
        return "wand.and.stars"
    }
}

private struct PresetComposer: View {
    @ObservedObject var store: FavoritesStore
    let onPick: (LaunchItem) -> Void
    @State private var name = ""
    @State private var selected: Set<UUID> = []

    private var allItems: [(band: ContextBand, item: LaunchItem)] {
        store.favorites.bands.flatMap { band in band.items.filter { if case .preset = $0.kind { return false } else { return true } }.map { (band, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Preset name", text: $name).textFieldStyle(.roundedBorder).padding(8)
            Text("Pick the items this preset fires, in order:").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            List(allItems, id: \.item.id) { entry in
                Toggle(isOn: binding(for: entry.item.id)) {
                    HStack { LaunchItemIconView(item: entry.item, size: 16); Text(entry.item.title)
                        Spacer(); Text(entry.band.name).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.inset)
            Button("Add Preset") {
                let ordered = allItems.map(\.item.id).filter { selected.contains($0) }
                onPick(LaunchItem(title: name, icon: .sfSymbol("square.stack.3d.up.fill"), kind: .preset(itemIDs: ordered)))
                name = ""; selected = []
            }
            .disabled(name.isEmpty || selected.isEmpty)
            .padding(8)
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }
}

// MARK: - Bands pane (list on top, band editor below)

/// The merged bands + sources column. Lists the bands; clicking one selects it (its items show in the
/// items column, always visible) AND expands the source picker (Applications / URLs / Scripts / …)
/// inline under that band, so adding goes straight into it. The selected band's settings are pinned at the
/// bottom of this same column. Re-clicking the band collapses its sources; clicking another switches.
private struct BandsColumn: View {
    @ObservedObject var store: FavoritesStore
    @Binding var selectedBandID: UUID?
    @Binding var selectedItemID: UUID?
    @Binding var autoFocusItemID: UUID?
    @State private var draggingBand: UUID?
    /// The pinned band-settings card starts collapsed (it's secondary to adding items) and is opened
    /// via its disclosure arrow; the state persists across band selections.
    @State private var bandSettingsExpanded = false

    private var selectedBand: ContextBand? { store.favorites.bands.first { $0.id == selectedBandID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.favorites.bands) { band in bandRow(band) }
                }
            }
            Divider()
            HStack {
                Button { addBand() } label: { Label("Band", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
            // The selected band's settings live at the bottom of this same column, collapsed behind a
            // disclosure arrow so they're not always taking up space.
            if let band = selectedBand {
                Divider()
                Button {
                    withAnimation(WizardMotion.pop) { bandSettingsExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(bandSettingsExpanded ? 90 : 0))
                        Text("Band settings").font(.subheadline.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if bandSettingsExpanded {
                    BandInspector(store: store, band: band).id(band.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private func bandRow(_ band: ContextBand) -> some View {
        let selected = selectedBandID == band.id
        VStack(spacing: 0) {
            BandRow(band: band) { deleteBand(band) }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { tap(band) }
                .onDrag { draggingBand = band.id; return NSItemProvider(object: band.id.uuidString as NSString) }
                .onDrop(of: [.text], delegate: BandReorderDrop(target: band.id, store: store, dragging: $draggingBand))
            if selectedBandID == band.id {
                Divider()
                SourcePicker(store: store, targetBandID: band.id,
                             selectedItemID: $selectedItemID, autoFocusItemID: $autoFocusItemID)
                    .id(band.id)   // fresh category-drill state per band
            }
            Divider()
        }
    }

    private func tap(_ band: ContextBand) {
        // Re-tapping the selected band deselects it (no highlight, no sources, empty items column — the
        // same clean state as first opening the Hub); tapping another switches.
        selectedBandID = (selectedBandID == band.id) ? nil : band.id
        selectedItemID = nil
    }

    private func addBand() {
        let hue = Double(store.favorites.bands.count) * 0.16
        let color = ItemColor(NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.85, alpha: 1))
        let id = store.addBand(color: color)
        selectedBandID = id        // select + open the new band so its sources are ready
        selectedItemID = nil
    }

    private func deleteBand(_ band: ContextBand) {
        let wasSelected = selectedBandID == band.id
        store.removeBand(band.id)
        if wasSelected { selectedBandID = nil; selectedItemID = nil }   // deselect — no auto-highlight
    }
}

// MARK: - Items pane (grid + item editor — always visible for the selected band)

private struct ItemsPane: View {
    @ObservedObject var store: FavoritesStore
    let bandID: UUID?
    @Binding var selectedItemID: UUID?
    @Binding var autoFocusItemID: UUID?
    @State private var dragging: UUID?

    private var band: ContextBand? { store.favorites.bands.first { $0.id == bandID } }

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 14)]

    var body: some View {
        if let band {
            VStack(spacing: 0) {
                grid(band)
                if let itemID = selectedItemID, let item = band.items.first(where: { $0.id == itemID }) {
                    Divider()
                    ItemInspector(store: store, bandID: band.id, item: item,
                                  autoFocusItemID: $autoFocusItemID).id(item.id)
                }
            }
        } else {
            ContentUnavailable("No band selected", systemImage: "rectangle.stack",
                               caption: "Select a band in the middle column, or add one.")
        }
    }

    @ViewBuilder
    private func grid(_ band: ContextBand) -> some View {
        if band.items.isEmpty {
            ContentUnavailable("Empty band", systemImage: "tray",
                               caption: "Pick items from the sources on the left to add them here.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(band.items) { item in
                        ItemGridCell(item: item, selected: selectedItemID == item.id) {
                            // First click selects + arms; clicking the armed item again deletes it.
                            if selectedItemID == item.id { delete(item, in: band.id) }
                            else { selectedItemID = item.id }
                        } onTrash: {
                            delete(item, in: band.id)
                        }
                        .onDrag {
                            dragging = item.id
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                        .onDrop(of: [.text], delegate: ItemReorderDrop(
                            target: item.id, bandID: band.id, store: store, dragging: $dragging))
                        // The picked source tile shrinks; the new item grows in here (the add runs in a
                        // `WizardMotion.arrival` transaction, so this insertion springs from small).
                        .transition(.scale(scale: 0.15).combined(with: .opacity))
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func delete(_ item: LaunchItem, in bandID: UUID) {
        store.removeItem(item.id, fromBand: bandID)
        if selectedItemID == item.id { selectedItemID = nil }
    }
}

/// Drag-reorder for band header rows (mirrors `ItemReorderDrop`). An item's id never matches a band, so
/// the two drag sessions can't cross-contaminate.
private struct BandReorderDrop: DropDelegate {
    let target: UUID
    let store: FavoritesStore
    @Binding var dragging: UUID?
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = store.favorites.bands.firstIndex(where: { $0.id == dragging }),
              let to = store.favorites.bands.firstIndex(where: { $0.id == target }) else { return }
        store.moveBands(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct BandRow: View {
    let band: ContextBand
    let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            BandIconView(band: band, size: 20)
            Spacer()
            Text("\(band.items.count)").font(.caption).foregroundStyle(.secondary)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete band")
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Item grid cell

/// The shared square tile — a rounded icon container + title + sublabel — used by BOTH the band's item
/// grid and the source-picker grids, so a candidate looks identical to the item it becomes. `trash`
/// (shown only while `selected`) is the band grid's delete badge; the source grids omit it.
private struct GridTile<Icon: View>: View {
    var selected: Bool = false
    let title: String
    let subtitle: String
    var trash: (() -> Void)? = nil
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                icon()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                if selected, let trash {
                    Button(action: trash) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Delete (or click the item again)")
                }
            }
            .frame(height: 78)
            Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Press feedback for a pickable source tile: it scales down while pressed — the *shrink* half of
/// the shrink-then-grow gesture, the picked item then *grows* into the band grid (see `SourcePicker.add`).
private struct PickTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(WizardMotion.arrival, value: configuration.isPressed)
    }
}

/// Three fixed columns for every source-picker grid (the band item grid uses adaptive columns in its
/// wider pane, but the tiles themselves are identical).
private let sourceGridColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

/// One band-grid cell: a `GridTile` for the item plus tap-to-select / tap-again-to-delete behavior.
private struct ItemGridCell: View {
    let item: LaunchItem
    let selected: Bool
    let onTap: () -> Void
    let onTrash: () -> Void

    var body: some View {
        GridTile(selected: selected, title: item.title, subtitle: kindLabel(item.kind), trash: onTrash) {
            LaunchItemIconView(item: item, size: 44)
        }
        .onTapGesture { onTap() }
    }
}

/// Live drag-to-reorder for the items grid: as the dragged item hovers a cell, it moves there.
private struct ItemReorderDrop: DropDelegate {
    let target: UUID
    let bandID: UUID
    let store: FavoritesStore
    @Binding var dragging: UUID?

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let items = store.favorites.bands.first(where: { $0.id == bandID })?.items,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        store.moveItems(inBand: bandID, fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct BandInspector: View {
    @ObservedObject var store: FavoritesStore
    let band: ContextBand
    /// Local edit buffer for the band name (committed on change) so per-keystroke store writes don't
    /// churn the text field's cursor. Reset per band via the parent's `.id(band.id)`.
    @State private var name: String

    init(store: FavoritesStore, band: ContextBand) {
        self.store = store; self.band = band
        _name = State(initialValue: band.name)
    }

    var body: some View {
        Form {
            // Icon + color + name on one row. The launcher still shows bands by icon only; the name
            // labels the band in the "Move to band" / "Send to band" menus. The band's color tints
            // its icon, so the color swatch *is* the band color (no separate per-icon tint).
            HStack(spacing: 10) {
                IconColorControl(
                    icon: Binding(get: { band.resolvedIcon },
                                  set: { ic in store.updateBand(band.id) { $0.icon = ic } }),
                    tint: Binding(get: { Optional(band.color) },
                                  set: { c in if let c { store.updateBand(band.id) { $0.color = c } } }),
                    naturalIcon: nil) {
                        IconGlyphView(icon: band.resolvedIcon, tint: band.color, size: 20)
                    }
                TextField("Band name", text: $name)
                    .onChange(of: name) { store.updateBand(band.id) { $0.name = name } }
            }
            Picker("Default app strategy", selection: Binding(
                get: { band.defaultAppStrategy },
                set: { s in store.updateBand(band.id) { $0.defaultAppStrategy = s } })) {
                ForEach(AppStrategy.allCases, id: \.self) { Text(strategyLabel($0)).tag($0) }
            }
            Text(strategyHelp(band.defaultAppStrategy)).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(height: 230)
    }
}

private struct ItemInspector: View {
    @ObservedObject var store: FavoritesStore
    let bandID: UUID
    let item: LaunchItem
    @Binding var autoFocusItemID: UUID?
    @State private var title: String
    @State private var prompt: String
    /// Local edit buffer for the link address (a `.url` stores a `URL`, so we commit only when it parses).
    @State private var address: String
    /// Local edit buffer for an inline script body (shell / AppleScript).
    @State private var scriptCode: String
    /// Local edit buffer for the Claude Project command (shown defaulting to `claude`).
    @State private var claudeCommand: String
    /// Local edit buffer for the Open-in-Terminal command (blank = just open a shell).
    @State private var terminalCommand: String
    /// Installed apps for the link "Open with" picker (loaded once on appear).
    @State private var installedApps: [AppCandidate] = []
    @FocusState private var focus: Field?
    private enum Field: Hashable { case name, url, script }

    init(store: FavoritesStore, bandID: UUID, item: LaunchItem, autoFocusItemID: Binding<UUID?>) {
        self.store = store; self.bandID = bandID; self.item = item
        _autoFocusItemID = autoFocusItemID
        _title = State(initialValue: item.title)
        if case let .aiCommand(cmd) = item.kind {
            _prompt = State(initialValue: cmd.promptTemplate)
        } else {
            _prompt = State(initialValue: "")
        }
        if case let .url(u, _, _) = item.kind, u != blankLinkURL {
            _address = State(initialValue: u.absoluteString)
        } else {
            _address = State(initialValue: "")
        }
        if case let .script(body) = item.kind {
            _scriptCode = State(initialValue: Self.inlineScriptText(body))
        } else {
            _scriptCode = State(initialValue: "")
        }
        if case let .claudeProject(_, command, _) = item.kind {
            _claudeCommand = State(initialValue: command ?? "claude")
        } else if case let .claudeProjectPrompt(_, command, _) = item.kind {
            _claudeCommand = State(initialValue: command ?? "claude")
        } else {
            _claudeCommand = State(initialValue: "")
        }
        if case let .terminalCommand(_, command) = item.kind {
            _terminalCommand = State(initialValue: command)
        } else if case let .terminalCommandPrompt(_, command) = item.kind {
            _terminalCommand = State(initialValue: command)
        } else {
            _terminalCommand = State(initialValue: "")
        }
    }

    /// The editable text of an inline script body (empty for a file-backed script).
    private static func inlineScriptText(_ body: ScriptBody) -> String {
        switch body {
        case .shell(let s), .appleScript(let s): return s
        case .file: return ""
        }
    }

    var body: some View {
        if liveAICommand != nil { aiForm } else { standardForm }
    }

    // MARK: Standard item form (app / file / url / shortcut / script / action / preset)

    private var standardForm: some View {
        Form {
            HStack(spacing: 10) {
                IconColorControl(
                    icon: Binding(get: { item.icon },
                                  set: { ic in store.updateItem(item.id, inBand: bandID) { $0.icon = ic } }),
                    tint: Binding(get: { item.tint },
                                  set: { t in store.updateItem(item.id, inBand: bandID) { $0.tint = t } }),
                    naturalIcon: naturalIcon(for: item.kind)) {
                        LaunchItemIconView(item: item, size: 20)
                    }
                TextField("Name", text: $title)
                    .focused($focus, equals: .name)
                    .onChange(of: title) { store.updateItem(item.id, inBand: bandID) { $0.title = title } }
            }
            if case let .url(_, _, newWindow) = item.kind {
                urlEditor(newWindow: newWindow ?? false)
            }
            if case .path(let pathURL) = item.kind {
                pathEditor(pathURL)
            }
            if case .script(let body) = item.kind {
                scriptEditor(body)
            }
            if case let .app(bundleURL, strategy) = item.kind {
                HStack {
                    Text("Application")
                    Spacer()
                    Text(bundleURL.deletingPathExtension().lastPathComponent)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseApp(current: bundleURL, strategy: strategy) }
                }
                Picker("Window strategy", selection: Binding(
                    get: { strategy ?? band?.defaultAppStrategy ?? .smart },
                    set: { s in store.updateItem(item.id, inBand: bandID) { $0.kind = .app(bundleURL: bundleURL, strategy: s) } })) {
                    ForEach(AppStrategy.allCases, id: \.self) { Text(strategyLabel($0)).tag($0) }
                }
                Text(strategyHelp(strategy ?? band?.defaultAppStrategy ?? .smart))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case let .action(action, adjustment, toClipboard) = item.kind {
                if action.isValueAdjustable {
                    valueControl(action: action, adjustment: adjustment)
                }
                if action.supportsClipboardDestination {
                    screenshotClipboardControl(action: action, adjustment: adjustment, toClipboard: toClipboard ?? false)
                }
            }
            if case let .claudeProject(folder, _, claudePath) = item.kind {
                claudeProjectEditor(folder, claudePath: claudePath)
            }
            if case let .terminalCommand(folder, _) = item.kind {
                terminalEditor(folder)
            }
            if case let .claudeProjectPrompt(lastFolder, _, claudePath) = item.kind {
                claudePromptEditor(lastFolder: lastFolder, claudePath: claudePath)
            }
            if case let .terminalCommandPrompt(lastFolder, _) = item.kind {
                terminalPromptEditor(lastFolder: lastFolder)
            }
            moveToBandControl
        }
        .formStyle(.grouped)
        .frame(height: inspectorHeight)
        .task { if installedApps.isEmpty { installedApps = await loadInstalledApps() } }
        .onAppear {
            guard autoFocusItemID == item.id else { return }
            autoFocusItemID = nil   // consume the one-shot focus request for this freshly-added item
            switch item.kind {
            case .url:    focus = .url
            case .script: focus = .script
            default:      focus = .name
            }
        }
    }

    // MARK: Per-kind value editors (link / file / script)

    /// Link editor: the address, which app opens it, and whether it opens a new window or reuses one.
    @ViewBuilder
    private func urlEditor(newWindow: Bool) -> some View {
        TextField("URL", text: $address, prompt: Text("https://… or app scheme"))
            .focused($focus, equals: .url)
            .onChange(of: address) { setURLAddress(address) }
        Picker("Open with", selection: Binding(get: { currentHandler }, set: { setURLHandler($0) })) {
            Text("System default").tag(URL?.none)
            ForEach(installedApps) { app in Text(app.name).tag(URL?.some(app.url)) }
        }
        Picker("Window", selection: Binding(get: { newWindow }, set: { setURLNewWindow($0) })) {
            Text("Reuse existing window").tag(false)
            Text("New window").tag(true)
        }
        .pickerStyle(.radioGroup)
        if newWindow {
            Text("New window works in common browsers; others open normally.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// File/folder editor: the path, re-pickable.
    @ViewBuilder
    private func pathEditor(_ pathURL: URL) -> some View {
        HStack {
            Text("Path")
            Spacer()
            Text(pathURL.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { choosePath(current: pathURL) }
        }
    }

    /// Claude Project editor: the bound folder (re-pickable), the editable command run after `cd`
    /// (default `claude`, Script-style), and a read-only disclosure of the full generated `.command`
    /// script — so you can both see and configure what runs under the hood.
    @ViewBuilder
    private func claudeProjectEditor(_ folder: URL, claudePath: String?) -> some View {
        HStack {
            Text("Folder")
            Spacer()
            Text(folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { chooseClaudeProjectFolder(current: folder) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
            TextEditor(text: $claudeCommand)
                .frame(minHeight: 60).font(.system(.body, design: .monospaced)).border(.quaternary)
                .onChange(of: claudeCommand) { setClaudeCommand(claudeCommand) }
            Text("Runs in your default terminal after “cd” into the folder. Leave as “claude” for a plain session, or add flags / setup lines (e.g. claude --resume).")
                .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Generated script") {
            ScrollView {
                Text(ClaudeLauncher.commandScript(folder: folder,
                                                  command: Self.normalizedClaudeCommand(claudeCommand),
                                                  claudePath: claudePath))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    /// Normalize the inspector's command buffer for storage / preview: trimmed; the bare default
    /// (`claude`, the friendly placeholder) becomes `nil` so a launch uses the resolved `claudePath`
    /// (exact binary, works off-PATH) rather than re-running plain `claude`.
    private static func normalizedClaudeCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "claude") ? nil : trimmed
    }

    private func setClaudeCommand(_ value: String) {
        guard case let .claudeProject(folder, _, claudePath) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) {
            $0.kind = .claudeProject(folder: folder, command: Self.normalizedClaudeCommand(value), claudePath: claudePath)
        }
    }

    private func chooseClaudeProjectFolder(current: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = current
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let renaming = title.isEmpty || title == current.lastPathComponent
        if renaming { title = folder.lastPathComponent }
        // Update the folder immediately (preserve the command, clear the resolved path); re-resolve
        // `claude` off-main and patch it back in.
        store.updateItem(item.id, inBand: bandID) {
            if case let .claudeProject(_, command, _) = $0.kind {
                $0.kind = .claudeProject(folder: folder, command: command, claudePath: nil)
            }
            if renaming { $0.title = folder.lastPathComponent }
        }
        let id = item.id, band = bandID
        Task {
            let path = await Task.detached { ClaudeLauncher.resolveClaudePath() }.value
            guard let path else { return }
            store.updateItem(id, inBand: band) {
                if case let .claudeProject(f, c, _) = $0.kind { $0.kind = .claudeProject(folder: f, command: c, claudePath: path) }
            }
        }
    }

    /// Open-in-Terminal editor: the bound folder (re-pickable), the command run after `cd` (blank =
    /// just open a shell), and a read-only disclosure of the full generated `.command` script.
    @ViewBuilder
    private func terminalEditor(_ folder: URL) -> some View {
        HStack {
            Text("Folder")
            Spacer()
            Text(folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") { chooseTerminalProjectFolder(current: folder) }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
            TextEditor(text: $terminalCommand)
                .frame(minHeight: 60).font(.system(.body, design: .monospaced)).border(.quaternary)
                .onChange(of: terminalCommand) { setTerminalCommand(terminalCommand) }
            Text("Runs in your default terminal after “cd” into the folder (e.g. npm run dev). Leave blank to just open a shell there.")
                .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Generated script") {
            ScrollView {
                Text(TerminalLauncher.commandScript(folder: folder, command: terminalCommand))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func setTerminalCommand(_ value: String) {
        guard case let .terminalCommand(folder, _) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .terminalCommand(folder: folder, command: value) }
    }

    private func chooseTerminalProjectFolder(current: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = current
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let renaming = title.isEmpty || title == current.lastPathComponent
        if renaming { title = folder.lastPathComponent }
        store.updateItem(item.id, inBand: bandID) {
            if case let .terminalCommand(_, command) = $0.kind { $0.kind = .terminalCommand(folder: folder, command: command) }
            if renaming { $0.title = folder.lastPathComponent }
        }
    }

    // MARK: Choose-folder-at-launch editors (no setup folder; the folder is picked each run)

    /// Claude (Pick Folder) editor: the remembered last folder (Clear-able) plus the editable command.
    @ViewBuilder
    private func claudePromptEditor(lastFolder: URL?, claudePath: String?) -> some View {
        promptFolderRow(lastFolder: lastFolder)
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
            TextEditor(text: $claudeCommand)
                .frame(minHeight: 60).font(.system(.body, design: .monospaced)).border(.quaternary)
                .onChange(of: claudeCommand) { setClaudePromptCommand(claudeCommand) }
            Text("Runs in your default terminal after “cd” into the folder you pick. Leave as “claude” for a plain session, or add flags / setup lines (e.g. claude --resume).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Terminal (Pick Folder) editor: the remembered last folder (Clear-able) plus the editable command.
    @ViewBuilder
    private func terminalPromptEditor(lastFolder: URL?) -> some View {
        promptFolderRow(lastFolder: lastFolder)
        VStack(alignment: .leading, spacing: 4) {
            Text("Command")
            TextEditor(text: $terminalCommand)
                .frame(minHeight: 60).font(.system(.body, design: .monospaced)).border(.quaternary)
                .onChange(of: terminalCommand) { setTerminalPromptCommand(terminalCommand) }
            Text("Runs in your default terminal after “cd” into the folder you pick (e.g. npm run dev). Leave blank to just open a shell there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The folder row for a choose-folder-at-launch item: there is no bound folder — the chooser opens at
    /// the remembered last folder (or home), shown here with a Clear to forget it.
    @ViewBuilder
    private func promptFolderRow(lastFolder: URL?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Folder")
                Spacer()
                if let lastFolder {
                    Text(lastFolder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Clear") { clearPromptLastFolder() }
                } else {
                    Text("home folder").foregroundStyle(.secondary)
                }
            }
            Text(lastFolder == nil
                 ? "You pick the folder each time you run this; the chooser opens at your home folder."
                 : "You pick the folder each time you run this; the chooser opens at the folder above (your last pick). Clear to start from home.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setClaudePromptCommand(_ value: String) {
        guard case let .claudeProjectPrompt(lastFolder, _, claudePath) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) {
            $0.kind = .claudeProjectPrompt(lastFolder: lastFolder, command: Self.normalizedClaudeCommand(value), claudePath: claudePath)
        }
    }
    private func setTerminalPromptCommand(_ value: String) {
        guard case let .terminalCommandPrompt(lastFolder, _) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .terminalCommandPrompt(lastFolder: lastFolder, command: value) }
    }
    private func clearPromptLastFolder() {
        store.updateItem(item.id, inBand: bandID) { $0.kind = $0.kind.withLastFolder(nil) }
    }

    /// Script editor: the body type, plus an inline code editor or a file chooser.
    @ViewBuilder
    private func scriptEditor(_ body: ScriptBody) -> some View {
        Picker("Type", selection: Binding(get: { ScriptKind(body) }, set: { setScriptKind($0) })) {
            ForEach(ScriptKind.allCases) { Text($0.rawValue).tag($0) }
        }
        if case let .file(fileURL) = body {
            HStack {
                Text(fileURL.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseScriptFile() }
            }
        } else {
            TextEditor(text: $scriptCode)
                .frame(minHeight: 100).font(.system(.body, design: .monospaced)).border(.quaternary)
                .focused($focus, equals: .script)
                .onChange(of: scriptCode) { setScriptCode(scriptCode) }
        }
    }

    private var currentHandler: URL? {
        if case let .url(_, h, _) = item.kind { return h }
        return nil
    }

    private func setURLAddress(_ s: String) {
        guard case let .url(_, h, n) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .url(normalizedURL(s) ?? blankLinkURL, handler: h, newWindow: n) }
    }
    private func setURLHandler(_ handler: URL?) {
        guard case let .url(u, _, n) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .url(u, handler: handler, newWindow: n) }
    }
    private func setURLNewWindow(_ newWindow: Bool) {
        guard case let .url(u, h, _) = item.kind else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .url(u, handler: h, newWindow: newWindow) }
    }

    private func choosePath(current: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let renaming = title.isEmpty || title == current.lastPathComponent
        if renaming { title = url.lastPathComponent }
        store.updateItem(item.id, inBand: bandID) {
            $0.kind = .path(url)
            if renaming { $0.title = url.lastPathComponent }
        }
    }

    private func setScriptKind(_ kind: ScriptKind) {
        switch kind {
        case .shell:       store.updateItem(item.id, inBand: bandID) { $0.kind = .script(.shell(scriptCode)) }
        case .appleScript: store.updateItem(item.id, inBand: bandID) { $0.kind = .script(.appleScript(scriptCode)) }
        case .file:        chooseScriptFile()   // sets `.file(url)` on pick; stays put on cancel
        }
    }
    private func setScriptCode(_ code: String) {
        switch item.kind {
        case .script(.shell):       store.updateItem(item.id, inBand: bandID) { $0.kind = .script(.shell(code)) }
        case .script(.appleScript): store.updateItem(item.id, inBand: bandID) { $0.kind = .script(.appleScript(code)) }
        default: break
        }
    }
    private func chooseScriptFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.updateItem(item.id, inBand: bandID) { $0.kind = .script(.file(url)) }
    }

    private var inspectorHeight: CGFloat {
        if item.isAppKind { return 340 }
        switch item.kind {
        case .url:    return 340
        case .script: return 360
        case .path:   return 250
        case .claudeProject, .terminalCommand, .claudeProjectPrompt, .terminalCommandPrompt: return 400
        default:      break
        }
        if case let .action(action, _, _) = item.kind {
            if action.isValueAdjustable { return 310 }
            if action.supportsClipboardDestination { return 280 }
        }
        return 230
    }

    /// A "Move to band" menu shown when other bands exist, so any item (including an AI command) can be
    /// moved between bands (spec: "An AI command moves between bands"; "movable between bands like any
    /// other item"). After moving, the item leaves the current band's grid (it now lives elsewhere).
    @ViewBuilder
    private var moveToBandControl: some View {
        let others = store.favorites.bands.filter { $0.id != bandID }
        if !others.isEmpty {
            Menu("Move to band") {
                ForEach(others) { b in
                    Button { store.moveItem(item.id, fromBand: bandID, toBand: b.id) } label: {
                        // Bands are icon-only — show the destination band's icon (+ color) in the menu.
                        Label { Text(b.name) } icon: { bandMenuGlyph(b) }
                    }
                }
            }
        }
    }

    /// The destination band's icon for the "Move to band" menu (bands are shown by icon, not name).
    @ViewBuilder
    private func bandMenuGlyph(_ b: ContextBand) -> some View {
        switch b.resolvedIcon {
        case .sfSymbol(let n): Image(systemName: n)
        case .emoji(let g): Text(g)
        case .appDefault, .fileIcon: Image(systemName: "square.grid.2x2.fill")
        }
    }

    /// Optional value control for the volume/brightness actions: native step (default), set to a
    /// percentage, or change by a percentage.
    private enum ValueChoice: Hashable { case step, set, change }

    @ViewBuilder
    private func valueControl(action: SystemAction, adjustment: ValueAdjustment?) -> some View {
        let noun = action.controlsVolume ? "volume" : "brightness"
        Picker("Value", selection: Binding(
            get: {
                switch adjustment?.mode {
                case .none: return ValueChoice.step
                case .absolute: return .set
                case .relative: return .change
                }
            },
            set: { choice in
                let pct = adjustment?.percent ?? 50
                let newAdj: ValueAdjustment?
                switch choice {
                case .step:   newAdj = nil
                case .set:    newAdj = ValueAdjustment(mode: .absolute, percent: pct)
                case .change: newAdj = ValueAdjustment(mode: .relative, percent: pct)
                }
                store.updateItem(item.id, inBand: bandID) { $0.kind = .action(action, newAdj) }
            })) {
            Text("Step (system default)").tag(ValueChoice.step)
            Text("Set \(noun) to…").tag(ValueChoice.set)
            Text("Change by…").tag(ValueChoice.change)
        }
        if let adjustment {
            let label = adjustment.mode == .absolute
                ? "Set to \(Int(adjustment.percent))%"
                : "\(action.increasesValue ? "Increase" : "Decrease") by \(Int(adjustment.percent))%"
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Slider(value: Binding(
                    get: { adjustment.percent },
                    set: { p in
                        let clamped = max(0, min(100, p.rounded()))
                        store.updateItem(item.id, inBand: bandID) {
                            $0.kind = .action(action, ValueAdjustment(mode: adjustment.mode, percent: clamped))
                        }
                    }), in: 0...100, step: 5)
            }
            Text(adjustment.mode == .absolute
                 ? "Sets \(noun) directly to this level (the up/down direction is ignored)."
                 : "Adds or subtracts this much from the current \(noun); Up adds, Down subtracts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Toggle for the Selection / Full-Screen screenshot actions: route the capture to the clipboard
    /// (the native ⌃-modified shortcut) instead of writing a file. Preserves any (irrelevant here)
    /// value adjustment when rewriting the kind.
    @ViewBuilder
    private func screenshotClipboardControl(action: SystemAction, adjustment: ValueAdjustment?,
                                            toClipboard: Bool) -> some View {
        Toggle("Save screenshot to clipboard", isOn: Binding(
            get: { toClipboard },
            set: { on in
                store.updateItem(item.id, inBand: bandID) {
                    // Store `nil` when off so the field encodes as absent — identical on disk to a
                    // pre-feature item, and equal to a never-toggled one.
                    $0.kind = .action(action, adjustment, screenshotToClipboard: on ? true : nil)
                }
            }))
        Text("Captures to the clipboard only — no file is saved to the Desktop. Paste it anywhere (⌘V).")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var band: ContextBand? { store.favorites.bands.first { $0.id == bandID } }

    /// Pick a different application for this `.app` item (keeps the user's name/icon/strategy).
    private func chooseApp(current: URL, strategy: AppStrategy?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            store.updateItem(item.id, inBand: bandID) { $0.kind = .app(bundleURL: url, strategy: strategy) }
        }
    }

    // MARK: - AI command editing (the embedded `.aiCommand` is authoritative; display fields mirror it)

    /// The live embedded command for this item, re-read from the store each render so structural edits
    /// reflect immediately. `nil` when this item isn't an AI command (→ the standard form is shown).
    private var liveAICommand: AICommand? {
        guard let b = store.favorites.bands.first(where: { $0.id == bandID }),
              let it = b.items.first(where: { $0.id == item.id }),
              case let .aiCommand(cmd) = it.kind else { return nil }
        return cmd
    }

    /// A non-optional view of the command for the editors (the fallback is never rendered — `aiForm`
    /// only appears when `liveAICommand != nil`).
    private var ai: AICommand {
        liveAICommand ?? AICommand(name: "", icon: .sfSymbol("wand.and.stars"),
                                   input: .selection, promptTemplate: "", output: .previewOnly)
    }

    /// Apply an edit to the embedded command and persist it, mirroring name/icon/tint onto the
    /// `LaunchItem`'s display fields so the grid and launcher render the command correctly.
    private func updateCommand(_ block: (inout AICommand) -> Void) {
        guard var cmd = liveAICommand else { return }
        block(&cmd)
        store.updateItem(item.id, inBand: bandID) {
            $0.kind = .aiCommand(cmd)
            $0.title = cmd.name
            $0.icon = cmd.icon
            $0.tint = cmd.tint
        }
    }

    private func insertToken(_ token: String) {
        prompt += token
        updateCommand { $0.promptTemplate = prompt }
    }

    /// Whether any band other than this item's exists (gates the "Move to band" control + its divider).
    private var hasOtherBands: Bool { store.favorites.bands.contains { $0.id != bandID } }

    /// A compact "Title: control" field — a `.labelsHidden()` picker sits right next to its title so
    /// two can share a row without the Form's full-width label/value spread.
    private func aiField<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text("\(title):").foregroundStyle(.secondary)
            content()
        }
    }

    private var aiForm: some View {
        ScrollView {
            // One unified container holds the whole command configuration: identity, input, prompt,
            // output, model, reasoning, confirmation, and move — grouped by light inline subheaders
            // instead of separate boxed Sections, so the inspector reads as a single item card.
            Form {
                Section {
                    HStack(spacing: 10) {
                        IconColorControl(
                            icon: Binding(get: { ai.icon }, set: { ic in updateCommand { $0.icon = ic } }),
                            tint: Binding(get: { ai.tint }, set: { t in updateCommand { $0.tint = t } }),
                            naturalIcon: nil) {
                                IconGlyphView(icon: ai.icon, tint: ai.tint, size: 20)
                            }
                        TextField("Name", text: $title)
                            .onChange(of: title) { updateCommand { $0.name = title } }
                    }

                    // Input source + Output target on one tight row; the output's conditional
                    // task/destination sub-editors flow below it.
                    HStack(spacing: 18) {
                        aiField("Input source") {
                            Picker("Input source", selection: Binding(
                                get: { ai.input }, set: { src in updateCommand { $0.input = src } })) {
                                ForEach(InputSource.allCases, id: \.self) { Text(aiInputLabel($0)).tag($0) }
                            }
                            .labelsHidden()
                        }
                        aiField("Output target") { aiOutputPicker.labelsHidden() }
                        Spacer(minLength: 0)
                    }
                    aiOutputDetail

                    AITokenBar { insertToken($0) }
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .font(.system(.body, design: .monospaced))
                        .border(.quaternary)
                        .onChange(of: prompt) { updateCommand { $0.promptTemplate = prompt } }
                    Text("Tokens are substituted at fire time: {input} the acquired text, {date} today, {app} the front app, {url} the front document URL. Unknown braces are left as-is.")
                        .font(.caption).foregroundStyle(.secondary)

                    // Model + Reasoning on one tight row.
                    HStack(spacing: 18) {
                        aiField("Model") { aiModelPicker.labelsHidden() }
                        aiField("Reasoning") { aiReasoningPicker.labelsHidden() }
                        Spacer(minLength: 0)
                    }

                    Toggle("Confirm before running", isOn: Binding(
                        get: { ai.confirmBeforeRun }, set: { on in updateCommand { $0.confirmBeforeRun = on } }))

                    if hasOtherBands { Divider().padding(.vertical, 2); moveToBandControl }
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(height: 380)
    }

    private var aiOutputPicker: some View {
        Picker("Output target", selection: Binding(
            get: { outputChoice(ai.output) }, set: { setOutputChoice($0) })) {
            ForEach(OutputChoice.allCases) { Text($0.label).tag($0) }
        }
    }

    /// The output's conditional task/destination sub-editors — shown below the paired input/output
    /// row (only when the chosen output target needs further configuration).
    @ViewBuilder
    private var aiOutputDetail: some View {
        if case let .runTask(kind) = ai.output { aiTaskKindEditor(kind) }
        if case let .sendTo(dest) = ai.output {
            aiDestinationEditor(dest) { newDest in updateCommand { $0.output = .sendTo(newDest) } }
        }
    }

    @ViewBuilder
    private func aiTaskKindEditor(_ kind: TaskKind) -> some View {
        Picker("Task", selection: Binding(get: { taskChoice(kind) }, set: { setTaskChoice($0) })) {
            ForEach(TaskChoice.allCases) { Text($0.label).tag($0) }
        }
        switch kind {
        case .addToCalendar:
            Text("Parses an event from the result and adds it to Calendar (asks for permission the first time).")
                .font(.caption).foregroundStyle(.secondary)
        case .addToReminder:
            Text("Parses a to-do from the result and adds it to Reminders (asks for permission the first time).")
                .font(.caption).foregroundStyle(.secondary)
        case .newContact:
            Text("Parses contact details from the result and creates a Contacts card (asks for permission the first time).")
                .font(.caption).foregroundStyle(.secondary)
        case let .saveToProject(project):
            TextField("Project", text: Binding(
                get: { project }, set: { p in updateCommand { $0.output = .runTask(.saveToProject(project: p)) } }))
        case let .openToolWithPayload(tool):
            ToolTargetPicker(tool: Binding(
                get: { tool }, set: { t in updateCommand { $0.output = .runTask(.openToolWithPayload(tool: t)) } }))
        case let .sendTo(dest):
            aiDestinationEditor(dest) { newDest in updateCommand { $0.output = .runTask(.sendTo(newDest)) } }
        }
    }

    @ViewBuilder
    private func aiDestinationEditor(_ dest: Destination, onChange: @escaping (Destination) -> Void) -> some View {
        Picker("Destination", selection: Binding(
            get: { destinationChoice(dest) }, set: { onChange(blankDestination(for: $0, from: dest)) })) {
            ForEach(DestinationChoice.allCases) { Text($0.label).tag($0) }
        }
        switch dest {
        case let .shortcut(n):
            ShortcutPicker(name: Binding(get: { n }, set: { onChange(.shortcut(name: $0)) }))
        case let .urlScheme(s):
            TextField("URL scheme (use {content})", text: Binding(get: { s }, set: { onChange(.urlScheme($0)) }))
        case let .shell(c):
            TextField("Shell command (content on stdin)", text: Binding(get: { c }, set: { onChange(.shell(command: $0)) }))
        }
    }

    private var aiModelPicker: some View {
        let registry = ModelRegistry.standard
        return Picker("Model", selection: Binding(
            get: { selectedModelID(ai.model) }, set: { id in updateCommand { $0.model = .onDevice(modelID: id) } })) {
            Text("Registry default").tag(String?.none)
            ForEach(registry.models) { m in Text(m.displayName).tag(Optional(m.id)) }
        }
    }

    private var aiReasoningPicker: some View {
        Picker("Reasoning", selection: Binding(
            get: { ai.reasoning }, set: { r in updateCommand { $0.reasoning = r } })) {
            Text("Default").tag(AIReasoning?.none)
            Text("On").tag(Optional(AIReasoning.on))
            Text("Off").tag(Optional(AIReasoning.off))
        }
    }

    private func outputChoice(_ o: OutputTarget) -> OutputChoice {
        switch o {
        case .replaceSelection: return .replaceSelection
        case .pasteAtCursor: return .pasteAtCursor
        case .previewOnly: return .previewOnly
        case .runTask: return .runTask
        case .sendTo: return .sendTo
        }
    }

    private func setOutputChoice(_ choice: OutputChoice) {
        let newOutput: OutputTarget
        switch choice {
        case .replaceSelection: newOutput = .replaceSelection
        case .pasteAtCursor: newOutput = .pasteAtCursor
        case .previewOnly: newOutput = .previewOnly
        case .runTask: newOutput = .runTask(.addToCalendar)
        case .sendTo: newOutput = .sendTo(.shortcut(name: ""))
        }
        let crossedBoundary = ai.output.isSideEffecting != newOutput.isSideEffecting
        updateCommand {
            $0.output = newOutput
            if crossedBoundary { $0.confirmBeforeRun = AICommand.defaultConfirmBeforeRun(for: newOutput) }
        }
    }

    private func taskChoice(_ k: TaskKind) -> TaskChoice {
        switch k {
        case .addToCalendar: return .addToCalendar
        case .addToReminder: return .addToReminder
        case .newContact: return .newContact
        case .saveToProject: return .saveToProject
        case .openToolWithPayload: return .openToolWithPayload
        case .sendTo: return .sendTo
        }
    }

    private func setTaskChoice(_ choice: TaskChoice) {
        let kind: TaskKind
        switch choice {
        case .addToCalendar: kind = .addToCalendar
        case .addToReminder: kind = .addToReminder
        case .newContact: kind = .newContact
        case .saveToProject: kind = .saveToProject(project: "")
        case .openToolWithPayload: kind = .openToolWithPayload(tool: "")
        case .sendTo: kind = .sendTo(.shortcut(name: ""))
        }
        updateCommand { $0.output = .runTask(kind) }
    }

    private func destinationChoice(_ d: Destination) -> DestinationChoice {
        switch d {
        case .shortcut: return .shortcut
        case .urlScheme: return .urlScheme
        case .shell: return .shell
        }
    }

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
}

/// Compact appearance control: a clickable icon button (opens the SF Symbol picker) plus a color
/// swatch that tints it. Designed to sit on one row beside a name field (items / AI) or alone for
/// an icon-only band. The `preview` closure renders the live icon so each call site can show the
/// real thing (an app/file icon via `LaunchItemIconView`, or a plain symbol glyph).
///
/// SF Symbols only — the old Emoji mode was dropped. Existing emoji icons still *render* everywhere
/// (`ItemIcon.emoji` stays in the model for backward compatibility); they just can't be authored here.
private struct IconColorControl<Preview: View>: View {
    @Binding var icon: ItemIcon
    @Binding var tint: ItemColor?
    /// The app/file icon offered as a "Default" reset inside the picker, when the kind has one.
    let naturalIcon: ItemIcon?
    @ViewBuilder var preview: () -> Preview
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showing = true } label: {
                preview()
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.secondary.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Choose an icon")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SymbolPicker(icon: $icon, naturalIcon: naturalIcon, isPresented: $showing)
            }
            ColorPicker("Icon color", selection: Binding(
                get: { tint.map(Color.init) ?? .accentColor },
                set: { tint = ItemColor($0) }))
                .labelsHidden()
                .help("Icon color")
        }
    }
}

/// Renders an `ItemIcon` (symbol / legacy emoji) tinted, for previews that have no backing
/// `LaunchItem` (the AI identity row, the band row). App/file defaults fall back to a generic glyph.
private struct IconGlyphView: View {
    let icon: ItemIcon
    let tint: ItemColor?
    var size: CGFloat = 20

    var body: some View {
        switch icon {
        case .sfSymbol(let n):
            Image(systemName: n).resizable().scaledToFit()
                .foregroundStyle(tint.map(Color.init) ?? .accentColor)
                .frame(width: size, height: size)
        case .emoji(let g):
            Text(g).font(.system(size: size * 0.85)).frame(width: size, height: size)
        case .appDefault, .fileIcon:
            Image(systemName: "app.dashed").resizable().scaledToFit()
                .foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}

private func naturalIcon(for kind: LaunchItemKind) -> ItemIcon? {
    switch kind {
    case .app: return .appDefault
    case .path: return .fileIcon
    case .url, .shortcut, .script, .action, .preset, .clipboardEntry, .fileEntry, .aiCommand, .claudeProject, .terminalCommand, .claudeProjectPrompt, .terminalCommandPrompt: return nil
    }
}

/// SF Symbol chooser popover: a searchable grid of curated symbols. When the kind has a natural
/// icon (app / file) it offers a "Default" reset at the top; a search that names a real SF Symbol
/// outside the curated set can be picked directly, preserving the old typed-name power.
private struct SymbolPicker: View {
    @Binding var icon: ItemIcon
    let naturalIcon: ItemIcon?
    @Binding var isPresented: Bool
    @State private var search = ""

    private var current: String { if case .sfSymbol(let n) = icon { return n } else { return "" } }
    private var filtered: [String] {
        search.isEmpty ? curatedSFSymbols : curatedSFSymbols.filter { $0.localizedCaseInsensitiveContains(search) }
    }
    /// A typed query that is a real SF Symbol but isn't already in the curated grid — offered first.
    private var typedExtra: String? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !curatedSFSymbols.contains(q),
              NSImage(systemSymbolName: q, accessibilityDescription: nil) != nil else { return nil }
        return q
    }

    var body: some View {
        VStack(spacing: 8) {
            if naturalIcon != nil {
                Button { if let n = naturalIcon { icon = n }; isPresented = false } label: {
                    Label("Default icon", systemImage: "app.dashed").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            TextField("Search symbols", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 7), spacing: 6) {
                    if let typedExtra { cell(typedExtra) }
                    ForEach(filtered, id: \.self) { cell($0) }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 330, height: 380)
    }

    private func cell(_ sym: String) -> some View {
        Button { icon = .sfSymbol(sym); isPresented = false } label: {
            Image(systemName: sym).font(.system(size: 18)).frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(current == sym ? Color.accentColor.opacity(0.30) : .clear))
        }
        .buttonStyle(.plain)
        .help(sym)
    }
}

/// A curated set of common SF Symbols for the icon picker (searching any other name still works).
let curatedSFSymbols: [String] = [
    // Shapes
    "circle.fill", "circle", "square.fill", "square", "triangle.fill", "triangle",
    "diamond.fill", "diamond", "hexagon.fill", "hexagon", "pentagon.fill", "pentagon",
    "octagon.fill", "octagon", "seal.fill", "seal", "capsule.fill", "capsule",
    "oval.fill", "oval", "rhombus.fill", "rhombus", "rectangle.fill", "rectangle",
    "suit.heart.fill", "suit.club.fill", "suit.spade.fill", "suit.diamond.fill",
    "circle.hexagongrid.fill", "circle.grid.2x2.fill", "square.on.square",
    "star.fill", "star", "heart.fill", "heart", "bolt.fill", "bolt", "flame.fill", "flame",
    "sparkles", "wand.and.stars", "crown.fill", "trophy.fill", "rosette", "medal.fill",
    "folder.fill", "folder", "doc.fill", "doc", "doc.text.fill", "tray.fill", "archivebox.fill",
    "externaldrive.fill", "internaldrive.fill", "shippingbox.fill", "cube.fill",
    "terminal.fill", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
    "hammer.fill", "wrench.and.screwdriver.fill", "gearshape.fill", "gearshape.2.fill", "gear",
    "app.fill", "square.grid.2x2.fill", "square.grid.3x3.fill", "square.stack.3d.up.fill",
    "rectangle.stack.fill", "macwindow", "menubar.rectangle",
    "globe", "network", "link", "paperplane.fill", "envelope.fill", "message.fill",
    "bubble.left.fill", "phone.fill", "video.fill", "bell.fill", "megaphone.fill",
    "calendar", "clock.fill", "alarm.fill", "timer", "stopwatch.fill", "hourglass",
    "person.fill", "person.2.fill", "person.crop.circle.fill", "figure.walk",
    "house.fill", "building.2.fill", "building.columns.fill", "cart.fill", "bag.fill",
    "creditcard.fill", "dollarsign.circle.fill", "banknote.fill",
    "music.note", "music.note.list", "play.fill", "pause.fill", "stop.fill",
    "forward.fill", "backward.fill", "speaker.wave.2.fill", "headphones", "mic.fill",
    "photo.fill", "camera.fill", "film.fill", "paintbrush.fill", "paintpalette.fill",
    "pencil", "pencil.tip", "highlighter", "scribble.variable", "ruler.fill", "scissors",
    "book.fill", "books.vertical.fill", "bookmark.fill", "newspaper.fill", "graduationcap.fill",
    "map.fill", "mappin.and.ellipse", "location.fill", "flag.fill", "globe.americas.fill",
    "cup.and.saucer.fill", "fork.knife", "wineglass.fill", "birthday.cake.fill",
    "gamecontroller.fill", "dice.fill", "puzzlepiece.fill", "gift.fill", "party.popper.fill",
    "airplane", "car.fill", "bicycle", "tram.fill", "bus.fill", "ferry.fill",
    "lock.fill", "lock.open.fill", "key.fill", "shield.fill", "checkmark.shield.fill",
    "tag.fill", "pin.fill", "bookmark.circle.fill", "exclamationmark.triangle.fill",
    "trash.fill", "plus.circle.fill", "minus.circle.fill", "xmark.circle.fill", "checkmark.circle.fill",
    "arrow.clockwise", "arrow.triangle.2.circlepath", "arrow.up.circle.fill", "arrow.down.circle.fill",
    "magnifyingglass", "slider.horizontal.3", "line.3.horizontal", "ellipsis.circle.fill",
    "wifi", "antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right",
    "display", "laptopcomputer", "desktopcomputer", "keyboard.fill", "cpu.fill", "memorychip.fill",
    "battery.100", "powerplug.fill", "bolt.batteryblock.fill",
    "brain.head.profile", "lightbulb.fill", "atom", "function", "sum", "x.squareroot",
    "chart.bar.fill", "chart.pie.fill", "chart.line.uptrend.xyaxis", "list.bullet", "checklist",
    "square.and.arrow.up.fill", "square.and.arrow.down.fill", "square.and.pencil",
    "moon.fill", "sun.max.fill", "cloud.fill", "drop.fill", "leaf.fill", "tree.fill",
    "pawprint.fill", "tortoise.fill", "ant.fill", "ladybug.fill",
    "cross.case.fill", "pills.fill", "stethoscope", "heart.text.square.fill",
]

// MARK: - Shared rendering helpers

/// Renders a band's icon (SF Symbol / emoji) tinted by its color — used wherever a band is shown by
/// icon in the Hub (the band list, the "Add to" header). Bands carry only an icon, not a name.
private struct BandIconView: View {
    let band: ContextBand
    var size: CGFloat = 18

    var body: some View {
        switch band.resolvedIcon {
        case .sfSymbol(let n):
            Image(systemName: n).resizable().scaledToFit()
                .foregroundStyle(Color(band.color))
                .frame(width: size, height: size)
        case .emoji(let g):
            Text(g).font(.system(size: size * 0.9)).frame(width: size, height: size)
        case .appDefault, .fileIcon:
            Image(systemName: "square.grid.2x2.fill").resizable().scaledToFit()
                .foregroundStyle(Color(band.color)).frame(width: size, height: size)
        }
    }
}

/// Renders a `LaunchItem`'s icon (app icon / file icon / SF Symbol / emoji), mirroring the launcher.
struct LaunchItemIconView: View {
    let item: LaunchItem
    var size: CGFloat = 24

    var body: some View {
        Group {
            switch item.icon {
            case .appDefault:
                if case let .app(url, _) = item.kind {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else { symbol("app.dashed") }
            case .fileIcon:
                if case let .path(url) = item.kind {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else { symbol("doc") }
            case .sfSymbol(let n):
                Image(systemName: n).resizable().scaledToFit()
                    .foregroundStyle(item.tint.map(Color.init) ?? .accentColor)
            case .emoji(let g):
                Text(g).font(.system(size: size * 0.82))
            }
        }
        .frame(width: size, height: size)
    }

    private func symbol(_ n: String) -> some View {
        Image(systemName: n).resizable().scaledToFit().foregroundStyle(.secondary)
    }
}

/// Lightweight stand-in for `ContentUnavailableView` (keeps the macOS deployment target flexible).
private struct ContentUnavailable: View {
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

private extension LaunchItem {
    var isAppKind: Bool { if case .app = kind { return true } else { return false } }
}

extension ItemColor {
    /// Build the model color from a SwiftUI `Color` (via sRGB components).
    init(_ color: Color) { self.init(NSColor(color)) }

    /// Build the model color from an `NSColor` (via sRGB components).
    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? .gray
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent),
                  blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}

private func strategyLabel(_ s: AppStrategy) -> String {
    switch s {
    case .smart: return "Smart (recommended)"
    case .alwaysNewWindow: return "Always a new window"
    case .bringExistingHere: return "Go to its window"
    case .quitAndReopenHere: return "Quit & reopen here (loses unsaved state)"
    case .newInstance: return "New app instance"
    }
}

private func strategyHelp(_ s: AppStrategy) -> String {
    switch s {
    case .smart: return "New window for multi-window apps; for single-window apps, go to the existing window."
    case .alwaysNewWindow: return "Always open a new window (menu New Window, else ⌘N)."
    case .bringExistingHere: return "Switch to the Space holding the app's window and focus it."
    case .quitAndReopenHere: return "Quit the app and relaunch it so a fresh window opens on this Space. Loses unsaved state — use only for safe apps."
    case .newInstance: return "Launch a second copy of the app (only for apps that support multiple instances)."
    }
}

private func kindLabel(_ kind: LaunchItemKind) -> String {
    switch kind {
    case .app: return "App"
    case .path: return "File"
    case .url: return "URL"
    case .shortcut: return "Shortcut"
    case .script: return "Script"
    case .action: return "Action"
    case .preset: return "Preset"
    case .clipboardEntry: return "Clipboard"
    case .fileEntry: return "File Entry"
    case .aiCommand: return "AI Command"
    case .claudeProject: return "Claude Project"
    case .terminalCommand: return "Terminal"
    case .claudeProjectPrompt: return "Claude (Pick Folder)"
    case .terminalCommandPrompt: return "Terminal (Pick Folder)"
    }
}

// MARK: - AI tool/destination pickers

/// Menu picker for the "Open tool with payload" task target. The stored value is a bare string with
/// opener-defined semantics (see `WorkspaceToolOpener.defaultOpen`): an app *path* (contains "/" or
/// ends ".app") is launched as an app, anything else is run as a named Shortcut. So an app pick
/// stores `candidate.url.path` and a Shortcut pick stores its name. A "Custom…" escape hatch (also
/// auto-shown for an unrecognised value) exposes a `TextField` for not-yet-created Shortcuts.
private struct ToolTargetPicker: View {
    @Binding var tool: String
    @State private var apps: [AppCandidate] = []
    @State private var shortcuts: [String] = []
    @State private var showCustom = false
    /// Set once the async lists have loaded, so a pre-existing listed value isn't briefly treated as
    /// "custom" (the `matchesShortcut` check is meaningless against an empty, not-yet-loaded list).
    @State private var loaded = false

    private var isAppPath: Bool { tool.contains("/") || tool.hasSuffix(".app") }
    private var matchesShortcut: Bool { shortcuts.contains(tool) }

    /// Friendly label for the current value: app file name (no `.app`), shortcut name, or the raw value.
    private var menuLabel: String {
        if tool.isEmpty { return "Choose app or shortcut…" }
        if isAppPath { return URL(fileURLWithPath: tool).deletingPathExtension().lastPathComponent }
        return tool
    }

    /// Show the free-text field when explicitly requested, or — once the lists have loaded — when the
    /// current value matches neither a known app path nor a listed shortcut (so an unusual/typed target
    /// stays editable without flashing for a pre-existing listed value while the list loads).
    private var showsField: Bool {
        showCustom || (loaded && !tool.isEmpty && !isAppPath && !matchesShortcut)
    }

    var body: some View {
        Menu {
            if !shortcuts.isEmpty {
                Section("Shortcuts") {
                    ForEach(shortcuts, id: \.self) { name in
                        Button { showCustom = false; tool = name } label: { Label(name, systemImage: "bolt.fill") }
                    }
                }
            }
            Section("Apps") {
                ForEach(apps) { app in
                    Button {
                        showCustom = false; tool = app.url.path
                    } label: {
                        Label { Text(app.name) } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 16, height: 16)
                        }
                    }
                }
            }
            Divider()
            Button("Custom…") { showCustom = true }
        } label: {
            if isAppPath {
                Label { Text(menuLabel) } icon: {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: tool)).resizable().frame(width: 16, height: 16)
                }
            } else {
                Label(menuLabel, systemImage: matchesShortcut ? "bolt.fill" : "wand.and.stars")
            }
        }
        .task { apps = await loadInstalledApps(); shortcuts = await loadShortcutNames(); loaded = true }
        if showsField {
            TextField("Tool (app path or shortcut name)", text: $tool)
        }
    }
}

/// Menu picker for a `.shortcut(name:)` destination: the user's Shortcuts plus a "Custom…" → field
/// escape hatch for a not-yet-created Shortcut. Lazy-loaded; tolerates an empty list.
private struct ShortcutPicker: View {
    @Binding var name: String
    @State private var shortcuts: [String] = []
    @State private var showCustom = false
    /// Set once the list loads, so a pre-existing listed Shortcut isn't briefly shown as "custom".
    @State private var loaded = false

    private var menuLabel: String { name.isEmpty ? "Choose shortcut…" : name }
    private var showsField: Bool { showCustom || (loaded && !name.isEmpty && !shortcuts.contains(name)) }

    var body: some View {
        Menu {
            ForEach(shortcuts, id: \.self) { n in
                Button { showCustom = false; name = n } label: { Label(n, systemImage: "bolt.fill") }
            }
            Divider()
            Button("Custom…") { showCustom = true }
        } label: {
            Label(menuLabel, systemImage: "bolt.fill")
        }
        .task { shortcuts = await loadShortcutNames(); loaded = true }
        if showsField {
            TextField("Shortcut name", text: $name)
        }
    }
}

// MARK: - Async source loaders

struct AppCandidate: Identifiable {
    let url: URL
    var name: String { url.deletingPathExtension().lastPathComponent }
    var id: String { url.path }
}

/// Scan the standard application directories (shallow + one level deep) for `.app` bundles. The
/// user-facing folders are listed as-is; `CoreServices` (where Finder lives) is filtered to drop
/// background/agent bundles (Dock, SystemUIServer, loginwindow…) so only real apps like Finder show.
func loadInstalledApps() async -> [AppCandidate] {
    await Task.detached(priority: .userInitiated) {
        let fm = FileManager.default
        let openRoots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                         NSHomeDirectory() + "/Applications"]
        let coreRoots = ["/System/Library/CoreServices", "/System/Library/CoreServices/Applications"]

        func appBundles(in root: String) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
            var urls: [URL] = []
            for entry in entries {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    urls.append(URL(fileURLWithPath: path))
                } else if let sub = try? fm.contentsOfDirectory(atPath: path) {
                    // One level deep (e.g. /Applications/<Vendor>/Foo.app).
                    for s in sub where s.hasSuffix(".app") { urls.append(URL(fileURLWithPath: path + "/" + s)) }
                }
            }
            return urls
        }

        var found: [URL] = []
        for root in openRoots { found.append(contentsOf: appBundles(in: root)) }
        for root in coreRoots { found.append(contentsOf: appBundles(in: root).filter(isUserLaunchableApp)) }

        var seen = Set<String>()
        return found
            .filter { seen.insert($0.deletingPathExtension().lastPathComponent).inserted }
            .map(AppCandidate.init)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }.value
}

/// True unless the bundle is a pure background/agent app (`LSUIElement` / `LSBackgroundOnly`), which
/// is how we keep Finder while dropping the CoreServices helpers that shouldn't appear in a launcher.
private func isUserLaunchableApp(_ url: URL) -> Bool {
    guard let info = Bundle(url: url)?.infoDictionary else { return false }
    func flag(_ key: String) -> Bool { (info[key] as? Bool) == true || (info[key] as? String) == "1" }
    return !flag("LSUIElement") && !flag("LSBackgroundOnly")
}

/// Names of the user's Shortcuts via the `shortcuts` CLI (empty if unavailable).
func loadShortcutNames() async -> [String] {
    await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }.value
}

// MARK: - AI command inspector helpers (ported from the former AI-command editor)

/// Prompt-template token quick-insert bar for the AI command inspector.
private struct AITokenBar: View {
    let onInsert: (String) -> Void
    private let tokens = ["{input}", "{date}", "{app}", "{url}"]
    var body: some View {
        HStack(spacing: 6) {
            Text("Insert:").font(.caption).foregroundStyle(.secondary)
            ForEach(tokens, id: \.self) { token in
                Button(token) { onInsert(token) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
    }
}

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

private enum TaskChoice: String, CaseIterable, Identifiable {
    case addToCalendar, addToReminder, newContact, saveToProject, openToolWithPayload, sendTo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addToCalendar: return "Add to Calendar"
        case .addToReminder: return "Add to Reminders"
        case .newContact: return "New Contact"
        case .saveToProject: return "Save to project"
        case .openToolWithPayload: return "Open tool with payload"
        case .sendTo: return "Send to destination"
        }
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

private func aiInputLabel(_ s: InputSource) -> String {
    switch s {
    case .selection: return "Selected text"
    case .clipboard: return "Clipboard"
    case .screenRegion: return "Screen region (vision)"
    case .none: return "No input"
    }
}

