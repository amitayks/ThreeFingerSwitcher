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
                ForEach(runningApps(), id: \.bundleID) { app in
                    Button(app.name) {
                        if !excluded.contains(app.bundleID) { excluded.append(app.bundleID) }
                    }
                }
            }
        }
    }

    private func displayName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    private func runningApps() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
