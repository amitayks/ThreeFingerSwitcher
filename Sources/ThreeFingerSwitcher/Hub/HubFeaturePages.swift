import SwiftUI

// Feature detail pages — the controls from the former Settings window, re-homed onto Hub pages and
// bound to the same `AppSettings` properties (same keys, defaults, and reset semantics). Each page
// leads with its master enable toggle; a disabled feature keeps its page with controls disabled.

// MARK: - Window Switcher

struct SwitcherPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HubPage(HubDestination.switcher.title,
                subtitle: "Switch windows with a three-finger horizontal swipe.") {
            HubSection {
                ToggleRow(title: "Enable the window switcher", isOn: $settings.enabled)
            }
            HubSection("Sensitivity") {
                LabeledSlider(title: "Activation threshold", value: $settings.activationThreshold,
                              range: 0.01...0.15, format: "%.3f",
                              help: "How far you must slide horizontally before the switcher appears.")
                LabeledSlider(title: "Step distance (one window per…)", value: $settings.stepDistance,
                              range: 0.02...0.20, format: "%.3f",
                              help: "Finger travel needed to move the highlight by one window.")
                LabeledSlider(title: "Axis-lock ratio", value: $settings.axisLockRatio,
                              range: 1.0...3.0, format: "%.2f",
                              help: "How strongly horizontal must dominate vertical to scrub instead of yielding to Mission Control.")
                LabeledSlider(title: "Velocity smoothing", value: $settings.velocitySmoothing,
                              range: 0.05...1.0, format: "%.2f",
                              help: "Higher is snappier, lower is smoother.")
            }
            HubSection("Behavior") {
                Toggle("Wrap around at the ends of the list", isOn: $settings.wrapAtEnds)
                Toggle("Reverse direction", isOn: $settings.reverseDirection)
                Toggle("Require exactly three fingers", isOn: $settings.requireExactlyThree)
            }
        }
    }
}

// MARK: - Spaces

struct SpacesPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HubPage(HubDestination.spaces.title,
                subtitle: "Move between Spaces while the switcher is open.") {
            HubSection("Space-row switching",
                       footnote: "Slide three fingers up/down while the switcher is open to move between Spaces. To free that gesture, this moves Mission Control / App Exposé to four-finger up/down (they keep working there). Changes a system setting that stays applied until you turn this off; a logout/restart is required for it to take effect.") {
                ToggleRow(title: "Switch Spaces by sliding up/down", isOn: $settings.manageVerticalGesture)
                LabeledSlider(title: "Row-step distance (one Space per…)", value: $settings.rowStepDistance,
                              range: 0.05...0.30, format: "%.3f",
                              help: "Vertical finger travel needed to switch to the next Space's row. Keep this larger than the step distance so horizontal scrubbing doesn't flip rows.")
                    .disabled(!settings.manageVerticalGesture)
                Toggle("Reverse vertical (Space-row) direction", isOn: $settings.reverseVerticalDirection)
                    .disabled(!settings.manageVerticalGesture)
            }
            HubSection("Fixed order",
                       footnote: "Turns off macOS “Automatically rearrange Spaces based on most recent use” so each Space keeps its position and the switcher's row order stays stable. Changes a system setting (Mission Control, everywhere) and briefly restarts the Dock; restored when you quit and reapplied on launch.") {
                Toggle("Keep Spaces in a fixed order", isOn: $settings.manageSpacesRearrange)
            }
        }
    }
}

// MARK: - Launcher

struct LauncherPage: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HubPage(HubDestination.launcher.title,
                subtitle: "A four-finger launcher of your apps, scripts, and commands.") {
            HubSection(footnote: "Slide four fingers horizontally to open a launcher of your favorite apps, scripts, and presets; dwell on an item and lift to fire it. Frees the native four-finger swipe gestures (Mission Control / App Exposé stay on three-finger up/down). Changes a system setting that needs a logout/restart to take effect and stays applied until you turn it off.") {
                ToggleRow(title: "Open a launcher with a four-finger swipe", isOn: $settings.enableLauncher)
            }
            HubSection("Tuning") {
                LabeledSlider(title: "Activation threshold", value: $settings.launcherActivationThreshold,
                              range: 0.01...0.15, format: "%.3f",
                              help: "How far you must slide horizontally before the launcher appears.")
                    .disabled(!settings.enableLauncher)
                LabeledSlider(title: "Item-step distance (one item per…)", value: $settings.launcherStepDistance,
                              range: 0.02...0.20, format: "%.3f",
                              help: "Finger travel to move the selection by one item — horizontally between items in a band, and vertically between grid rows and the band headers.")
                    .disabled(!settings.enableLauncher)
                LabeledSlider(title: "Band-switch distance (one band per…)", value: $settings.launcherContextStepDistance,
                              range: 0.05...0.30, format: "%.3f",
                              help: "Horizontal finger travel on the band-headers row needed to switch to the next band. Independent of the item step — raise it to make band switching more deliberate without slowing item movement.")
                    .disabled(!settings.enableLauncher)
                LabeledSlider(title: "Dwell-to-arm (seconds)", value: $settings.dwellToArmDuration,
                              range: 0.2...1.5, format: "%.2f",
                              help: "How long to rest on an item before it arms; then lift to fire. A quick scrub-and-lift never fires.")
                    .disabled(!settings.enableLauncher)
            }
        }
    }
}

// MARK: - Clipboard

struct ClipboardPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    private var maxBytesMB: Binding<Double> {
        Binding(get: { Double(settings.clipboardMaxBytes) / (1024 * 1024) },
                set: { settings.clipboardMaxBytes = Int($0 * 1024 * 1024) })
    }

    var body: some View {
        HubPage(HubDestination.clipboard.title,
                subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.") {
            HubSection(footnote: "Records what you copy — text, images, files, colors, links — into a Clipboard band shown as the last band in the four-finger launcher. Scrub to an entry and lift to paste it where you were. Stored only on this Mac; password-manager copies and excluded apps are never recorded. No new permission or logout needed. Off by default.") {
                ToggleRow(title: "Keep clipboard history", isOn: $settings.keepClipboardHistory)
            }
            HubSection("Recording") {
                Toggle("Pause recording", isOn: $settings.clipboardPaused)
                    .disabled(!settings.keepClipboardHistory)
                LabeledSlider(title: "Poll interval (seconds)", value: $settings.clipboardPollInterval,
                              range: 0.2...2.0, format: "%.2f",
                              help: "How often the clipboard is checked for new copies.")
                    .disabled(!settings.keepClipboardHistory)
                HubExcludedAppsEditor(excluded: $settings.clipboardExcludedApps)
                    .disabled(!settings.keepClipboardHistory)
            }
            HubSection("Retention") {
                LabeledIntSlider(title: "Entries shown in the band", value: $settings.clipboardRecentWindow,
                                 range: 5...100,
                                 help: "How many recent entries the Clipboard band shows. Pinned entries always float to the top.")
                    .disabled(!settings.keepClipboardHistory)
                LabeledIntSlider(title: "Maximum stored entries", value: $settings.clipboardMaxCount,
                                 range: 20...1000,
                                 help: "Oldest non-pinned entries are removed past this. Pinned entries are exempt.")
                    .disabled(!settings.keepClipboardHistory)
                LabeledSlider(title: "Maximum storage (MB)", value: maxBytesMB,
                              range: 16...2048, format: "%.0f",
                              help: "Total size of stored payloads (mostly images). Oldest non-pinned entries are removed past this.")
                    .disabled(!settings.keepClipboardHistory)
                LabeledSlider(title: "Maximum age (days, 0 = no limit)", value: $settings.clipboardMaxAgeDays,
                              range: 0...90, format: "%.0f",
                              help: "Non-pinned entries older than this are removed. 0 disables the age limit.")
                    .disabled(!settings.keepClipboardHistory)
            }
            HubSection("Navigation") {
                LabeledSlider(title: "Edge-scroll acceleration", value: $settings.clipboardEdgeAcceleration,
                              range: 0.5...3.0, format: "%.2f",
                              help: "How quickly the list speeds up when you hold a finger at the trackpad edge to scroll a long history.")
                    .disabled(!settings.keepClipboardHistory)
                LabeledSlider(title: "Pin flick distance", value: $settings.clipboardPinDistance,
                              range: 0.10...0.45, format: "%.3f",
                              help: "How far you swipe sideways on an entry to pin it (right) or jump to the previous band (left). Larger = more deliberate; one flick pins once.")
                    .disabled(!settings.keepClipboardHistory)
            }
            HubSection("History") {
                HStack {
                    Button("Clear history") { context.onClearClipboard(false) }
                    Button("Clear history (incl. pinned)") { context.onClearClipboard(true) }
                }
                .disabled(!settings.keepClipboardHistory)
            }
        }
    }
}

// MARK: - AI

struct AIPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var models: ModelManager

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _models = ObservedObject(wrappedValue: context.models)
    }

    /// Picker binding: maps `aiSelectedModelID` (nil = registry default) to the picker's optional-string.
    private var modelSelection: Binding<String?> {
        Binding(get: { settings.aiSelectedModelID },
                set: { settings.aiSelectedModelID = $0 })
    }

    /// The model the management surface shows: the user's pinned selection if it resolves, else default.
    private var selectedModelDescriptor: ModelDescriptor {
        let registry = ModelRegistry.standard
        if let id = settings.aiSelectedModelID, let d = registry.descriptor(id: id) { return d }
        return registry.defaultDescriptor ?? registry.models[0]
    }

    var body: some View {
        HubPage(HubDestination.ai.title,
                subtitle: "Run on-device AI commands. Author the commands themselves on the Bands page.") {
            HubSection(footnote: "Runs an on-device Gemma 4 model — turning this on starts a one-time multi-gigabyte download. No new permission or logout needed (a calendar task asks for Calendar access the first time it runs). Add AI commands to any band on the Bands page. Off by default.") {
                ToggleRow(title: "Enable AI commands", isOn: $settings.aiCommandsEnabled)
            }
            HubSection("Model") {
                let registry = ModelRegistry.standard
                Picker("Model", selection: modelSelection) {
                    Text("Default (\(registry.defaultDescriptor?.displayName ?? "registry"))").tag(String?.none)
                    ForEach(registry.models, id: \.id) { model in
                        Text(model.displayName).tag(String?.some(model.id))
                    }
                }
                .disabled(!settings.aiCommandsEnabled)

                ModelManagementView(manager: models,
                                    descriptor: selectedModelDescriptor,
                                    onDownload: context.onDownloadModel)
                    .disabled(!settings.aiCommandsEnabled)
            }
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings
    @State private var refresh = false

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    var body: some View {
        HubPage(HubDestination.general.title) {
            HubSection("Reliability",
                       footnote: "Verifies the switched-to window actually receives focus and recovers automatically, so you never need Mission Control to escape a stuck state.") {
                Toggle("Self-heal focus after switching", isOn: $settings.focusWatchdogEnabled)
            }
            HubSection("Startup") {
                Toggle("Open at Login", isOn: Binding(
                    get: { _ = refresh; return context.isOpenAtLogin() },
                    set: { _ in context.onToggleOpenAtLogin(); refresh.toggle() }
                ))
            }
            HubSection("Diagnostics",
                       footnote: "Adds “Write Diagnostics” and “Copy Focus Log” here — handy when reporting a bug. Off by default.") {
                Toggle("Show diagnostic tools", isOn: $settings.showDiagnostics)
                if settings.showDiagnostics {
                    HStack {
                        Button("Write Diagnostics → /tmp") { context.onWriteDiagnostics() }
                        Button("Copy Focus Log") { context.onCopyFocusLog() }
                    }
                }
            }
            HubSection {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.resetToDefaults() }
                }
            }
        }
    }
}
