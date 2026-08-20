import SwiftUI

/// The Window Inspector (refine-window-filtering, design D5): an on-demand snapshot of every regular
/// app's current-Space window candidates with the verdict the switcher's own filter produced —
/// Listed, a typed drop reason, or Duplicate — grouped by app, with an inline per-app rule picker
/// writing `AppSettings.windowAppRules`. Pull-only: one load on first appearance, the Refresh
/// button, and a re-read after a rule edit (all explicit actions) — NEVER a timer (the hidden-window
/// idle-CPU landmine: the Hub window outlives its visibility).
struct HubWindowInspector: View {
    @ObservedObject var settings: AppSettings
    let inspect: () -> [WindowInspectorEntry]

    @State private var entries: [WindowInspectorEntry] = []
    @State private var loaded = false
    /// Grouped + sorted ONCE per snapshot. This view observes `AppSettings` and shares a page with
    /// five sliders, so it re-renders on every slider tick — re-grouping and ICU-sorting every
    /// window (twice: body + summary) per tick was pure waste.
    @State private var groups: [(key: String, name: String, icon: NSImage?, rows: [WindowInspectorEntry])] = []

    private func setEntries(_ new: [WindowInspectorEntry]) {
        entries = new
        groups = Dictionary(grouping: new, by: \.appKey)
            .map { (key: $0.key, name: $0.value.first?.appName ?? $0.key,
                    icon: $0.value.first?.appIcon, rows: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { setEntries(inspect()) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            ForEach(groups, id: \.key) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.rows) { row(for: $0) }
                        rulePicker(for: group.key)
                            .padding(.top, 4)
                    }
                    .padding(.leading, 2)
                } label: {
                    HStack(spacing: 6) {
                        if let icon = group.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(group.name).font(.callout)
                        if let rule = settings.windowAppRules[group.key] {
                            Text(Self.ruleLabel(rule))
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                        Spacer()
                        Text(groupSummary(group.rows)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            setEntries(inspect())
        }
    }

    private var summary: String {
        guard !entries.isEmpty else { return "No windows enumerated yet." }
        let shown = entries.filter { $0.verdict == .listed && !$0.dedupedOut }.count
        return "\(shown) of \(entries.count) windows listed, across \(groups.count) apps"
    }

    private func groupSummary(_ rows: [WindowInspectorEntry]) -> String {
        let shown = rows.filter { $0.verdict == .listed && !$0.dedupedOut }.count
        return "\(shown)/\(rows.count) listed"
    }

    private func row(for entry: WindowInspectorEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.title.isEmpty ? "Untitled" : entry.title)
                .font(.caption)
                .foregroundStyle(entry.title.isEmpty ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Text("\(Int(entry.size.width))×\(Int(entry.size.height)) · \(Self.subroleLabel(entry.subrole))\(entry.isMinimized ? " · minimized" : "")")
                .font(.caption2).foregroundStyle(.tertiary)
                .layoutPriority(1)
            Spacer(minLength: 8)
            verdictBadge(for: entry).layoutPriority(1)
        }
    }

    private func verdictBadge(for entry: WindowInspectorEntry) -> some View {
        let (text, color) = Self.verdictLabel(entry)
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    /// The verdict vocabulary, one human string per `WindowDropReason` — bounded, never raw AX text.
    static func verdictLabel(_ entry: WindowInspectorEntry) -> (String, Color) {
        if entry.dedupedOut { return ("Duplicate", .orange) }
        switch entry.verdict {
        case .listed: return ("Listed", .green)
        case .dropped(.appExcluded): return ("Excluded app", .secondary)
        case .dropped(.minimized): return ("Minimized (opt-in off)", .secondary)
        case .dropped(.notAWindow): return ("Not a window", .secondary)
        case .dropped(.degenerateSize): return ("Sliver frame", .secondary)
        case .dropped(.junkSubrole): return ("Floating palette", .secondary)
        case .dropped(.phantom): return ("Phantom frame", .secondary)
        case .dropped(.nonStandardSubrole): return ("Non-standard window", .secondary)
        }
    }

    /// Compact subrole readout ("AXStandardWindow" → "standard") — the debugging signal that tells
    /// which filter tier judged the window, without raw AX constants in the UI.
    static func subroleLabel(_ subrole: String?) -> String {
        guard let subrole else { return "no subrole" }
        return subrole.hasPrefix("AX") ? String(subrole.dropFirst(2)).lowercased() : subrole
    }

    static func ruleLabel(_ rule: WindowAppRule) -> String {
        switch rule {
        case .include: return "Include all"
        case .strict: return "Standard only"
        case .exclude: return "Excluded"
        }
    }

    /// Absent key ⇒ the sentinel "global" tag; writing `global` removes the entry. A rule edit
    /// re-reads the snapshot immediately (an explicit action) so the verdicts shown match the rule.
    private func rulePicker(for key: String) -> some View {
        Picker("Rule for this app", selection: Binding(
            get: { settings.windowAppRules[key]?.rawValue ?? "global" },
            set: { raw in
                if let rule = WindowAppRule(rawValue: raw) {
                    settings.windowAppRules[key] = rule
                } else {
                    settings.windowAppRules.removeValue(forKey: key)
                }
                setEntries(inspect())
            })) {
            Text("Follow global setting").tag("global")
            Text("Include all windows").tag(WindowAppRule.include.rawValue)
            Text("Standard windows only").tag(WindowAppRule.strict.rawValue)
            Text("Exclude this app").tag(WindowAppRule.exclude.rawValue)
        }
        .pickerStyle(.menu)
        .font(.caption)
    }
}
