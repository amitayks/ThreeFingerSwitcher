import SwiftUI
import AppKit

// The Files feature page — the configuration surface for the launcher's Files band (a local-only
// Finder-mimic column navigator). Re-homed onto a Hub page and bound to the same `AppSettings`
// properties (same keys/defaults/reset). Like the other feature pages it leads with its master
// enable toggle; every control persists live via `AppSettings`' `didSet`, so there is no Apply step.
//
// Sections, top to bottom: opt-in · Roots (the entry column) · Appearance · Behavior.

struct FilesPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    var body: some View {
        HubPage(HubDestination.files.title,
                subtitle: "A four-finger Files band — pilot your local folders, preview, and open by trackpad.") {
            HubSection(footnote: "Adds a local-only column navigator as a band in the four-finger launcher: drill into your folders horizontally, highlight vertically, lift to open (or add a finger for Open-With). Reads the local filesystem on demand — no new permission, no logout, nothing copied off this Mac. Off by default.") {
                ToggleRow(title: "Show a Files band in the launcher", isOn: $settings.filesBandEnabled)
            }

            rootsSection
            appearanceSection
            behaviorSection
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
            Text(settings.filesDefaultOpen == .openWith
                 ? "Lifting on a file opens the Open-With chooser. (Folders always open as a Finder window.)"
                 : "Lifting on a file opens it in its default app. Add a finger for the Open-With chooser. (Folders always open as a Finder window.)")
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
