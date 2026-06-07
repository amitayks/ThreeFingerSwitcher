import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The favorites "small IDE": a left **sources** sidebar that browses candidates by type and adds
/// them to the active band, and a **canvas** (bands list + the selected band's items) that arranges
/// everything exactly as the launcher shows it. Every edit writes straight through `FavoritesStore`,
/// which persists immediately, so the launcher reflects changes on its next activation.
///
/// The selected band on the canvas IS the active add target — picking a sourced item drops it there.
struct FavoritesEditorView: View {
    @ObservedObject var store: FavoritesStore

    @State private var selectedBandID: UUID?
    @State private var selectedItemID: UUID?

    var body: some View {
        HSplitView {
            SourcesSidebar(store: store, targetBandID: activeBandID, selectedItemID: $selectedItemID)
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            BandsPane(store: store, selectedBandID: $selectedBandID)
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)

            ItemsPane(store: store, bandID: activeBandID, selectedItemID: $selectedItemID)
                .frame(minWidth: 340, idealWidth: 460, maxWidth: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
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
        case .presets: return "square.stack.3d.up.fill"
        }
    }
}

private struct SourcesSidebar: View {
    @ObservedObject var store: FavoritesStore
    let targetBandID: UUID?
    @Binding var selectedItemID: UUID?
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Add to").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let band = targetBand { Circle().fill(Color(band.color)).frame(width: 10, height: 10) }
                Text(targetBand?.name ?? "—").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var categoryIndex: some View {
        List(SourceCategory.allCases) { cat in
            Button { category = cat } label: {
                Label(cat.rawValue, systemImage: cat.symbol)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
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
            case .paths:     PathPicker { add($0) }
            case .urls:      URLForm { add($0) }
            case .scripts:   ScriptForm { add($0) }
            case .actions:   ActionBrowser { add($0) }
            case .presets:   PresetComposer(store: store) { add($0) }
            }
        }
    }

    private func add(_ item: LaunchItem) {
        guard let id = targetBandID else { return }
        store.addItem(item, toBand: id)
        selectedItemID = item.id   // auto-select the freshly added line so its inspector shows
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

private struct PathPicker: View {
    let onPick: (LaunchItem) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a file or folder to open in its default app.").font(.caption).foregroundStyle(.secondary)
            Button("Choose File or Folder…") { choose() }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(LaunchItem(title: url.lastPathComponent, icon: .fileIcon, kind: .path(url)))
        }
    }
}

private struct URLForm: View {
    let onPick: (LaunchItem) -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var icon: ItemIcon = .sfSymbol("link")
    @State private var tint: ItemColor?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("URL (https://… or app scheme)", text: $address)
            AppearanceEditor(icon: $icon, tint: $tint, naturalIcon: nil)
            Button("Add URL") {
                guard let url = normalizedURL(address) else { return }
                let title = name.isEmpty ? (url.host ?? address) : name
                onPick(LaunchItem(title: title, icon: icon, tint: tint, kind: .url(url)))
                name = ""; address = ""; icon = .sfSymbol("link"); tint = nil
            }
            .disabled(normalizedURL(address) == nil)
        }
        .formStyle(.grouped)
    }

    private func normalizedURL(_ s: String) -> URL? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") || trimmed.contains(":") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)
    }
}

private struct ScriptForm: View {
    let onPick: (LaunchItem) -> Void
    private enum Kind: String, CaseIterable, Identifiable { case shell = "Shell", appleScript = "AppleScript", file = "Script file"; var id: String { rawValue } }
    @State private var name = ""
    @State private var kind: Kind = .shell
    @State private var code = ""
    @State private var fileURL: URL?
    @State private var icon: ItemIcon = .sfSymbol("terminal.fill")
    @State private var tint: ItemColor?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
            switch kind {
            case .shell, .appleScript:
                TextEditor(text: $code).frame(minHeight: 120).font(.system(.body, design: .monospaced))
                    .border(.quaternary)
            case .file:
                HStack {
                    Text(fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Choose…") { chooseFile() }
                }
            }
            AppearanceEditor(icon: $icon, tint: $tint, naturalIcon: nil)
            Button("Add Script") { add() }.disabled(!canAdd)
        }
        .formStyle(.grouped)
    }

    private var canAdd: Bool {
        guard !name.isEmpty else { return false }
        switch kind {
        case .shell, .appleScript: return !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: return fileURL != nil
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { fileURL = panel.url }
    }

    private func add() {
        let body: ScriptBody
        switch kind {
        case .shell: body = .shell(code)
        case .appleScript: body = .appleScript(code)
        case .file: guard let fileURL else { return }; body = .file(fileURL)
        }
        onPick(LaunchItem(title: name, icon: icon, tint: tint, kind: .script(body)))
        name = ""; code = ""; fileURL = nil; icon = .sfSymbol("terminal.fill"); tint = nil
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
        HStack(spacing: 8) {
            Circle().fill(Color(band.color)).frame(width: 12, height: 12)
            Text(band.name)
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
    @State private var dragging: UUID?

    private var band: ContextBand? { store.favorites.bands.first { $0.id == bandID } }

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 14)]

    var body: some View {
        if let band {
            VStack(spacing: 0) {
                grid(band)
                if let itemID = selectedItemID, let item = band.items.first(where: { $0.id == itemID }) {
                    Divider()
                    ItemInspector(store: store, bandID: band.id, item: item).id(item.id)
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
    @State private var name: String

    init(store: FavoritesStore, band: ContextBand) {
        self.store = store; self.band = band
        _name = State(initialValue: band.name)
    }

    var body: some View {
        Form {
            TextField("Band name", text: $name)
                .onChange(of: name) { store.updateBand(band.id) { $0.name = name } }
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
        .frame(height: 168)
    }
}

private struct ItemInspector: View {
    @ObservedObject var store: FavoritesStore
    let bandID: UUID
    let item: LaunchItem
    @State private var title: String

    init(store: FavoritesStore, bandID: UUID, item: LaunchItem) {
        self.store = store; self.bandID = bandID; self.item = item
        _title = State(initialValue: item.title)
    }

    var body: some View {
        Form {
            TextField("Name", text: $title)
                .onChange(of: title) { store.updateItem(item.id, inBand: bandID) { $0.title = title } }
            AppearanceEditor(
                icon: Binding(get: { item.icon },
                              set: { ic in store.updateItem(item.id, inBand: bandID) { $0.icon = ic } }),
                tint: Binding(get: { item.tint },
                              set: { t in store.updateItem(item.id, inBand: bandID) { $0.tint = t } }),
                naturalIcon: naturalIcon(for: item.kind))
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
            if case let .action(action, adjustment) = item.kind, action.isValueAdjustable {
                valueControl(action: action, adjustment: adjustment)
            }
        }
        .formStyle(.grouped)
        .frame(height: inspectorHeight)
    }

    private var inspectorHeight: CGFloat {
        if item.isAppKind { return 300 }
        if case let .action(action, _) = item.kind, action.isValueAdjustable { return 270 }
        return 190
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
}

/// Icon + tint editor shared by the item inspector and the manual url/script forms. Offers a
/// "Default" mode (the app/file icon) only when the kind has one (`naturalIcon`), plus SF Symbol
/// and Emoji modes.
private struct AppearanceEditor: View {
    @Binding var icon: ItemIcon
    @Binding var tint: ItemColor?
    let naturalIcon: ItemIcon?

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
        ColorPicker("Tint", selection: Binding(
            get: { tint.map(Color.init) ?? .accentColor },
            set: { tint = ItemColor($0) }))
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
    case .url, .shortcut, .script, .action, .preset: return nil
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
