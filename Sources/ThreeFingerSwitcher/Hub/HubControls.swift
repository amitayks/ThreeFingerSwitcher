import SwiftUI
import AppKit

/// A toggle with an explanatory caption beneath it — the master/opt-in row used across feature pages.
struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: $isOn)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A settings row with the title + optional caption on the left and a right-aligned `.switch` toggle —
/// the "main toggle" look (matching the Overview `featureRow`'s switch) for immediate on/off preferences.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var caption: String? = nil

    init(_ title: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-body selectable card (title + optional caption). The whole card is the click target and a
/// selected card is highlighted (tinted fill + stroke) — used for the General page's Danger-zone
/// category selectors, where a multi-select reads better as deliberate tiles than as checkboxes.
struct ToggleCard: View {
    let title: String
    @Binding var isOn: Bool
    var caption: String? = nil

    init(_ title: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.caption = caption
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isOn ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Fade the fill / stroke colour / line-width in and out on selection rather than snapping.
            .animation(.easeInOut(duration: 0.18), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// A labeled `Double` slider with a monospaced value readout and help text — the tuning row used
/// across feature pages (ported from the former Settings window's `slider` helper).
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range)
            Text(help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A labeled integer slider (Double-backed) — ported from the former Settings window's `intSlider`.
struct LabeledIntSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value) },
                                  set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Manages the clipboard-history app-exclusion list — ported from the former Settings window. Shows
/// current entries with a remove control and an "Add app…" menu of running regular applications.
struct HubExcludedAppsEditor: View {
    @Binding var excluded: [String]

    var body: some View {
        DisclosureGroup("Excluded apps (\(excluded.count))") {
            if excluded.isEmpty {
                Text("Copies from apps you add here are never recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(excluded, id: \.self) { bundleID in
                HStack {
                    Text(displayName(bundleID)).font(.caption)
                    Spacer()
                    Button { excluded.removeAll { $0 == bundleID } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            Menu("Add app…") {
                ForEach(apps, id: \.bundleID) { app in
                    Button(app.name) {
                        if !excluded.contains(app.bundleID) { excluded.append(app.bundleID) }
                    }
                }
            }
        }
        // Enumerate once per appearance, not per render: this editor lives on a page with four
        // sliders bound to AppSettings, so `body` re-ran (and re-walked + ICU-sorted every running
        // app, plus a LaunchServices name lookup per excluded row) on every slider tick.
        .onAppear { refreshApps() }
    }

    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var names: [String: String] = [:]

    private func refreshApps() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        names = Dictionary(apps.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    private func displayName(_ bundleID: String) -> String {
        names[bundleID]
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
    }
}
