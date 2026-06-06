import SwiftUI

/// Settings window for the gesture tunables.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    /// Opens the Setup & Permissions (onboarding) window. Wired by the coordinator.
    var onOpenSetup: () -> Void = {}
    /// Restores the native three-finger up/down (Mission Control) gesture. Wired by the coordinator.
    var onRestoreMissionControl: () -> Void = {}
    /// Whether a Mission-Control backup exists to restore (drives the restore button's visibility).
    var showRestoreMissionControl: Bool = false

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
                       help: "Finger travel needed to move the selection by one item.")
                    .disabled(!settings.enableLauncher)
                slider("Context-step distance (one band per…)", value: $settings.launcherContextStepDistance,
                       range: 0.05...0.30, format: "%.3f",
                       help: "Vertical finger travel needed to switch context bands. Keep larger than the item step so horizontal scrubbing doesn't flip bands.")
                    .disabled(!settings.enableLauncher)
                slider("Dwell-to-arm (seconds)", value: $settings.dwellToArmDuration,
                       range: 0.2...1.5, format: "%.2f",
                       help: "How long to rest on an item before it arms; then lift to fire. A quick scrub-and-lift never fires.")
                    .disabled(!settings.enableLauncher)
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
