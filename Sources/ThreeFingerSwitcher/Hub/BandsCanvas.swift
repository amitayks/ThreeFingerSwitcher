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
            SourcesSidebar(store: store, targetBandID: activeBandID,
                           selectedItemID: $selectedItemID, autoFocusItemID: $autoFocusItemID)
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            BandsPane(store: store, selectedBandID: $selectedBandID)
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)

            ItemsPane(store: store, bandID: activeBandID,
                      selectedItemID: $selectedItemID, autoFocusItemID: $autoFocusItemID)
                .frame(minWidth: 300, idealWidth: 440, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedBandID == nil { selectedBandID = store.favorites.bands.first?.id }
        }
    }

    /// The effective add target: the selection if still valid, else the first band.
    private var activeBandID: UUID? {
        if let id = selectedBandID, store.favorites.bands.contains(where: { $0.id == id }) { return id }
        return store.favorites.bands.first?.id
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
        case .presets: return "square.stack.3d.up.fill"
        }
    }
}

private struct SourcesSidebar: View {
    @ObservedObject var store: FavoritesStore
    let targetBandID: UUID?
    @Binding var selectedItemID: UUID?
    @Binding var autoFocusItemID: UUID?
    @State private var category: SourceCategory?

    private var targetBand: ContextBand? {
        store.favorites.bands.first { $0.id == targetBandID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if targetBandID == nil {
                ContentUnavailable("Create a band first", systemImage: "tray", caption: "Add a band on the canvas, then pick items to drop into it.")
            } else if let category {
                categoryBrowser(category)
            } else {
                categoryIndex
            }
        }
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add to").font(.caption).foregroundStyle(.secondary)
            if let band = targetBand {
                BandIconView(band: band, size: 24)
            } else {
                Text("—").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var categoryIndex: some View {
        List(SourceCategory.allCases) { cat in
            Button { activate(cat) } label: {
                Label(cat.rawValue, systemImage: cat.symbol)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    /// URLs / Scripts / Files&Folders add an item immediately and open it for editing in the item panel
    /// (Files pick a path first, since a file item needs one); the rest drill into a browser of candidates.
    private func activate(_ cat: SourceCategory) {
        switch cat {
        case .urls:    add(.newLink(), focus: true)
        case .scripts: add(.newScript(), focus: true)
        case .paths:   choosePath()
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

    @ViewBuilder
    private func categoryBrowser(_ cat: SourceCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { category = nil } label: { Label("All sources", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            switch cat {
            case .apps:      AppBrowser { add($0) }
            case .shortcuts: ShortcutBrowser { add($0) }
            case .actions:   ActionBrowser { add($0) }
            case .aiCommands: AICommandSource(store: store) { add($0) }
            case .presets:   PresetComposer(store: store) { add($0) }
            // Immediate-add sources never drill in (handled by `activate`); never reached.
            case .urls, .scripts, .paths: EmptyView()
            }
        }
    }

    private func add(_ item: LaunchItem, focus: Bool = false) {
        guard let id = targetBandID else { return }
        store.addItem(item, toBand: id)
        selectedItemID = item.id   // auto-select the freshly added line so its inspector shows
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
                List(shown) { app in
                    Button {
                        onPick(LaunchItem(title: app.name, icon: .appDefault,
                                          kind: .app(bundleURL: app.url, strategy: nil)))
                    } label: {
                        Label { Text(app.name) } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 18, height: 18)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
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
                List(names, id: \.self) { name in
                    Button {
                        onPick(LaunchItem(title: name, icon: .sfSymbol("bolt.fill"), kind: .shortcut(name: name)))
                    } label: { Label(name, systemImage: "bolt.fill") }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
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
        List {
            ForEach(SystemAction.Category.allCases) { category in
                Section(category.rawValue) {
                    ForEach(SystemAction.allCases.filter { $0.category == category }) { action in
                        Button {
                            onPick(LaunchItem(title: action.title, icon: .sfSymbol(action.symbol), kind: .action(action)))
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .buttonStyle(.plain)
                        .help(action.detail)
                    }
                }
            }
        }
        .listStyle(.inset)
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
        List {
            ForEach(AICommandCatalog.Category.allCases) { category in
                Section {
                    ForEach(AICommandCatalog.commands(in: category)) { preset in
                        Button {
                            onPick(AIBand.item(for: AICommandCatalog.copy(of: preset)))
                        } label: {
                            Label(preset.name, systemImage: symbolName(preset.icon))
                        }
                        .buttonStyle(.plain)
                        .help(preset.promptTemplate)
                    }
                } header: {
                    HStack {
                        Label(category.title, systemImage: category.sfSymbol)
                        Spacer()
                        Button("Add all as a band") { addCategoryAsBand(category) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.caption)
                            .help("Create a new \"\(category.title)\" band populated with these presets.")
                    }
                }
            }
            Section {
                Button {
                    let cmd = AICommand(name: "New Command", icon: .sfSymbol("wand.and.stars"),
                                        input: .selection, promptTemplate: "{input}", output: .previewOnly)
                    onPick(AIBand.item(for: cmd))
                } label: {
                    Label("Custom command", systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .help("Add a blank AI command, then edit its prompt, input, and output on the right.")
            }
        }
        .listStyle(.inset)
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

private struct BandsPane: View {
    @ObservedObject var store: FavoritesStore
    @Binding var selectedBandID: UUID?

    private var selectedBand: ContextBand? { store.favorites.bands.first { $0.id == selectedBandID } }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedBandID) {
                ForEach(store.favorites.bands) { band in
                    BandRow(band: band) { deleteBand(band) }
                        .tag(band.id)
                }
                .onMove { store.moveBands(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack {
                Button { addBand() } label: { Label("Band", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
            // The band editor lives directly below the band list.
            if let band = selectedBand {
                Divider()
                BandInspector(store: store, band: band).id(band.id)
            }
        }
    }

    private func addBand() {
        let hue = Double(store.favorites.bands.count) * 0.16
        let color = ItemColor(NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 0.85, alpha: 1))
        selectedBandID = store.addBand(color: color)
    }

    private func deleteBand(_ band: ContextBand) {
        let wasSelected = selectedBandID == band.id
        store.removeBand(band.id)
        if wasSelected { selectedBandID = store.favorites.bands.first?.id }
    }
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

// MARK: - Items pane (grid on top, item editor below)

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

/// One grid cell: icon + label. When selected it highlights and shows a trash badge on top; a second
/// click on the cell (or a click on the badge) deletes it.
private struct ItemGridCell: View {
    let item: LaunchItem
    let selected: Bool
    let onTap: () -> Void
    let onTrash: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                LaunchItemIconView(item: item, size: 44)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                if selected {
                    Button(action: onTrash) {
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
            Text(item.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(selected ? .primary : .secondary)
            Text(kindLabel(item.kind)).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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

    var body: some View {
        Form {
            // A band is identified by its ICON, not a name (the launcher shows icons only). Reuses the
            // item icon picker; the band's own Color below tints it, so the per-icon tint is hidden.
            AppearanceEditor(
                icon: Binding(get: { band.resolvedIcon },
                              set: { ic in store.updateBand(band.id) { $0.icon = ic } }),
                tint: .constant(nil),
                naturalIcon: nil,
                showTint: false)
            ColorPicker("Color", selection: Binding(
                get: { Color(band.color) },
                set: { newColor in store.updateBand(band.id) { $0.color = ItemColor(newColor) } }))
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
            TextField("Name", text: $title)
                .focused($focus, equals: .name)
                .onChange(of: title) { store.updateItem(item.id, inBand: bandID) { $0.title = title } }
            AppearanceEditor(
                icon: Binding(get: { item.icon },
                              set: { ic in store.updateItem(item.id, inBand: bandID) { $0.icon = ic } }),
                tint: Binding(get: { item.tint },
                              set: { t in store.updateItem(item.id, inBand: bandID) { $0.tint = t } }),
                naturalIcon: naturalIcon(for: item.kind))
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

    private var aiForm: some View {
        ScrollView {
            Form {
                Section("Identity") {
                    TextField("Name", text: $title)
                        .onChange(of: title) { updateCommand { $0.name = title } }
                    AppearanceEditor(
                        icon: Binding(get: { ai.icon }, set: { ic in updateCommand { $0.icon = ic } }),
                        tint: Binding(get: { ai.tint }, set: { t in updateCommand { $0.tint = t } }),
                        naturalIcon: nil)
                }
                Section("Input") {
                    Picker("Input source", selection: Binding(
                        get: { ai.input }, set: { src in updateCommand { $0.input = src } })) {
                        ForEach(InputSource.allCases, id: \.self) { Text(aiInputLabel($0)).tag($0) }
                    }
                    Text(aiInputHelp(ai.input)).font(.caption).foregroundStyle(.secondary)
                }
                Section("Prompt") {
                    AITokenBar { insertToken($0) }
                    TextEditor(text: $prompt)
                        .frame(minHeight: 110)
                        .font(.system(.body, design: .monospaced))
                        .border(.quaternary)
                        .onChange(of: prompt) { updateCommand { $0.promptTemplate = prompt } }
                    Text("Tokens are substituted at fire time: {input} the acquired text, {date} today, {app} the front app, {url} the front document URL. Unknown braces are left as-is.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Output") { aiOutputEditor }
                Section("Model") { aiModelEditor }
                Section("Reasoning") { aiReasoningEditor }
                Section("Confirmation") {
                    Toggle("Confirm before running", isOn: Binding(
                        get: { ai.confirmBeforeRun }, set: { on in updateCommand { $0.confirmBeforeRun = on } }))
                    Text(ai.output.isSideEffecting
                         ? "This output has a side effect; confirmation defaults on, but you can turn it off for a trusted command."
                         : "In-place edits don't ask by default; turn this on to review the result before it's applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { moveToBandControl }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)
        }
        .frame(height: 380)
    }

    @ViewBuilder
    private var aiOutputEditor: some View {
        Picker("Output target", selection: Binding(
            get: { outputChoice(ai.output) }, set: { setOutputChoice($0) })) {
            ForEach(OutputChoice.allCases) { Text($0.label).tag($0) }
        }
        Text(aiOutputLabel(ai.output)).font(.caption).foregroundStyle(.secondary)
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

    @ViewBuilder
    private var aiModelEditor: some View {
        let registry = ModelRegistry.standard
        Picker("Model", selection: Binding(
            get: { selectedModelID(ai.model) }, set: { id in updateCommand { $0.model = .onDevice(modelID: id) } })) {
            Text("Registry default").tag(String?.none)
            ForEach(registry.models) { m in Text(m.displayName).tag(Optional(m.id)) }
        }
        Text("On-device Gemma 4. \"Registry default\" tracks the recommended model; pin a specific one only if you need it.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var aiReasoningEditor: some View {
        Picker("Reasoning", selection: Binding(
            get: { ai.reasoning }, set: { r in updateCommand { $0.reasoning = r } })) {
            Text("Default").tag(AIReasoning?.none)
            Text("On").tag(Optional(AIReasoning.on))
            Text("Off").tag(Optional(AIReasoning.off))
        }
        Text("Default follows the AI Reasoning toggle; override per command.")
            .font(.caption).foregroundStyle(.secondary)
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

/// Icon + tint editor shared by the item inspector and the manual url/script forms. Offers a
/// "Default" mode (the app/file icon) only when the kind has one (`naturalIcon`), plus SF Symbol
/// and Emoji modes.
private struct AppearanceEditor: View {
    @Binding var icon: ItemIcon
    @Binding var tint: ItemColor?
    let naturalIcon: ItemIcon?
    /// When false, the per-icon Tint picker is hidden (e.g. a band, which already has its own color).
    var showTint: Bool = true

    private enum Mode: Hashable { case auto, symbol, emoji }

    private var mode: Mode {
        switch icon {
        case .appDefault, .fileIcon: return .auto
        case .sfSymbol: return .symbol
        case .emoji: return .emoji
        }
    }

    var body: some View {
        Picker("Icon", selection: Binding(get: { mode }, set: { setMode($0) })) {
            if naturalIcon != nil { Text("Default").tag(Mode.auto) }
            Text("SF Symbol").tag(Mode.symbol)
            Text("Emoji").tag(Mode.emoji)
        }
        if case .sfSymbol = icon {
            SymbolPickerRow(icon: $icon)
        } else if case .emoji = icon {
            EmojiPickerRow(icon: $icon)
        }
        if showTint {
            ColorPicker("Tint", selection: Binding(
                get: { tint.map(Color.init) ?? .accentColor },
                set: { tint = ItemColor($0) }))
        }
    }

    private func setMode(_ m: Mode) {
        switch m {
        case .auto:   if let n = naturalIcon { icon = n }
        case .symbol: if case .sfSymbol = icon {} else { icon = .sfSymbol("star.fill") }
        case .emoji:  if case .emoji = icon {} else { icon = .emoji("⭐️") }
        }
    }
}

private func naturalIcon(for kind: LaunchItemKind) -> ItemIcon? {
    switch kind {
    case .app: return .appDefault
    case .path: return .fileIcon
    case .url, .shortcut, .script, .action, .preset, .clipboardEntry, .aiCommand: return nil
    }
}

/// SF Symbol chooser: a preview + a typed fallback + a popover grid of curated symbols (searchable).
private struct SymbolPickerRow: View {
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

/// Emoji chooser: a preview + a typed fallback + a popover grid of curated emoji, plus a button to
/// open the full macOS emoji & symbols viewer (inserts into the focused field).
private struct EmojiPickerRow: View {
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

/// A curated set of common SF Symbols for the icon picker (typing any other name still works).
let curatedSFSymbols: [String] = [
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

/// A curated set of common emoji for the quick grid (the system viewer covers everything else).
let curatedEmojis: [String] = [
    "⭐️", "🔥", "💡", "🚀", "✨", "🎯", "📌", "🏆", "🎉", "🎁",
    "📁", "📂", "📄", "🗂️", "🗃️", "📦", "🧰", "🛠️", "🔧", "⚙️",
    "💻", "🖥️", "⌨️", "🖱️", "📱", "⌚️", "🎮", "🎧", "🎵", "🎬",
    "📷", "📸", "🎨", "✏️", "📝", "📚", "🔖", "🗺️", "📍", "🧭",
    "🏠", "🏢", "🏦", "🛒", "💳", "💰", "💵", "📊", "📈", "📉",
    "✅", "❌", "⚠️", "⛔️", "🔒", "🔓", "🔑", "🛡️", "🔔", "🏷️",
    "🌐", "🔗", "✉️", "📨", "💬", "📞", "📅", "⏰", "⏱️", "⏳",
    "🧠", "🤖", "👤", "👥", "🫶", "👍", "🙌", "💪", "🧪", "🔬",
    "☕️", "🍔", "🍕", "🍎", "🌙", "☀️", "☁️", "⚡️", "💧", "🍃",
    "🐙", "🐳", "🦊", "🐱", "🦄", "🐢", "❤️", "💙", "💚", "💜",
    "🟠", "🟢", "🔵", "🟣", "⚫️", "⭕️", "▶️", "⏸️", "⏹️", "🆕",
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
    case .aiCommand: return "AI Command"
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

private func aiInputHelp(_ s: InputSource) -> String {
    switch s {
    case .selection: return "The front app's selected text (falls back to the clipboard when nothing is selected)."
    case .clipboard: return "The current clipboard contents."
    case .screenRegion: return "A captured screen region, fed to a vision-capable model."
    case .none: return "No input — the prompt template stands alone."
    }
}

private func aiOutputLabel(_ o: OutputTarget) -> String {
    switch o {
    case .replaceSelection: return "Replace the selected text with the result."
    case .pasteAtCursor: return "Paste the result at the cursor."
    case .previewOnly: return "Show the result in the preview only; write nothing back."
    case let .runTask(kind): return "Run task: \(aiTaskLabel(kind))."
    case let .sendTo(dest): return "Send to \(aiDestinationLabel(dest))."
    }
}

private func aiTaskLabel(_ k: TaskKind) -> String {
    switch k {
    case .addToCalendar: return "Add to Calendar"
    case .addToReminder: return "Add to Reminders"
    case .newContact: return "New Contact"
    case let .saveToProject(p): return "Save to project \(p.isEmpty ? "…" : p)"
    case let .openToolWithPayload(t): return "Open \(t.isEmpty ? "tool" : t) with payload"
    case let .sendTo(d): return "Send to \(aiDestinationLabel(d))"
    }
}

private func aiDestinationLabel(_ d: Destination) -> String {
    switch d {
    case let .shortcut(n): return "Shortcut \(n.isEmpty ? "…" : n)"
    case let .urlScheme(s): return "URL \(s.isEmpty ? "…" : s)"
    case let .shell(c): return "Shell \(c.isEmpty ? "…" : c)"
    }
}
