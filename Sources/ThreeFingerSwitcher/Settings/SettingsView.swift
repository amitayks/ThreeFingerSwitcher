import SwiftUI

/// Settings window for the gesture tunables.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Sensitivity") {
                slider("Activation threshold", value: $settings.activationThreshold,
                       range: 0.01...0.15, format: "%.3f",
                       help: "How far you must slide horizontally before the switcher appears.")
                slider("Step distance (one window per…)", value: $settings.stepDistance,
                       range: 0.02...0.20, format: "%.3f",
                       help: "Finger travel needed to move the highlight by one window.")
                slider("Row-step distance (one Space per…)", value: $settings.rowStepDistance,
                       range: 0.05...0.30, format: "%.3f",
                       help: "Vertical finger travel needed to switch to the next Space's row. Keep this larger than the step distance so horizontal scrubbing doesn't flip rows.")
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
                Toggle("Reverse vertical (Space-row) direction", isOn: $settings.reverseVerticalDirection)
                Toggle("Require exactly three fingers", isOn: $settings.requireExactlyThree)
            }

            Section("Spaces") {
                Toggle("Keep Spaces in a fixed order", isOn: $settings.manageSpacesRearrange)
                Text("Turns off macOS “Automatically rearrange Spaces based on most recent use” so each Space keeps its position and the switcher's row order stays stable. Changes a system setting (Mission Control, everywhere) and briefly restarts the Dock; restored when you quit and reapplied on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reliability") {
                Toggle("Self-heal focus after switching", isOn: $settings.focusWatchdogEnabled)
                Text("Verifies the switched-to window actually receives focus and recovers automatically, so you never need Mission Control to escape a stuck state.")
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
        .frame(width: 460, height: 420)
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
