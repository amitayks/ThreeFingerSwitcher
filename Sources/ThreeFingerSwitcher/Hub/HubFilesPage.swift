import SwiftUI
import AppKit

// The Files feature page — the configuration surface for the launcher's Files band (a local-only
// Finder-mimic column navigator). Re-homed onto a Hub page and bound to the same `AppSettings`
// properties (same keys/defaults/reset). Like the other feature pages it leads with its master
// enable toggle; every control persists live via `AppSettings`' `didSet`, so there is no Apply step.
//
// Sections, top to bottom: opt-in · Roots (the entry column) · Appearance · Behavior.

struct FilesPage: View {
    /// Stable identity for this page's gesture preview (see `SwitcherPage.previewToken`).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §11.5 — the REAL launcher showing its FILES band: a `LauncherView` over the user's actual bands with
    /// a synthetic Files band appended (the last band, like Clipboard / AI), driven by `filesJourney`
    /// (`bandJourney(bandFraction: 0.66, inSurface: .lift)`) — the full path: 4-finger open → 2-finger
    /// traverse to the Files band → land/lift to open. The Files band here is a STATIC seeded band (the user's
    /// configured roots, no live `FilesColumnController` / drill controller — keeping the preview a pure,
    /// presentation-only seeded model). The holder's `scrub` traverses toward the Files band (the last band)
    /// in sync with the traverse stroke.
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false
    /// The hover-demo override pushed into the preview's driver by the drill-resolution binding rows:
    /// hovering a row demos that action's currently-bound excursion as a directed candidate gesture. `nil`
    /// ⇒ the base open→band→lift journey. (Driven form — mirrors the AI page's `demoGesture` bridge.)
    @State private var demoGesture: GesturePose.DemoGesture?
    /// The excursion the hovered binding row maps to — stashed by the picker's `demoAxis` closure (an
    /// event-handler call) so the `demo` closure can build the matching directed candidate gesture. The
    /// shared `HubBindingPicker` speaks `GesturePose.Axis`; this bridges its hover signal to the driven
    /// preview's `DemoGesture` candidate without changing the component (the AI page's exact idiom).
    @State private var hoveredExcursion: GestureBindings.FilesExcursion?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: Self.filesJourney,
            onScrub: { [weak holder] centroid in holder?.scrub(centroid) },
            onOpen: { [weak holder] in holder?.open() },
            onDismiss: { [weak holder] in holder?.dismiss() }))
    }

    /// The preview's attract journey: open the four-finger launcher → traverse to the Files band → land
    /// and lift to open. The hover-demo override (`demoGesture`) plays a candidate drill excursion instead.
    private static let filesJourney = GesturePose.bandJourney(bandFraction: 0.66, inSurface: .lift)

    /// The coarse axis a Files-drill excursion sweeps along — the `GesturePose.Axis` the shared
    /// `HubBindingPicker` component expects from `demoAxis`. The two lift excursions land-and-open (the
    /// journey's in-surface tail is a dwell-and-lift, no directional travel → `nil` = no axis), while the
    /// four-finger horizontal discard demos a sideways move.
    private func axis(for excursion: GestureBindings.FilesExcursion) -> GesturePose.Axis? {
        switch excursion {
        case .lift, .plusOneFingerLift: return nil
        case .fourFingerHorizontal:     return .horizontal
        }
    }

    /// Map a Files-drill excursion to the directed candidate gesture its hover-demo should play. The two
    /// lift excursions replay the full land-and-open journey (their in-surface tail is a dwell-and-lift);
    /// the four-finger horizontal discard demos a decisive four-finger sideways stroke (the dismiss
    /// finger-count grammar — four fingers discard an open surface).
    private func candidate(for excursion: GestureBindings.FilesExcursion) -> GesturePose.DemoGesture {
        switch excursion {
        case .lift, .plusOneFingerLift:
            return Self.filesJourney
        case .fourFingerHorizontal:
            // A standalone four-finger leftward discard stroke (carries the hand angle/bow + a lift + loop).
            let mid: CGFloat = 0.5
            return GesturePose.DemoGesture(strokes: [
                GesturePose.Stroke(fingers: 4,
                                   from: CGPoint(x: 0.78, y: mid),
                                   to: CGPoint(x: 0.22, y: mid))
            ], liftGap: 0.6)
        }
    }

    /// Seed once with the user's real bands + a synthetic Files band appended as the LAST band, then point
    /// the holder's scrub at the last band (the Files band) so the traverse stroke lands on it. Degrades
    /// gracefully through `HubPreviewModels` (the real bands always; sample roots when none are configured).
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        // The user's real bands (clipboard / AI off here — this page demos the Files band), then a static
        // Files band appended last, built from the configured roots (no live drill controller).
        let base = models.makeLauncherModel(clipboardOn: false, aiOn: false,
                                            dwell: settings.dwellToArmDuration)
        demo.seed(from: appendingFilesBand(to: base), traverseToLastBand: true)
    }

    /// Build a fresh `LauncherModel` that is `base` plus a synthetic **Files band** appended as the last
    /// band — a STATIC seeded band (no `FilesColumnController`), its column the user's configured roots (or
    /// sample folders when none are set), so the demo's "traverse to the Files band" lands on a real-looking
    /// Files band. The Files band's sentinel id / tint / icon come from `FilesBandBuilder`, so it reads
    /// exactly like the live band; only the live drill is omitted (this is presentation-only).
    private func appendingFilesBand(to base: LauncherModel) -> LauncherModel {
        let filesBand = FilesBandBuilder.build(currentColumn: sampleFilesColumn())
        var bands = base.bands
        var names = base.bandNames
        var colors = base.bandColors
        var icons = base.bandIcons
        bands.append(filesBand.items)
        names.append(filesBand.name)
        colors.append(filesBand.color)
        icons.append(filesBand.resolvedIcon)
        let filesIndex = bands.count - 1

        let model = LauncherModel()
        model.dwell = base.dwell
        model.setBands(bands, names: names, colors: colors, icons: icons,
                       startBand: 0, column: 0,
                       clipboardBandIndex: base.clipboardBandIndex,
                       filesBandIndex: filesIndex)
        return model
    }

    /// The Files band's current-column entries for the demo: each configured root as a folder `FileEntry`
    /// (the band's first column is its roots). Falls back to a few common folders so the band reads alive
    /// when the user has not configured any roots yet — degrading gracefully like the rest of the Hub demos.
    private func sampleFilesColumn() -> [FileEntry] {
        let paths = settings.filesRoots.isEmpty
            ? ["~/Desktop", "~/Documents", "~/Downloads", "~/Pictures"].map { ($0 as NSString).expandingTildeInPath }
            : settings.filesRoots
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            return FileEntry(url: url, name: name, isDirectory: true,
                             modificationDate: nil, kind: .folder)
        }
    }

    var body: some View {
        HubPage(HubDestination.files.title,
                subtitle: "A four-finger Files band — pilot your local folders, preview, and open by trackpad.") {
            HubSection(footnote: "Adds a local-only column navigator as a band in the four-finger launcher: drill into your folders horizontally, highlight vertically, lift to deliver the item to the app you came from — or open it (your choice) — and add a finger for the action menu. Reads the local filesystem on demand — no new permission, no logout, nothing copied off this Mac. Off by default.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(driver: driver) {
                        FilesDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.files.systemImage,
                    title: HubDestination.files.title,
                    subtitle: "Pilot your local folders, preview, and open them by trackpad.",
                    isOn: $settings.filesBandEnabled,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
                )
                .onAppear { seedIfNeeded() }
                .onChange(of: demoGesture) { _, new in driver.hoverGesture = new }
            }

            drillBindingSection
            actionMenuSection
            rootsSection
            appearanceSection
            behaviorSection
        }
    }

    // MARK: - Action menu (the +1-finger menu — what it offers, per type)

    /// The configuration for the action menu a `+1`-finger lift opens over the highlighted item: what a lift
    /// itself does (deliver vs open), the per-type item lists (add / remove / reorder from the catalog), and
    /// which detected terminals/editors appear under "Open in". Persists live via `AppSettings`.
    private var actionMenuSection: some View {
        HubSection("Action menu",
                   footnote: "A +1-finger lift opens an action menu over the highlighted item. Choose what a plain lift does, customize the menu for files and folders, and pick which terminals/editors it can open folders in. Defaults match the built-in menus.") {
            Picker("When you lift on an item", selection: $settings.filesLiftAction) {
                ForEach(FilesLiftAction.allCases) { Text(liftActionLabel($0)).tag($0) }
            }
            Text(settings.filesLiftAction == .deliver
                 ? "Lifting delivers the item to the app you came from — its path into a text field, the file into Finder. Add a finger for the action menu."
                 : "Lifting opens the item (file → default app, folder → Finder). Add a finger for the action menu.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            menuEditor(title: "File menu", isFolder: false)
            Divider()
            menuEditor(title: "Folder menu", isFolder: true)
            Divider()
            toolsCuration
        }
        .disabled(!settings.filesBandEnabled)
    }

    /// One per-type menu editor: the ordered catalog items (reorder / remove), plus an "Add item" menu of the
    /// catalog actions not already present. Mirrors `rootsSection`'s row affordances.
    @ViewBuilder
    private func menuEditor(title: String, isFolder: Bool) -> some View {
        let items = isFolder ? settings.filesActionMenu.folderItems : settings.filesActionMenu.fileItems
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            ForEach(Array(items.enumerated()), id: \.element) { index, action in
                HStack(spacing: 8) {
                    Image(systemName: FilesBandView.menuRowGlyph(.action(action)))
                        .foregroundStyle(.secondary).frame(width: 18)
                    Text(FilesBandView.menuRowLabel(.action(action))).font(.callout)
                    Spacer(minLength: 8)
                    Button { moveMenuItem(isFolder: isFolder, index: index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(index == 0).help("Move up")
                    Button { moveMenuItem(isFolder: isFolder, index: index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(index == items.count - 1).help("Move down")
                    Button { removeMenuItem(isFolder: isFolder, action: action) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from this menu")
                }
                .contentShape(Rectangle())
            }
            let available = FilesMenuAction.allCases.filter { !items.contains($0) }
            if !available.isEmpty {
                Menu {
                    ForEach(available) { action in
                        Button { addMenuItem(isFolder: isFolder, action: action) } label: {
                            Label(FilesBandView.menuRowLabel(.action(action)),
                                  systemImage: FilesBandView.menuRowGlyph(.action(action)))
                        }
                    }
                } label: { Label("Add item", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    /// The detected terminals/editors, each toggleable — disabling one drops it from the folder menu's tool
    /// rows and the folder "Open in" grid (curation = "all detected, minus the disabled").
    private var toolsCuration: some View {
        let tools = installedTools(FilesToolCatalog.terminals, role: .terminal)
            + installedTools(FilesToolCatalog.editors, role: .editor)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Open folders in").font(.callout)
            if tools.isEmpty {
                Text("No supported terminals or editors detected on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(tools) { tool in
                Toggle(isOn: toolEnabledBinding(tool.bundleID)) {
                    Label(tool.name, systemImage: tool.role == .editor
                          ? "chevron.left.forward.slash.chevron.right" : "terminal")
                }
            }
        }
    }

    /// The catalog tools of `role` that are actually installed (a bundle-id probe), with the user's
    /// enable state applied — used only to render the curation toggles.
    private func installedTools(_ seeds: [(bundleID: String, name: String)], role: FilesTool.Role) -> [FilesTool] {
        seeds.compactMap { seed in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: seed.bundleID) != nil else { return nil }
            return FilesTool(bundleID: seed.bundleID, name: seed.name, role: role,
                             enabled: !settings.filesToolsDisabled.contains(seed.bundleID))
        }
    }

    private func toolEnabledBinding(_ bundleID: String) -> Binding<Bool> {
        Binding(get: { !settings.filesToolsDisabled.contains(bundleID) },
                set: { on in
                    if on { settings.filesToolsDisabled.removeAll { $0 == bundleID } }
                    else if !settings.filesToolsDisabled.contains(bundleID) { settings.filesToolsDisabled.append(bundleID) }
                })
    }

    private func addMenuItem(isFolder: Bool, action: FilesMenuAction) {
        var menu = settings.filesActionMenu
        if isFolder { menu.folderItems.append(action) } else { menu.fileItems.append(action) }
        settings.filesActionMenu = menu
    }

    private func removeMenuItem(isFolder: Bool, action: FilesMenuAction) {
        var menu = settings.filesActionMenu
        if isFolder { menu.folderItems.removeAll { $0 == action } } else { menu.fileItems.removeAll { $0 == action } }
        settings.filesActionMenu = menu
    }

    private func moveMenuItem(isFolder: Bool, index: Int, by delta: Int) {
        var menu = settings.filesActionMenu
        var list = isFolder ? menu.folderItems : menu.fileItems
        let target = index + delta
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        if isFolder { menu.folderItems = list } else { menu.fileItems = list }
        settings.filesActionMenu = menu
    }

    private func liftActionLabel(_ a: FilesLiftAction) -> String {
        switch a {
        case .deliver: return "Deliver it to the front app"
        case .open:    return "Open it"
        }
    }

    // MARK: - Drill resolution bindings (7.2)

    /// Map the Files drill's three resolution actions — open / Open-With / discard — onto its excursion
    /// vocabulary (lift · +1-finger lift · four-finger sideways), via the shared `HubBindingPicker`.
    /// Choosing routes through the pure `FilesDrillBinding.assigning(_:to:)`, which keeps the map one-to-one
    /// (picking a taken move swaps it). Defaults to today's behavior; hovering a row demos it in the preview.
    private var drillBindingSection: some View {
        HubSection("Resolve gestures",
                   footnote: "Choose which trackpad move runs the lift action, opens the action menu, or discards the highlighted item while the Files band is open. Each move maps to one action — picking a taken move swaps it. A discard never closes a running app. Hover a row to preview the move above.") {
            HubBindingPicker(
                actions: GestureBindings.FilesAction.allCases,
                excursions: GestureBindings.FilesExcursion.allCases,
                actionLabel: HubBindingLabels.filesAction,
                excursionLabel: HubBindingLabels.files,
                current: { settings.gestureBindings.filesDrill.excursion(for: $0) },
                assign: { excursion, action in
                    settings.gestureBindings.filesDrill = settings.gestureBindings.filesDrill.assigning(excursion, to: action)
                },
                demoAxis: { excursion in
                    // Stash the hovered excursion (event-handler context) so `demo` can build the matching
                    // directed candidate; return the coarse axis the component expects (nil for a lift).
                    hoveredExcursion = excursion
                    return axis(for: excursion)
                },
                demo: { _ in
                    // The component signals enter (it just called `demoAxis`) / exit (nil). On enter, build a
                    // directed candidate for the hovered excursion; on exit, clear the override. Lift
                    // excursions have a nil axis but a real candidate (the land-and-open journey), so key the
                    // enter/exit off `hoveredExcursion` being set rather than the axis being non-nil.
                    demoGesture = hoveredExcursion.map { candidate(for: $0) }
                    hoveredExcursion = nil
                }
            )
            .disabled(!settings.filesBandEnabled)
        }
    }

    // MARK: - Roots (12.2)

    /// The entry column: the local root folders the band opens onto. Add (a directories-only open
    /// panel), remove, and reorder, persisting to `settings.filesRoots` (absolute paths). The app is
    /// unsandboxed, so plain paths suffice — no security-scoped bookmarks. Non-local (network / iCloud)
    /// selections are rejected with an inline note.
    private var rootsSection: some View {
        HubSection("Root folders",
                   footnote: "These are the band's first column — where each drill-in starts. Local folders only; network shares and iCloud-only locations are rejected. The band restores where you last left off in each root.") {
            if settings.filesRoots.isEmpty {
                Text("No roots yet. Add folders like Home, Desktop, Downloads, or any project folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(settings.filesRoots.enumerated()), id: \.element) { index, path in
                    rootRow(index: index, path: path)
                    if index < settings.filesRoots.count - 1 { Divider() }
                }
            }

            if let rejection {
                Label(rejection, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button { addRoots() } label: { Label("Add folder…", systemImage: "plus") }
                Spacer()
            }
        }
        .disabled(!settings.filesBandEnabled)
    }

    private func rootRow(index: Int, path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent.isEmpty ? path : url.lastPathComponent).font(.callout)
                Text(abbreviate(path)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // Reorder: a root higher in the list is offered higher in the band's entry column.
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(index == 0)
                .help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .disabled(index == settings.filesRoots.count - 1)
                .help("Move down")
            Button { settings.filesRoots.removeAll { $0 == path } } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Remove this root")
        }
        .contentShape(Rectangle())
    }

    // MARK: - Appearance (12.3)

    /// Column width / density / tint / icon-vs-preview. Width and tint are the bounded-overlay knobs;
    /// density packs the current-list rows; the tint is the band's accent (stored as a `#RRGGBB` hex).
    private var appearanceSection: some View {
        HubSection("Appearance") {
            LabeledSlider(title: "Column width", value: $settings.filesColumnWidth,
                          range: 180...420, format: "%.0f pt",
                          help: "Width of the current-folder column. The overlay stays bounded at any depth — ancestors collapse to a thin icon rail.")

            Picker("Row density", selection: $settings.filesDensity) {
                ForEach(FilesDensity.allCases) { Text(densityLabel($0)).tag($0) }
            }

            Picker("Row leading glyph", selection: $settings.filesIconStyle) {
                ForEach(FilesIconStyle.allCases) { Text(iconStyleLabel($0)).tag($0) }
            }
            Text(settings.filesIconStyle == .preview
                 ? "Rows lead with a QuickLook thumbnail when one is available (icon fallback)."
                 : "Rows lead with the cheap file/folder type icon — no QuickLook churn while scrubbing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ColorPicker("Accent tint", selection: tintBinding, supportsOpacity: false)
        }
        .disabled(!settings.filesBandEnabled)
    }

    // MARK: - Behavior (12.4)

    /// Sort field + direction · default-open action · which metadata a row shows. The metadata is an
    /// `OptionSet`, so it's a set of independent toggles (any/all may show at once).
    private var behaviorSection: some View {
        HubSection("Behavior") {
            Picker("Sort folders by", selection: $settings.filesSortField) {
                ForEach(FilesSortField.allCases) { Text(sortFieldLabel($0)).tag($0) }
            }
            Picker("Order", selection: $settings.filesSortDirection) {
                ForEach(FilesSortDirection.allCases) { Text(sortDirectionLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)

            Divider()

            Picker("When you open a file", selection: $settings.filesDefaultOpen) {
                ForEach(FilesDefaultOpen.allCases) { Text(defaultOpenLabel($0)).tag($0) }
            }
            Text("Applies when the lift action above is set to Open. "
                 + (settings.filesDefaultOpen == .openWith
                    ? "Opening a file shows the Open-With chooser."
                    : "Opening a file launches its default app.")
                 + " (Folders always open as a Finder window; the action menu’s “Open in ▸” is always available.)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Show beside each name").font(.callout)
                Toggle("Modified date", isOn: metadataBinding(.date))
                Toggle("Kind", isOn: metadataBinding(.kind))
                Toggle("Size", isOn: metadataBinding(.size))
            }

            Divider()

            // Restore-last-folder (refinement 2): when on (default), opening the Files band lands on AND
            // displays the last folder visited in that root — restored AT OPEN, so the column already shows
            // it while the highlight is still on the band icon, and crossing horizontally lands there with no
            // jump. Off opens fresh on the configured roots list.
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Remember and reopen the last folder", isOn: $settings.filesRememberLocation)
                Text(settings.filesRememberLocation
                     ? "Opening the Files band lands on the last folder you visited in that root — already shown before you cross in."
                     : "The Files band opens fresh on your root folders each time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!settings.filesBandEnabled)
    }

    // MARK: - Roots actions

    @State private var rejection: String?

    /// Present a directories-only open panel and append every accepted **local** selection. Network /
    /// iCloud selections are dropped with an inline note. Unsandboxed ⇒ plain absolute paths, no bookmarks.
    private func addRoots() {
        rejection = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose local folders to use as Files-band roots."
        guard panel.runModal() == .OK else { return }

        var rejected: [String] = []
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard Self.isLocalFolder(url) else { rejected.append(url.lastPathComponent); continue }
            if !settings.filesRoots.contains(path) { settings.filesRoots.append(path) }
        }
        if !rejected.isEmpty {
            rejection = "Skipped \(rejected.joined(separator: ", ")): the Files band is local-only (network shares and iCloud-only folders aren't supported)."
        }
    }

    /// Move the root at `index` by `delta` (clamped), nudging the band's entry-column order.
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard settings.filesRoots.indices.contains(index),
              settings.filesRoots.indices.contains(target) else { return }
        settings.filesRoots.swapAt(index, target)
    }

    /// Local-only gate for a chosen root: reject iCloud placeholders and non-local (network) volumes.
    /// Mirrors the lister's `.isUbiquitousItemKey` skip, adding `.volumeIsLocalKey` for network shares.
    private static func isLocalFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        if values?.isUbiquitousItem == true { return false }
        if let isLocal = values?.volumeIsLocal { return isLocal }
        return true   // unknown volume locality ⇒ allow (e.g. the boot volume reports nil on some setups)
    }

    /// Collapse a long home-relative path to `~/…` for the row's secondary line.
    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Bindings

    /// Bridge the persisted `#RRGGBB` hex string to/from a SwiftUI `Color` for the `ColorPicker`. The
    /// app keeps the tint as a single plist-native hex property (no nested model), so the conversion
    /// lives here rather than on `AppSettings`.
    private var tintBinding: Binding<Color> {
        Binding(get: { Self.color(fromHex: settings.filesBandTint) },
                set: { settings.filesBandTint = Self.hex(from: $0) })
    }

    /// A single member of the `filesRowMetadata` `OptionSet` as a Bool toggle.
    private func metadataBinding(_ option: FilesRowMetadata) -> Binding<Bool> {
        Binding(get: { settings.filesRowMetadata.contains(option) },
                set: { on in
                    var set = settings.filesRowMetadata
                    if on { set.insert(option) } else { set.remove(option) }
                    settings.filesRowMetadata = set
                })
    }

    // MARK: - Hex ⇄ Color (via NSColor sRGB, matching the app's ItemColor bridge)

    private static func color(fromHex hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return .accentColor }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    private static func hex(from color: Color) -> String {
        let ns = (NSColor(color).usingColorSpace(.sRGB)) ?? .gray
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Enum labels

    private func densityLabel(_ d: FilesDensity) -> String {
        switch d {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    private func iconStyleLabel(_ s: FilesIconStyle) -> String {
        switch s {
        case .icon: return "Type icon"
        case .preview: return "Preview thumbnail"
        }
    }

    private func sortFieldLabel(_ f: FilesSortField) -> String {
        switch f {
        case .name: return "Name"
        case .date: return "Date modified"
        case .kind: return "Kind"
        }
    }

    private func sortDirectionLabel(_ d: FilesSortDirection) -> String {
        switch d {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }

    private func defaultOpenLabel(_ o: FilesDefaultOpen) -> String {
        switch o {
        case .defaultApp: return "Open in the default app"
        case .openWith: return "Show the Open-With chooser"
        }
    }
}

// MARK: - §11.5 Files demo miniature (the real launcher, showing the Files band)

/// The §11.5 Files-page miniature: the **real** `LauncherView` over the holder's seeded model (the user's
/// bands + a synthetic Files band appended last), scaled to a tasteful Hub mini and launched in / receded
/// with the holder's `launched` flag — a soft morph, exactly like the Launcher / Clipboard / AI demo
/// miniatures (and the onboarding playground). It takes no hits (the preview disables hit-testing). The
/// `HubDemoDriver` traverses the band selection to the Files band in sync with the demonstrated journey.
private struct FilesDemoMiniature: View {
    @ObservedObject var demo: HubLauncherDemo

    var body: some View {
        LauncherView(model: demo.model, executor: nil, availability: nil)
            .scaleEffect(0.5)
            .frame(width: 360, height: 150)
            .opacity(demo.launched ? 1 : 0.14)
            .scaleEffect(demo.launched ? 1 : 0.95)
            .animation(.easeInOut(duration: 0.3), value: demo.launched)
    }
}
