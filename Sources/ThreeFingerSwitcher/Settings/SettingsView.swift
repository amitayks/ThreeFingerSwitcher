import SwiftUI
import AppKit

/// Settings window for the gesture tunables.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    /// Opens the Setup & Permissions (onboarding) window. Wired by the coordinator.
    var onOpenSetup: () -> Void = {}
    /// Restores the native three-finger up/down (Mission Control) gesture. Wired by the coordinator.
    var onRestoreMissionControl: () -> Void = {}
    /// Whether a Mission-Control backup exists to restore (drives the restore button's visibility).
    var showRestoreMissionControl: Bool = false
    /// Clears the stored clipboard history. Wired by the coordinator to `ClipboardStore`.
    var onClearClipboard: (_ includingPinned: Bool) -> Void = { _ in }

    var body: some View {
        Form {
            Section("Sensitivity") {
                slider("Activation threshold", value: $settings.activationThreshold,
                       range: 0.01...0.15, format: "%.3f",
                       help: "How far you must slide horizontally before the switcher appears.")
                slider("Step distance (one window per…)", value: $settings.stepDistance,
                       range: 0.02...0.20, format: "%.3f",
                       help: "Finger travel needed to move the highlight by one window.")
                slider("Axis-lock ratio", value: $settings.axisLockRatio,
                       range: 1.0...3.0, format: "%.2f",
                       help: "How strongly horizontal must dominate vertical to scrub instead of yielding to Mission Control.")
                slider("Velocity smoothing", value: $settings.velocitySmoothing,
                       range: 0.05...1.0, format: "%.2f",
                       help: "Higher is snappier, lower is smoother.")
            }

            Section("Behavior") {
                Toggle("Wrap around at the ends of the list", isOn: $settings.wrapAtEnds)
                Toggle("Reverse direction", isOn: $settings.reverseDirection)
                Toggle("Require exactly three fingers", isOn: $settings.requireExactlyThree)
            }

            Section("Spaces") {
                Toggle("Switch Spaces by sliding up/down", isOn: $settings.manageVerticalGesture)
                Text("Slide three fingers up/down while the switcher is open to move between Spaces. To free that gesture, this moves Mission Control / App Exposé to four-finger up/down (they keep working there). Changes a system setting that stays applied until you turn this off; a logout/restart is required for it to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                slider("Row-step distance (one Space per…)", value: $settings.rowStepDistance,
                       range: 0.05...0.30, format: "%.3f",
                       help: "Vertical finger travel needed to switch to the next Space's row. Keep this larger than the step distance so horizontal scrubbing doesn't flip rows.")
                    .disabled(!settings.manageVerticalGesture)
                Toggle("Reverse vertical (Space-row) direction", isOn: $settings.reverseVerticalDirection)
                    .disabled(!settings.manageVerticalGesture)

                Toggle("Keep Spaces in a fixed order", isOn: $settings.manageSpacesRearrange)
                Text("Turns off macOS “Automatically rearrange Spaces based on most recent use” so each Space keeps its position and the switcher's row order stays stable. Changes a system setting (Mission Control, everywhere) and briefly restarts the Dock; restored when you quit and reapplied on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Four-finger launcher") {
                Toggle("Open a launcher with a four-finger swipe", isOn: $settings.enableLauncher)
                Text("Slide four fingers horizontally to open a launcher of your favorite apps, scripts, and presets; dwell on an item and lift to fire it. Frees the native four-finger swipe gestures (Mission Control / App Exposé stay on three-finger up/down). Changes a system setting that needs a logout/restart to take effect and stays applied until you turn it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                slider("Activation threshold", value: $settings.launcherActivationThreshold,
                       range: 0.01...0.15, format: "%.3f",
                       help: "How far you must slide horizontally before the launcher appears.")
                    .disabled(!settings.enableLauncher)
                slider("Item-step distance (one item per…)", value: $settings.launcherStepDistance,
                       range: 0.02...0.20, format: "%.3f",
                       help: "Finger travel to move the selection by one item — horizontally between items in a band, and vertically between grid rows and the band headers.")
                    .disabled(!settings.enableLauncher)
                slider("Band-switch distance (one band per…)", value: $settings.launcherContextStepDistance,
                       range: 0.05...0.30, format: "%.3f",
                       help: "Horizontal finger travel on the band-headers row needed to switch to the next band. Independent of the item step — raise it to make band switching more deliberate without slowing item movement.")
                    .disabled(!settings.enableLauncher)
                slider("Dwell-to-arm (seconds)", value: $settings.dwellToArmDuration,
                       range: 0.2...1.5, format: "%.2f",
                       help: "How long to rest on an item before it arms; then lift to fire. A quick scrub-and-lift never fires.")
                    .disabled(!settings.enableLauncher)
            }

            Section("Clipboard history") {
                Toggle("Keep clipboard history", isOn: $settings.keepClipboardHistory)
                Text("Records what you copy — text, images, files, colors, links — into a Clipboard band shown as the last band in the four-finger launcher. Scrub to an entry and lift to paste it where you were. Stored only on this Mac; password-manager copies and excluded apps are never recorded. No new permission or logout needed. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Pause recording", isOn: $settings.clipboardPaused)
                    .disabled(!settings.keepClipboardHistory)
                intSlider("Entries shown in the band", value: $settings.clipboardRecentWindow,
                          range: 5...100,
                          help: "How many recent entries the Clipboard band shows. Pinned entries always float to the top.")
                    .disabled(!settings.keepClipboardHistory)
                intSlider("Maximum stored entries", value: $settings.clipboardMaxCount,
                          range: 20...1000,
                          help: "Oldest non-pinned entries are removed past this. Pinned entries are exempt.")
                    .disabled(!settings.keepClipboardHistory)
                slider("Maximum storage (MB)", value: maxBytesMB,
                       range: 16...2048, format: "%.0f",
                       help: "Total size of stored payloads (mostly images). Oldest non-pinned entries are removed past this.")
                    .disabled(!settings.keepClipboardHistory)
                slider("Maximum age (days, 0 = no limit)", value: $settings.clipboardMaxAgeDays,
                       range: 0...90, format: "%.0f",
                       help: "Non-pinned entries older than this are removed. 0 disables the age limit.")
                    .disabled(!settings.keepClipboardHistory)
                slider("Poll interval (seconds)", value: $settings.clipboardPollInterval,
                       range: 0.2...2.0, format: "%.2f",
                       help: "How often the clipboard is checked for new copies.")
                    .disabled(!settings.keepClipboardHistory)
                slider("Edge-scroll acceleration", value: $settings.clipboardEdgeAcceleration,
                       range: 0.5...3.0, format: "%.2f",
                       help: "How quickly the list speeds up when you hold a finger at the trackpad edge to scroll a long history.")
                    .disabled(!settings.keepClipboardHistory)
                slider("Pin flick distance", value: $settings.clipboardPinDistance,
                       range: 0.10...0.45, format: "%.3f",
                       help: "How far you swipe sideways on an entry to pin it (right) or jump to the previous band (left). Larger = more deliberate; one flick pins once.")
                    .disabled(!settings.keepClipboardHistory)
                ExcludedAppsEditor(excluded: $settings.clipboardExcludedApps)
                    .disabled(!settings.keepClipboardHistory)
                HStack {
                    Button("Clear history") { onClearClipboard(false) }
                    Button("Clear history (incl. pinned)") { onClearClipboard(true) }
                }
                .disabled(!settings.keepClipboardHistory)
            }

            Section("Reliability") {
                Toggle("Self-heal focus after switching", isOn: $settings.focusWatchdogEnabled)
                Text("Verifies the switched-to window actually receives focus and recovers automatically, so you never need Mission Control to escape a stuck state.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Setup & diagnostics") {
                Button("Setup & Permissions…") { onOpenSetup() }
                if showRestoreMissionControl {
                    Button("Restore Mission Control (three-finger up/down)…") { onRestoreMissionControl() }
                }
                Toggle("Show diagnostic tools in the menu", isOn: $settings.showDiagnostics)
                Text("Adds “Write Diagnostics” and “Copy Focus Log” to the menu bar — handy when reporting a bug. Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
    }

    /// The byte cap surfaced as megabytes for the slider.
    private var maxBytesMB: Binding<Double> {
        Binding(get: { Double(settings.clipboardMaxBytes) / (1024 * 1024) },
                set: { settings.clipboardMaxBytes = Int($0 * 1024 * 1024) })
    }

    @ViewBuilder
    private func intSlider(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)").foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Manages the clipboard-history app-exclusion list: shows current entries with a remove control and
/// an "Add app…" menu of currently-running regular applications.
private struct ExcludedAppsEditor: View {
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
