import SwiftUI

// Feature detail pages — the controls from the former Settings window, re-homed onto Hub pages and
// bound to the same `AppSettings` properties (same keys, defaults, and reset semantics). Each page
// leads with its master enable toggle; a disabled feature keeps its page with controls disabled.

// MARK: - Window Switcher

struct SwitcherPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §12 — the REAL mini switcher: a `SwitcherView` over the user's open windows grouped into Space-rows
    /// (true proportions + live thumbnails; icon-only fallbacks), owned by a `HubSwitcherDemo` holder and
    /// seeded once. The ghost-hand autoplay plays the teaching story (three-finger open → lift one → up/down
    /// Spaces → sideways windows) and the preview's `sync` seam steps the model to match — clockless in the
    /// holder, driven only by the visibility-gated preview clock, so a hidden Hub stays inert (the guardrail
    /// from `docs/postmortem-idle-cpu-spin.md`; the old free-running driver stays deleted).
    @StateObject private var demo = HubSwitcherDemo()
    @State private var seeded = false
    /// The base autoplay gesture — the teaching story, its open swipe scaled to the activation threshold.
    @State private var gesture: GesturePose.DemoGesture
    /// The hover-demo override pushed into the preview by the direction pickers: hovering the windows-axis
    /// control demos a sideways window scrub, the Spaces-axis control an up/down Space move. `nil` ⇒ base.
    @State private var hoverGesture: GesturePose.DemoGesture?
    /// The sync script matching `hoverGesture` (the stroke-index mapping the drive uses); `nil` ⇒ teaching.
    @State private var hoverScript: HubSwitcherDemo.SyncScript?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _gesture = State(initialValue: HubSwitcherDemo.teachingGesture(
            openLength: HubSwitcherDemo.openLength(forActivation: context.settings.activationThreshold)))
    }

    /// Two-way bindings onto the switcher axis directions — the single source of truth (the former
    /// `reverseDirection` / `reverseVerticalDirection` booleans are a view onto these).
    private var windowsAxis: Binding<GestureBindings.AxisDirection> {
        Binding(get: { settings.gestureBindings.switcher.windowsAxis },
                set: { settings.gestureBindings.switcher.windowsAxis = $0 })
    }
    private var spacesAxis: Binding<GestureBindings.AxisDirection> {
        Binding(get: { settings.gestureBindings.switcher.spacesAxis },
                set: { settings.gestureBindings.switcher.spacesAxis = $0 })
    }

    /// Seed the mini switcher once with the user's real windows grouped into Space-rows (true proportions +
    /// live thumbnails, with the single-window / fabricated-second-Space fallbacks from `HubPreviewModels`),
    /// sized to a wide-but-short mini canvas at the user's window-scale. Thumbnails are seeded against the
    /// RENDERED model so the post-reveal live-capture retries land HERE.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let canvas = CGSize(width: 820, height: 150)
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        let maxScale = SwitcherLayout.kMax * CGFloat(settings.switcherWindowScale)
        let seededModel = models.makeSwitcherModel(canvas: canvas, maxScale: maxScale)
        demo.seed(from: seededModel, canvas: canvas, maxScale: maxScale)
        // Live-capture the REAL windows into the rendered model (icon-only mocks have no captures).
        context.seedThumbnails(demo.model)
    }

    var body: some View {
        HubPage(HubDestination.switcher.title,
                subtitle: "Switch windows with a three-finger horizontal swipe — and Spaces by sliding up/down.") {
            HubSection {
                HubFeatureHeader(
                    preview: HubGesturePreview(
                        gesture: gesture,
                        hoverGesture: hoverGesture,
                        // The sync seam: the mini switcher follows the ghost hand (pop in on the open beat,
                        // Space slides on up/down, highlight steps on the scrub, pop out on the commit lift).
                        sync: { pose in
                            demo.drive(pose, script: pose.hovering ? (hoverScript ?? .teaching) : .teaching)
                        }
                    ) {
                        SwitcherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.switcher.systemImage,
                    title: HubDestination.switcher.title,
                    subtitle: "Switch windows with three fingers; switch Spaces by sliding up/down.",
                    isOn: $settings.enabled
                )
                .onAppear { seedIfNeeded() }
                // Live window-size: dragging "Window size" grows/shrinks the preview cards in real time.
                .onChange(of: settings.switcherWindowScale) { _, scale in
                    demo.setMaxScale(SwitcherLayout.kMax * CGFloat(scale))
                }
                // The demo's opening swipe tracks the real activation distance as you tune it.
                .onChange(of: settings.activationThreshold) { _, threshold in
                    gesture = HubSwitcherDemo.teachingGesture(
                        openLength: HubSwitcherDemo.openLength(forActivation: threshold))
                }
                // Drive this same window switcher from ⌘-Tab (instead of the native app switcher). Sits
                // right under the master enable and needs it on (⌘-Tab reuses the switcher's engine).
                SwitchRow("Use ⌘-Tab for the window switcher", isOn: $settings.commandTabSwitcher,
                          caption: "Replaces the macOS ⌘-Tab app switcher: hold ⌘, Tab steps forward across Spaces, ⇧Tab back, release ⌘ to switch, Esc cancels. No new permission or logout — turn off to restore the native ⌘-Tab.")
                    .disabled(!settings.enabled)
            }
            HubSection("How the gesture works") {
                SwitcherActionMap()
            }
            HubSection("Appearance") {
                LabeledSlider(title: "Window size", value: $settings.switcherWindowScale,
                              range: 0.5...2.0, format: "%.2f×",
                              help: "Relative size of the window previews in the switcher grid. Larger renders bigger cards; smaller packs more in. Windows keep their true relative proportions.")
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
                // Windows scrub direction — the single source of truth (folds the former "Reverse
                // direction" boolean). Hover demos the horizontal scrub in the preview.
                Picker("Windows scrub direction", selection: windowsAxis) {
                    ForEach(GestureBindings.AxisDirection.allCases) { direction in
                        Text(HubBindingLabels.axisDirection(direction)).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .onHover { inside in
                    hoverGesture = inside ? HubSwitcherDemo.windowsHoverGesture() : nil
                    hoverScript = inside ? .windowsHover : nil
                }
                Toggle("Require exactly three fingers", isOn: $settings.requireExactlyThree)
                ToggleRow(title: "Include non-standard windows",
                          isOn: $settings.includeNonStandardWindows,
                          caption: "Also switch to windows that don't report as standard document windows — like the Android emulator, simulators and tools from other UI toolkits, setup/welcome screens (e.g. Xcode's start window), and dialogs such as copy-progress windows. Phantom frames and floating palettes are still filtered out; check the Window inspector below to see each decision and override it per app.")
                ToggleRow(title: "Include minimized windows",
                          isOn: $settings.includeMinimizedWindows,
                          caption: "Show minimized windows in the switcher and ⌘-Tab, badged as “Minimized.” Selecting one restores it to where it was. Locked on while “Minimize all windows on three-finger down” (below) is enabled, so those windows are never stranded.")
                    .disabled(settings.swipeDownMinimizesAll)
            }
            HubSection("Window inspector",
                       footnote: "Every window on the current Space and what the switcher decided about it — including duplicates it collapsed. If the filter gets an app wrong, set a per-app rule here.") {
                HubWindowInspector(settings: settings, inspect: context.inspectWindows)
            }
            // Space-row switching — a sub-feature of the switcher: slide up/down while it is open to move
            // between Spaces. Re-homed here from the former standalone Spaces page.
            HubSection("Space-row switching",
                       footnote: "Slide three fingers up/down while the switcher is open to move between Spaces. To free that gesture, this moves Mission Control / App Exposé to four-finger up/down (they keep working there). Changes a system setting that stays applied until you turn this off; a logout/restart is required for it to take effect.") {
                ToggleRow(title: "Switch Spaces by sliding up/down", isOn: $settings.manageVerticalGesture)
                LabeledSlider(title: "Row-step distance (one Space per…)", value: $settings.rowStepDistance,
                              range: 0.05...0.30, format: "%.3f",
                              help: "Vertical finger travel needed to switch to the next Space's row. Keep this larger than the step distance so horizontal scrubbing doesn't flip rows.")
                    .disabled(!settings.manageVerticalGesture)
                // Spaces (Space-row) scrub direction — single source of truth (folds the former "Reverse
                // vertical direction" boolean). Hover demos the vertical scrub in the preview.
                Picker("Spaces scrub direction", selection: spacesAxis) {
                    ForEach(GestureBindings.AxisDirection.allCases) { direction in
                        Text(HubBindingLabels.axisDirection(direction)).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .onHover { inside in
                    hoverGesture = inside ? HubSwitcherDemo.spacesHoverGesture() : nil
                    hoverScript = inside ? .spacesHover : nil
                }
                .disabled(!settings.manageVerticalGesture)
                // The three-finger-DOWN action. Only reachable once the vertical gesture is ours (the same
                // opt-in above), so it's gated on `manageVerticalGesture`. Enabling it also flips on
                // "Include minimized windows" (model-level coupling) so a cleared desktop is recoverable.
                ToggleRow(title: "Minimize all windows on three-finger down",
                          isOn: $settings.swipeDownMinimizesAll,
                          caption: "Swipe DOWN with three fingers to minimize every window on the current Space and reveal the desktop (like Windows Win+D), instead of App Exposé. Also turns on “Include minimized windows” so you can bring them back from the switcher.")
                    .disabled(!settings.manageVerticalGesture)
            }
            HubSection("Fixed order",
                       footnote: "Turns off macOS “Automatically rearrange Spaces based on most recent use” so each Space keeps its position and the switcher's row order stays stable. Changes a system setting (Mission Control, everywhere) and briefly restarts the Dock; restored when you quit and reapplied on launch.") {
                Toggle("Keep Spaces in a fixed order", isOn: $settings.manageSpacesRearrange)
            }
            // The switcher "from another angle": hover the Dock with the mouse instead of swiping the
            // trackpad. Reuses the same window enumeration + live capture + raise, triggered by Dock hover.
            HubSection("Dock window previews",
                       footnote: "Hover an app's Dock icon to fan out its windows on the current Space (including minimized). Hover a thumbnail to peek its live content — the real window isn't disturbed — and click to bring it forward. Reuses the permissions you've already granted: no new permission, no logout. Off by default.") {
                ToggleRow(title: "Show window previews when hovering the Dock", isOn: $settings.showDockPreviews)
            }
            HubSection("Window groups",
                       footnote: "Drag a window until it snaps against another window's edge to link them: the switcher shows the pair snapped together (each window still highlighted on its own), and selecting one brings the whole group forward with the selected window focused. Drag a window away to unlink it; closing, minimizing, or moving it to another Space unlinks it too. No new permission, no logout. Off by default.") {
                ToggleRow(title: "Group windows snapped together by their edges", isOn: $settings.enableWindowGroups)
            }
        }
    }
}

// MARK: - Launcher

struct LauncherPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §13 — the user's REAL launcher, seeded once into a `HubLauncherDemo` holder. The ghost-hand autoplay
    /// plays the deterministic teaching story (4-finger open → lift two → one band down → across the items)
    /// and the preview's `sync` seam steps the model to match — clockless in the holder, driven only by the
    /// visibility-gated preview clock, so a hidden Hub stays inert (the guardrail from
    /// `docs/postmortem-idle-cpu-spin.md`; the launcher still never grows). The open swipe length tracks the
    /// activation threshold.
    @StateObject private var demo = HubLauncherDemo()
    @State private var seeded = false
    /// The autoplay teaching gesture; its open swipe scales with the activation threshold.
    @State private var gesture: GesturePose.DemoGesture

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _gesture = State(initialValue: HubLauncherDemo.teachingGesture(
            openLength: HubLauncherDemo.openLength(forActivation: context.settings.launcherActivationThreshold)))
    }

    /// Seed the launcher once with the user's real bands (favorites only — clipboard/AI off here). Lands on
    /// the band list at the home band, exactly as the real launcher.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: false, aiOn: false, dwell: settings.dwellToArmDuration))
    }

    var body: some View {
        HubPage(HubDestination.launcher.title,
                subtitle: "A four-finger launcher of your apps, scripts, and commands.") {
            HubSection(footnote: "Slide four fingers horizontally to open a launcher of your favorite apps, scripts, and presets; dwell on an item and lift to fire it. Frees the native four-finger swipe gestures (Mission Control / App Exposé stay on three-finger up/down). Changes a system setting that needs a logout/restart to take effect and stays applied until you turn it off.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(
                        gesture: gesture,
                        // The sync seam: the mini launcher follows the ghost hand (pop in on the open
                        // beat, band step, item scrub + arm, pop out on the closing lift).
                        sync: { demo.drive($0, script: .teaching) }
                    ) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.launcher.systemImage,
                    title: HubDestination.launcher.title,
                    subtitle: "Open a launcher of apps, scripts, and commands with four fingers.",
                    isOn: $settings.enableLauncher
                )
                .onAppear { seedIfNeeded() }
                // The opening swipe tracks the real activation distance as you tune it.
                .onChange(of: settings.launcherActivationThreshold) { _, t in
                    gesture = HubLauncherDemo.teachingGesture(openLength: HubLauncherDemo.openLength(forActivation: t))
                }
            }
            HubSection("How the gesture works") {
                LauncherActionMap()
            }
            HubSection("Tuning") {
                LabeledSlider(title: "Activation threshold", value: $settings.launcherActivationThreshold,
                              range: 0.01...0.15, format: "%.3f",
                              help: "How far you must slide horizontally before the launcher appears.")
                    .disabled(!settings.enableLauncher)
                LabeledSlider(title: "Item-step distance (one item per…)", value: $settings.launcherStepDistance,
                              range: 0.02...0.20, format: "%.3f",
                              help: "Finger travel to move the selection by one item — horizontally between items in a band, and vertically between grid rows. Also drives the in-launcher Finder's depth/highlight stepping.")
                    .disabled(!settings.enableLauncher)
                LabeledSlider(title: "Band-switch distance (one band per…)", value: $settings.launcherContextStepDistance,
                              range: 0.05...0.30, format: "%.3f",
                              help: "Vertical finger travel on the band list needed to switch to the next band. Independent of the item step — raise it to make band switching more deliberate without slowing item movement.")
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

    /// §13 — the REAL launcher showing its CLIPBOARD band: a `LauncherView` seeded once with the clipboard
    /// band on (it is the last band) and landed on it (the resting frame shows the band). The ghost-hand
    /// autoplay plays the full path — 4-finger open → 2-finger traverse down the band list → lift — and the
    /// preview's `sync` seam replays it on the model (pop in, band walk to the Clipboard band, pop out);
    /// clockless, visibility-gated, never grows (see `docs/postmortem-idle-cpu-spin.md`).
    @StateObject private var demo = HubLauncherDemo()
    @State private var seeded = false
    /// The autoplay band-journey gesture; its open swipe scales with the activation threshold.
    @State private var gesture: GesturePose.DemoGesture

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _gesture = State(initialValue: HubLauncherDemo.bandJourneyGesture(
            openLength: HubLauncherDemo.openLength(forActivation: context.settings.launcherActivationThreshold)))
    }

    private var maxBytesMB: Binding<Double> {
        Binding(get: { Double(settings.clipboardMaxBytes) / (1024 * 1024) },
                set: { settings.clipboardMaxBytes = Int($0 * 1024 * 1024) })
    }

    /// Seed once with the clipboard band on, landing the static preview on the last (Clipboard) band.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: true, aiOn: false, dwell: settings.dwellToArmDuration),
                  landOnLastBand: true)
    }

    var body: some View {
        HubPage(HubDestination.clipboard.title,
                subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.") {
            HubSection(footnote: "Records what you copy — text, images, files, colors, links — into a Clipboard band shown as the last band in the four-finger launcher. Scrub to an entry and lift to paste it where you were. Stored only on this Mac; password-manager copies and excluded apps are never recorded. No new permission or logout needed. Off by default.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(
                        gesture: gesture,
                        // The sync seam: the miniature replays the journey — pop in on the open beat,
                        // traverse the band list to the Clipboard band, pop out on the lift.
                        sync: { demo.drive($0, script: .bandJourney) }
                    ) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.clipboard.systemImage,
                    title: HubDestination.clipboard.title,
                    subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.",
                    isOn: $settings.keepClipboardHistory
                )
                .onAppear { seedIfNeeded() }
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
                              range: 0.06...0.45, format: "%.3f",
                              help: "How far you swipe right on an entry to pin it. Larger = more deliberate; one flick pins once. (Swiping left to leave the band is always a single quick step.)")
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

    /// §11.5 — the REAL launcher showing its AI band (the hero): a `LauncherView` seeded once with the AI
    /// band on (the last band) and landed on it (the resting frame shows the band). The ghost-hand autoplay
    /// plays the full path — 4-finger open → 2-finger traverse down to the AI band → the firing lift → a
    /// directed two-finger commit swipe — and the preview's `sync` seam replays the journey on the model
    /// (the resolve tail plays over it; the canvas isn't miniature); clockless, visibility-gated, never
    /// grows (see `docs/postmortem-idle-cpu-spin.md`).
    @StateObject private var demo = HubLauncherDemo()
    @State private var seeded = false
    /// The base autoplay journey, and the hover-demo override the canvas-resolve binding rows push in:
    /// hovering a row demos that action's currently-bound excursion as a directed canvas-resolve swipe.
    @State private var hoverGesture: GesturePose.DemoGesture?
    /// The excursion the hovered binding row maps to — stashed by the picker's `demoAxis` closure (an
    /// event-handler call) so the `demo` closure can build the matching directed candidate swipe. The
    /// `HubBindingPicker` is a shared component that speaks `GesturePose.Axis`; this bridges its hover
    /// signal to the preview's `DemoGesture` candidate without changing the component.
    @State private var hoveredExcursion: GestureBindings.CanvasExcursion?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _models = ObservedObject(wrappedValue: context.models)
    }

    /// The preview's attract journey: open the four-finger launcher → traverse DOWN the band list to the
    /// AI band (the real band-rail grammar, so the driven miniature can follow stroke for stroke) → the
    /// firing lift → a fresh directed downward canvas-commit swipe. The hover-demo override
    /// (`hoverGesture`) plays a candidate resolve instead.
    private static let aiJourney = HubLauncherDemo.bandJourneyGesture(openLength: 0.30, resolve: .swipeDown)

    /// The coarse axis a canvas excursion sweeps along (up/down ⇒ vertical, left/right ⇒ horizontal) —
    /// the `GesturePose.Axis` the shared `HubBindingPicker` component expects from `demoAxis`.
    private func axis(for excursion: GestureBindings.CanvasExcursion) -> GesturePose.Axis {
        switch excursion {
        case .swipeUp, .swipeDown:    return .vertical
        case .swipeLeft, .swipeRight: return .horizontal
        }
    }

    /// Map a canvas excursion to the directed resolve swipe its hover-demo should play (a standalone
    /// two-finger `canvasResolve` in that direction) — pushed into the preview's `hoverGesture`.
    private func candidate(for excursion: GestureBindings.CanvasExcursion) -> GesturePose.DemoGesture {
        switch excursion {
        case .swipeUp:    return GesturePose.canvasResolve(.swipeUp)
        case .swipeDown:  return GesturePose.canvasResolve(.swipeDown)
        case .swipeLeft:  return GesturePose.canvasResolve(.swipeLeft)
        case .swipeRight: return GesturePose.canvasResolve(.swipeRight)
        }
    }

    /// Seed once with the AI band on, landing the static preview on the last (AI) band.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let previewModels = HubPreviewModels(realWindowRows: context.realWindowRows,
                                             seedThumbnails: context.seedThumbnails,
                                             launcherBands: context.launcherBands)
        demo.seed(from: previewModels.makeLauncherModel(clipboardOn: false, aiOn: true, dwell: settings.dwellToArmDuration),
                  landOnLastBand: true)
    }

    /// Picker binding: maps `aiSelectedModelID` (nil = registry default) to the picker's optional-string.
    private var modelSelection: Binding<String?> {
        Binding(get: { settings.aiSelectedModelID },
                set: { settings.aiSelectedModelID = $0 })
    }

    /// The fleet roster's ACTIVE CHAT radio binding (`aiSelectedChatModelID`; nil = chat default).
    /// Whether this OS can run the on-device transcriber (`SpeechAnalyzer`, macOS 26).
    private var voiceOSSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The voice section's cost disclosure — includes the OS-floor message when it applies.
    private var voiceFootnote: String {
        if !voiceOSSupported {
            return "Requires macOS 26 (on-device speech recognition)."
        }
        return "Push-to-talk with the on-device assistant. The microphone opens ONLY while the key is held (asked for on first press) — no wake word, never always-listening. Speech is transcribed on this Mac; audio never leaves the device."
    }

    private var chatModelSelection: Binding<String?> {
        Binding(get: { settings.aiSelectedChatModelID },
                set: { settings.aiSelectedChatModelID = $0 })
    }

    /// The fleet roster's ENABLED CAPABILITY toggles binding (`aiEnabledCapabilityModelIDs`).
    private var capabilityModelSelection: Binding<Set<String>> {
        Binding(get: { settings.aiEnabledCapabilityModelIDs },
                set: { settings.aiEnabledCapabilityModelIDs = $0 })
    }

    /// The model the management surface shows: the user's pinned selection if it resolves, else default.
    private var selectedModelDescriptor: ModelDescriptor {
        let registry = ModelCatalog.standard
        if let id = settings.aiSelectedModelID, let d = registry.descriptor(id: id) { return d }
        return registry.defaultDescriptor ?? registry.models[0]
    }

    // MARK: - Context tuning + cost surface (tasks 5.2 / 5.3 / 5.4, design D5)

    /// The effective context-token budget for the chosen preset, clamped to the selected model's max.
    /// `agentContextTokens` is the persisted resolution; for a non-custom preset it follows the preset.
    private var effectiveContextTokens: Int {
        let modelMax = selectedModelDescriptor.maxContextTokens
        return settings.agentContextPreset.tokens(modelMax: modelMax, custom: settings.agentContextTokens)
    }

    /// The live cost surface (estimated RAM + concurrent-stream count + relative speed) for the chosen
    /// context — derived from the SAME pure `ConcurrencyBudget` the batched conformer uses (never silent
    /// OOM, house requirement). Recomputes whenever the preset / toggle / model changes.
    private var cost: AgentContextCostModel {
        AgentContextCostModel(contextTokens: effectiveContextTokens,
                              compactKV: settings.agentCompactKV,
                              weightBytes: selectedModelDescriptor.sizeBytes)
    }

    /// Picker binding: the preset segmented control writes the preset AND resolves `agentContextTokens` to
    /// the preset's token value (clamped to the model max) so the persisted budget the runtime / compaction
    /// reads always matches the chosen preset.
    private var presetSelection: Binding<AgentContextPreset> {
        Binding(get: { settings.agentContextPreset },
                set: { preset in
                    settings.agentContextPreset = preset
                    settings.agentContextTokens = preset.tokens(modelMax: selectedModelDescriptor.maxContextTokens,
                                                                custom: settings.agentContextTokens)
                })
    }

    @ViewBuilder private var contextSection: some View {
        HubSection("Context",
                   footnote: "Longer context remembers more of a conversation, skills, and memory — but the KV cache grows per background session, so more context means fewer concurrent background sessions and slower per-token speed. The estimate below updates as you choose; the foreground session always fits.") {
            // The Balanced / Long / Max preset (custom is implicit when a heavy skill raises it).
            Picker("Context size", selection: presetSelection) {
                ForEach([AgentContextPreset.balanced, .long, .max], id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.aiCommandsEnabled)

            // The single comprehensible KV-quant lever (8-bit) — a longer context fits the same RAM.
            Toggle("Compact long contexts (8-bit KV)", isOn: $settings.agentCompactKV)
                .disabled(!settings.aiCommandsEnabled)

            // The cost surface (RAM · concurrent background sessions · relative speed) — live.
            HStack(spacing: 6) {
                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                Text("\(effectiveContextTokens.formatted()) tokens · \(cost.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            // Per-skill override (read-only) — a heavy skill may raise the effective context (task 5.4).
            // The override value rides on the skill file (`ai-skills-as-files`); this surface only displays
            // that capability. With no skill source wired, the default resolves to no raise.
            if let overrideNote = skillOverrideNote {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.secondary)
                    Text(overrideNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Parked sessions (the opt-in auto-dismiss countdown)

    /// The auto-dismiss countdown surfaced in MINUTES: an idle, fully-seen session untouched this long is
    /// dismissed forever — **0 = never (the default)**. `agentParkAutoDismissCountdown` is persisted in
    /// SECONDS, so this binding divides on read / multiplies on write, keeping the Hub slider human.
    /// Clamped to whole minutes so the readout is clean.
    private var autoDismissMinutes: Binding<Double> {
        Binding(get: { (settings.agentParkAutoDismissCountdown / 60).rounded() },
                set: { settings.agentParkAutoDismissCountdown = max(0, $0.rounded()) * 60 })
    }

    @ViewBuilder private var parkedSessionsSection: some View {
        HubSection("Parked sessions",
                   footnote: "A conversation you park to the notch waits for you here — it keeps its results until you delete it. Set a countdown to auto-dismiss idle, already-seen sessions (0 = never; unseen results and sessions that need you always stay). Raise the cap to keep more parked at once.") {
            LabeledSlider(title: "Reveal dwell (seconds)", value: $settings.agentNotchRevealDwell,
                          range: 0...1, format: "%.2f",
                          help: "How long the cursor must linger behind the notch before the dock opens. Keeps a quick pass through the notch — reaching for the menu bar or another corner — from popping it. Set to 0 to open instantly. Default 0.30s.")
                .disabled(!settings.aiCommandsEnabled)

            LabeledSlider(title: "Auto-dismiss after (minutes, 0 = never)", value: autoDismissMinutes,
                          range: 0...30, format: "%.0f",
                          help: "How long an idle, already-seen session waits before it's dismissed forever. 0 (the default) keeps sessions until you delete them; sessions with unseen results never expire.")
                .disabled(!settings.aiCommandsEnabled)

            LabeledIntSlider(title: "Maximum parked sessions", value: $settings.agentMaxParkedSessions,
                             range: 1...12,
                             help: "Soft cap on parked sessions. When exceeded, the least-recently-used idle one is evicted (never an active or needs-you session).")
                .disabled(!settings.aiCommandsEnabled)
        }
    }

    /// The read-only per-skill-override note (task 5.4). Resolves the effective budget through the concrete
    /// `AgentContextBudgetProvider` (∩ model max ∩ per-skill override) — when a heavy skill raises it above
    /// the chosen preset, the note reports the raised number; otherwise it explains the capability.
    private var skillOverrideNote: String? {
        let provider = AgentContextBudgetProvider(userContextTokens: effectiveContextTokens,
                                                  modelMaxContextTokens: selectedModelDescriptor.maxContextTokens)
        let resolved = provider.maxContextTokens
        if resolved > effectiveContextTokens {
            return "A heavy skill raises the effective context to \(resolved.formatted()) tokens for that session."
        }
        return "A heavy skill may raise the effective context for its own session (read-only — authored on the skill)."
    }

    // MARK: - Release Full Potential (ai-full-potential-toggle, addendum §D1)

    /// Per-capability binding into `AppSettings` for the five sub-flags. The gate reads these at consult
    /// time; the Hub writes them directly (turning the master off NEVER zeroes them — see `panic-off`).
    private func subFlagBinding(_ capability: FullPotentialCapability) -> Binding<Bool> {
        switch capability {
        case .cpuLane:            return $settings.cpuLaneEnabled
        case .batchedRuntime:     return $settings.batchedRuntimeEnabled
        case .mediaGen:           return $settings.mediaGenEnabled
        case .backgroundAutonomy: return $settings.backgroundAutonomyEnabled
        case .fleetCloud:         return $settings.fleetCloudEscalationEnabled
        }
    }

    /// The sub-toggle's human title.
    private func subFlagTitle(_ capability: FullPotentialCapability) -> String {
        switch capability {
        case .cpuLane:            return "CPU lane"
        case .batchedRuntime:     return "Batched runtime"
        case .mediaGen:           return "Media generation"
        case .backgroundAutonomy: return "Background autonomy"
        case .fleetCloud:         return "Cloud escalation"
        }
    }

    /// The persistent, ALWAYS-VISIBLE cost line (RAM / heat / latency / $) — rendered inline as the row's
    /// caption, never behind a tooltip (design Decision 4; the honest-surface ethos). The media + cloud
    /// rows state the hard truths plainly: media evicts chat; cloud spends real money + sends data
    /// off-device.
    private func subFlagCost(_ capability: FullPotentialCapability) -> String {
        switch capability {
        case .cpuLane:
            return "Heat / battery — a second (CPU) lane runs concurrently for fast small jobs. Short structured bursts only; CPU per-token is slower."
        case .batchedRuntime:
            return "RAM + latency — multiplexes several background sessions over one weight read. Larger context means more resident KV cache, and latency rises under load."
        case .mediaGen:
            return "RAM (eviction) + latency + disk — a heavy generation evicts chat: the assistant goes quiet while it paints. Minutes per clip; tens of gigabytes of weights."
        case .backgroundAutonomy:
            return "Unattended action — the agent may act while you're away. Only whitelisted, contained writes auto-run; dangerous ones still ask, and everything is audited."
        case .fleetCloud:
            return "$ + network — spends real money and sends data off-device to a paid cloud model (Claude / GLM-5.2). Budget-capped + audited; off until you arm it."
        }
    }

    /// The Full Potential section: the master toggle FIRST, then the five sub-toggles (disabled while the
    /// master is off — visibly relocked — but their persisted values RETAINED). Each sub-row carries its
    /// cost inline. Shared Liquid Glass presentation (`HubSection` card). The whole section is itself gated
    /// behind the AI-commands opt-in (the fleet is a strict subset of the AI feature).
    @ViewBuilder private var fullPotentialSection: some View {
        HubSection("Release Full Potential",
                   footnote: "The agent ships calm: every heavy capability below is off until you release it here, and each states its own cost in the same breath it offers itself. Turning the master off relocks them all at once (your choices are kept, just inert) — a single calm panic-off. Cloud escalation stays off until you arm it: no surprise spend, no data leaving the device.") {
            // The master toggle FIRST. No cost line of its own — it just lights up the section.
            SwitchRow("Release Full Potential", isOn: $settings.fullPotentialEnabled,
                      caption: "Lights up the agent fleet. Each capability below states its own cost.")
                .disabled(!settings.aiCommandsEnabled)

            Divider()

            // The five sub-toggles, rendered by iterating the capability enum. Disabled (visibly relocked)
            // while the master is off; flipping the master off retains these stored values (no zeroing).
            ForEach(FullPotentialCapability.allCases, id: \.self) { capability in
                SwitchRow(subFlagTitle(capability),
                          isOn: subFlagBinding(capability),
                          caption: subFlagCost(capability))
                    .disabled(!settings.aiCommandsEnabled || !settings.fullPotentialEnabled)
            }
        }
    }

    var body: some View {
        HubPage(HubDestination.ai.title,
                subtitle: "Run on-device AI commands. Author the commands themselves on the Bands page.") {
            HubSection(footnote: "Runs an on-device Gemma 4 model — turning this on starts a one-time multi-gigabyte download. No new permission or logout needed (a calendar task asks for Calendar access the first time it runs). Add AI commands to any band on the Bands page. Off by default.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(
                        gesture: Self.aiJourney,
                        hoverGesture: hoverGesture,
                        // The sync seam: the miniature replays the journey to the AI band; the resolve
                        // tail and any hovered candidate swipe play over it (the canvas isn't miniature).
                        sync: { demo.drive($0, script: .bandJourneyResolve) }
                    ) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.ai.systemImage,
                    title: HubDestination.ai.title,
                    subtitle: "Run on-device AI commands on your selection, clipboard, or screen.",
                    isOn: $settings.aiCommandsEnabled
                )
                .onAppear { seedIfNeeded() }
            }
            HubSection("Resolve gestures",
                       footnote: "Choose which two-finger swipe commits, dismisses, or is ignored while the AI command canvas is open. Each move maps to one action — picking a taken move swaps it. Hover a row to preview the move above.") {
                HubBindingPicker(
                    actions: GestureBindings.CanvasAction.allCases,
                    excursions: GestureBindings.CanvasExcursion.allCases,
                    actionLabel: HubBindingLabels.canvasAction,
                    excursionLabel: HubBindingLabels.canvas,
                    current: { settings.gestureBindings.canvas.excursion(for: $0) },
                    assign: { excursion, action in
                        settings.gestureBindings.canvas = settings.gestureBindings.canvas.assigning(excursion, to: action)
                    },
                    demoAxis: { excursion in
                        // Stash the hovered excursion (event-handler context) so `demo` can build the
                        // matching directed candidate; return the coarse axis the component expects.
                        hoveredExcursion = excursion
                        return axis(for: excursion)
                    },
                    demo: { axis in
                        // The component signals enter (non-nil axis) / exit (nil); translate to a
                        // directed candidate swipe for the hovered excursion, or clear the override.
                        hoverGesture = (axis == nil) ? nil : hoveredExcursion.map { candidate(for: $0) }
                    }
                )
                .disabled(!settings.aiCommandsEnabled)
            }
            HubSection("Model",
                       footnote: "The fleet: a chat model + a small CPU model co-reside; an image or video model evicts chat while it generates (the assistant goes quiet, then reloads). Cloud models never run on-device and are off until you enable cloud escalation.") {
                // The §C1 fleet roster (`ai-model-fleet`, D6): role / lane / provider / per-model status /
                // honest residency cost, with the plan-driven evict-chat disclosure and the gated cloud
                // rows. `fleetCloudEscalationEnabled` is owned by `ai-full-potential-toggle` — consumed
                // here (default false) until that flag lands. Fleet-of-one renders as the single picker.
                HubFleetRosterView(cloudEscalationEnabled: { settings.fullPotentialGate.isUnlocked(.fleetCloud) },
                                   activeChatID: chatModelSelection,
                                   enabledCapabilityModelIDs: capabilityModelSelection,
                                   onDownloadCapabilityModel: context.onDownloadCapabilityModel,
                                   manager: models,
                                   aiEnabled: settings.aiCommandsEnabled)

                // The existing per-model lifecycle surface (download / status / evict / delete) for the
                // SELECTED model — preserved unchanged so the per-model status rule still holds.
                ModelManagementView(manager: models,
                                    descriptor: selectedModelDescriptor,
                                    onDownload: context.onDownloadModel)
                    .disabled(!settings.aiCommandsEnabled)

                // Idle-TTL for the resident weights (`model-idle-ttl-and-memory-pressure`): after this
                // long fully idle (no turn, no open chat, nothing scheduled) the loaded model is freed
                // from memory; the next command reloads it on demand. Memory-pressure eviction is
                // always armed and not a setting. "Never" = the pre-change keep-forever behavior.
                Picker("Free model memory after", selection: $settings.aiIdleEvictMinutes) {
                    Text("Never").tag(0)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                }
                .disabled(!settings.aiCommandsEnabled)
                .help("When the AI has been idle this long, the loaded model is freed from memory. The next command reloads it automatically.")
            }
            // Release Full Potential: the master gate + five cost-disclosing sub-toggles for the heavy
            // fleet capabilities (`ai-full-potential-toggle`, addendum §D1).
            fullPotentialSection
            HubSection("Reasoning",
                       footnote: "Let the model think before answering for higher-quality results (a bit slower). Thinking is never shown or pasted — only the final result.") {
                Toggle("Reasoning", isOn: $settings.aiReasoningEnabled)
                    .disabled(!settings.aiCommandsEnabled)
            }
            // Voice + computer use (`add-voice-computer-use-agent`): two separate opt-ins with honest
            // cost disclosure. Voice needs macOS 26 (SpeechAnalyzer) + the microphone permission on
            // first press; computer use reuses the existing Accessibility grant — no new permission.
            HubSection("Voice conversation",
                       footnote: voiceFootnote) {
                Toggle("Talk with the assistant (push-to-talk)", isOn: $settings.voiceConversationEnabled)
                    .disabled(!settings.aiCommandsEnabled || !voiceOSSupported)
                Text("Double-tap Right Option and hold the second press to talk; release to send. The same double-tap-and-hold interrupts it mid-reply. Any trackpad touch stops it. Single presses and shortcuts like ⌥⌫ are never affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HubSection("Computer use",
                       footnote: "The assistant can read windows, focus them, and — with your approval — click and type in them. Uses the Accessibility permission you already granted; no new permission. Every action needs approval unless you turn on auto mode for a conversation, and any trackpad touch instantly stops it.") {
                Toggle("Let the assistant use windows", isOn: $settings.computerUseEnabled)
                    .disabled(!settings.aiCommandsEnabled)
            }
            contextSection
            parkedSessionsSection
            // Background autonomy (`ai-background-autonomy`, §7): the user-editable trust boundary (the
            // whitelist) + the append-only "what your agents did while you were away" ledger.
            HubWhitelistEditor(trustedPaths: $settings.agentWhitelistPaths,
                               trustedCommands: $settings.agentWhitelistCommands,
                               isEnabled: settings.aiCommandsEnabled)
            HubAuditLogViewer(records: context.recentAuditRecords,
                              persistError: context.auditStorePersistError)
        }
        // Keep the status row tied to the SELECTED model: re-settle the manager's displayed state on
        // appear, when the picked model changes, and when AI is turned on — otherwise the single shared
        // status would keep showing whichever model was last active.
        .onAppear { models.showStatus(for: selectedModelDescriptor) }
        .onChange(of: settings.aiSelectedModelID) { models.showStatus(for: selectedModelDescriptor) }
        .onChange(of: settings.aiCommandsEnabled) {
            if settings.aiCommandsEnabled { models.showStatus(for: selectedModelDescriptor) }
        }
    }
}

// MARK: - Keyboard Language

struct KeyboardLanguagePage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings
    /// The live per-app/per-site memory. Observed so the "Saved sites" list updates the moment the engine
    /// learns a site — it's the same shared store the coordinator's service writes to.
    @ObservedObject private var keyboardStore = KeyboardLanguageStore.shared

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    var body: some View {
        HubPage(HubDestination.keyboardLanguage.title,
                subtitle: "Remember and auto-switch the keyboard language per app.") {
            HubSection(footnote: "Learns the keyboard input source you use in each app and re-selects it automatically when that app comes to the front — no manual setup. The language is remembered per app, learned from your own changes. No new permission or logout needed. Off by default.") {
                ToggleRow(title: "Remember the keyboard language per app", isOn: $settings.keyboardLanguageEnabled)
            }
            HubSection("Default for new apps",
                       footnote: "Applied to apps with no remembered language. Choose “None” to leave the current language untouched and learn from your next change.") {
                Picker("Default for new apps", selection: $settings.keyboardLanguageDefaultSourceID) {
                    Text("None").tag("")
                    ForEach(context.enabledInputSources(), id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .disabled(!settings.keyboardLanguageEnabled)
            }
            HubSection("In browsers") {
                ToggleRow(title: "Per-site language in browsers",
                          isOn: $settings.keyboardLanguagePerSiteEnabled,
                          caption: "Remembers the language per website. Works at host level on Chrome/Chromium; on Safari it’s domain-level until browser control is on.")
                    .disabled(!settings.keyboardLanguageEnabled)
                ToggleRow(title: "Allow browser control (exact per-site, incl. Safari)",
                          isOn: $settings.keyboardLanguageAllowBrowserControl,
                          caption: "Asks macOS for permission to read your browser’s current address via Automation; off ⇒ uses Accessibility only.")
                    .disabled(!settings.keyboardLanguagePerSiteEnabled)
            }
            if settings.keyboardLanguagePerSiteEnabled {
                savedSitesSection
            }
        }
    }

    /// The saved-sites list — every website you've set a specific language on (only ones you actively
    /// changed, not every site visited), each editable inline or removable. Doubles as a check that the
    /// in-browser detection is catching hosts: if it stays empty after you change a site's language, the
    /// address isn't being read (turn on "Allow browser control", especially for Safari).
    private var savedSitesSection: some View {
        HubSection("Saved sites",
                   footnote: "Sites you've set a specific language on — only ones you actively changed, not every site you visit. Change the language inline, or remove an entry. If this stays empty after you change a site's keyboard language, your browser's address isn't being read; turn on “Allow browser control” above (required for Safari).") {
            let entries = keyboardStore.siteEntries()
            if entries.isEmpty {
                Text("No sites saved yet. In a supported browser, change the keyboard language while on a site and it'll appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.host).font(.callout)
                            Text(entry.browserName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Picker("", selection: sourceBinding(forKey: entry.key, fallback: entry.source)) {
                            ForEach(context.enabledInputSources(), id: \.id) { source in
                                Text(source.name).tag(source.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                        Button { keyboardStore.removeSource(forBundleID: entry.key) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Forget \(entry.host)")
                    }
                }
            }
        }
        .disabled(!settings.keyboardLanguageEnabled)
    }

    /// A two-way binding for a saved site's language: reads the stored source (falling back to the row's
    /// known value), and writes the user's pick straight back into the shared store.
    private func sourceBinding(forKey key: String, fallback: String) -> Binding<String> {
        Binding(get: { keyboardStore.source(forBundleID: key) ?? fallback },
                set: { keyboardStore.setSource($0, forBundleID: key) })
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
            HubSection("General") {
                SwitchRow("Self-heal focus after switching", isOn: $settings.focusWatchdogEnabled,
                          caption: "Verifies the switched-to window actually receives focus and recovers automatically, so you never need Mission Control to escape a stuck state.")
                Divider()
                SwitchRow("Open at Login", isOn: Binding(
                    get: { _ = refresh; return context.isOpenAtLogin() },
                    set: { _ in context.onToggleOpenAtLogin(); refresh.toggle() }
                ))
                Divider()
                SwitchRow("Show diagnostic tools", isOn: $settings.showDiagnostics,
                          caption: "Adds “Write Diagnostics” and “Copy Focus Log” to the menu-bar menu — handy when reporting a bug. Off by default.")
            }
            HubSection {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { settings.resetToDefaults() }
                }
            }
            dangerZone
        }
    }

    // MARK: - Danger zone

    private var dangerZone: some View {
        HubSection("Danger zone",
                   footnote: "Each category is deleted only if its card is selected. Clearing app data or permissions relaunches the app; a data wipe restores any gesture relocations first (their backups live in the app data) and replays the welcome tour.") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ToggleCard("App data & settings", isOn: $wipeAppData,
                           caption: "Preferences, bands, AI commands, keyboard-language memory, clipboard history, project outputs, first-run state.")
                ToggleCard("Caches", isOn: $wipeCaches,
                           caption: "The app's cache and HTTP storage directories.")
                ToggleCard("AI models", isOn: $wipeAIModels,
                           caption: "The downloaded on-device model weights (multi-GB, re-downloadable). Turns the AI opt-in off.")
                ToggleCard("Permissions", isOn: $wipePermissions,
                           caption: "Resets every permission the app can hold (Accessibility, Screen Recording, Input Monitoring, Automation, Calendar, Reminders, Contacts) — macOS will prompt again.")
            }
            Divider()
            HStack {
                Button("Restore native gestures…") { context.onRestoreAllGestures() }
                    .help("Put every trackpad and Spaces setting the app changed back from its backup, and turn the gesture opt-ins off.")
                Spacer()
                Button("Clear selected…") { context.onDangerZoneClear(dangerSelection) }
                    .tint(.red)
                    .disabled(dangerSelection.isEmpty)
            }
        }
    }

    @State private var wipeAppData = false
    @State private var wipeCaches = false
    @State private var wipeAIModels = false
    @State private var wipePermissions = false

    private var dangerSelection: DangerZoneSelection {
        var selection: DangerZoneSelection = []
        if wipeAppData { selection.insert(.appData) }
        if wipeCaches { selection.insert(.caches) }
        if wipeAIModels { selection.insert(.aiModels) }
        if wipePermissions { selection.insert(.permissions) }
        return selection
    }
}

// MARK: - §13 Launcher demo holder (the user's REAL launcher, stepped by the sync drive)

/// The §13 holder behind the Launcher / Clipboard / Files / AI previews: it owns the **real** `LauncherModel`
/// (rendered by a real `LauncherView`), seeded once with the user's real bands so the preview shows the actual
/// launcher. Like `HubSwitcherDemo`, the model follows the ghost hand through the preview's **sync seam**
/// (`drive(_:script:)`): the four-finger open pops the panel in at the activation beat, the two-finger
/// vertical strokes step the band list, the teaching scrub crosses into the grid and steps the items (arming
/// the last one), and the final lift pops the panel out until the next loop. NOT the old free-running
/// `HubDemoDriver` (removed for the idle main-thread spin, `docs/postmortem-idle-cpu-spin.md`): the holder
/// owns no clock — frames arrive only from the preview's visibility-gated `TimelineView`, and every mutation
/// is state-guarded (idempotent per frame).
///
/// Band pages (Clipboard / Files / AI) seed with `landOnLastBand: true` so the preview's resting/static frame
/// *shows* their band (the last band) — the driven loop then replays the journey from the home band toward it.
@MainActor
final class HubLauncherDemo: ObservableObject {
    /// The real launcher model the preview renders (seeded once; stepped only by the sync drive).
    let model = LauncherModel()

    /// Whether the mini launcher is "open" in the teaching story: `true` while the ghost hand navigates,
    /// `false` between loops (after the closing lift, until the next open swipe crosses the activation
    /// beat). Defaults `true` so an undriven preview (hidden Hub's static frame, bare `#Preview`) shows it.
    @Published private(set) var overlayShown = true

    /// The seeded band content, retained so the drive can quietly re-seed the model between loops (the
    /// off-screen reset to the journey's start) and re-land it on the page's band for a hover-demo.
    private struct SeedState {
        var bands: [[LaunchItem]]
        var names: [String]
        var colors: [ItemColor]
        var icons: [ItemIcon]
        var clipboardBandIndex: Int?
        /// The band the page rests/presents on: the last band for the band pages, the home band otherwise.
        var restBand: Int
    }
    private var seedState: SeedState?

    // Sync-drive state (see the drive extension below): the item-scrub odometer's emitted steps, the last
    // script driven (a script change resets the odometer), and the hover presentation's one-shot latch.
    private var scrubStep = 0
    private var lastScript: SyncScript?
    private var hoverPresented = false

    /// Seed the model from a `HubPreviewModels`-built launcher (the user's real bands). `landOnLastBand`
    /// lands the selection on the last band (the Clipboard / Files / AI band) so a band page's resting
    /// preview shows that band; otherwise it rests on the home band, exactly as the real launcher opens.
    func seed(from source: LauncherModel, landOnLastBand: Bool = false) {
        model.dwell = source.dwell
        let startBand = landOnLastBand ? max(0, source.bandCount - 1) : 0
        seedState = SeedState(bands: source.bands, names: source.bandNames, colors: source.bandColors,
                              icons: source.bandIcons, clipboardBandIndex: source.clipboardBandIndex,
                              restBand: startBand)
        applySeed(startBand: startBand)
    }

    /// (Re)apply the stored seed at `startBand` — the drive's quiet reset (off-screen between loops) and
    /// the hover presentation both route through here. `setBands` re-lands focus and disarms, exactly as a
    /// fresh launcher open does.
    private func applySeed(startBand: Int) {
        guard let seed = seedState else { return }
        model.setBands(seed.bands, names: seed.names, colors: seed.colors,
                       icons: seed.icons, startBand: startBand, column: 0,
                       clipboardBandIndex: seed.clipboardBandIndex)
    }
}

// MARK: - §13 Launcher teaching gestures (real grammar via the connected-stroke seam)

extension HubLauncherDemo {
    /// The launcher's deterministic teaching gesture — the real usage story, mirroring
    /// `HubSwitcherDemo.teachingGesture`. A **four-finger** open swipe whose length tracks the activation
    /// distance, then — CONNECTED, no lift (`gapAfter: 0`, so two fingers lift while two stay down) — a
    /// two-finger DOWN step to switch a band, then a two-finger RIGHT scrub into the grid and across the
    /// items, then a lift and loop. Coordinates are y-UP (trackpad bottom-left origin — the pad renderer
    /// flips), so the "down one band" stroke travels to a SMALLER y.
    static func teachingGesture(openLength: CGFloat) -> GesturePose.DemoGesture {
        let openL = max(0.10, min(0.46, openLength))
        let xL: CGFloat = 0.30, xR: CGFloat = 0.74, homeY: CGFloat = 0.50, downY: CGFloat = 0.34
        // Four-finger open: a rightward swipe of `openL`, ending at `xL` so the two-finger nav has room to
        // travel right. `gapAfter: 0` keeps the hand DOWN — the next stroke drops to two fingers.
        let open = GesturePose.Stroke(fingers: 4,
                                      from: CGPoint(x: max(GesturePose.lowerBound, xL - openL), y: homeY),
                                      to: CGPoint(x: xL, y: homeY), gapAfter: 0)
        // Two-finger DOWN one band on the list (down the pad = next band), connected.
        let band = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: homeY), to: CGPoint(x: xL, y: downY),
                                      hold: 0.10, gapAfter: 0)
        // Two-finger RIGHT into the grid and across the items, then a settle.
        let items = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: downY), to: CGPoint(x: xR, y: downY),
                                       hold: 0.18)
        return GesturePose.DemoGesture(strokes: [open, band, items], liftGap: 0.6)
    }

    /// The band-journey teaching gesture (Clipboard / Files / AI): a **four-finger** open, then — CONNECTED —
    /// a long two-finger DOWN stroke that traverses the band list toward the last band, then a settle + lift.
    /// The traverse is target-based in the holder, so the exact stroke extent need only read as "down the
    /// bands"; the open length still tracks the activation distance. Coordinates are y-UP, so "down the band
    /// list" descends from `topY` to the smaller `botY`. An optional `resolve` appends the AI canvas's
    /// resolve tail: the traverse's lift *fires* the armed command, then a FRESH two-finger directed swipe
    /// (the real canvas grammar — a stray re-lift is a no-op; resolution is a new excursion) commits it.
    static func bandJourneyGesture(openLength: CGFloat,
                                   resolve: GesturePose.BandInSurfaceGesture? = nil) -> GesturePose.DemoGesture {
        let openL = max(0.10, min(0.46, openLength))
        let xL: CGFloat = 0.34, topY: CGFloat = 0.66, botY: CGFloat = 0.20
        let open = GesturePose.Stroke(fingers: 4,
                                      from: CGPoint(x: max(GesturePose.lowerBound, xL - openL), y: topY),
                                      to: CGPoint(x: xL, y: topY), gapAfter: 0)
        let traverse = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: topY), to: CGPoint(x: xL, y: botY),
                                          hold: 0.22)
        var strokes = [open, traverse]
        if let resolve, resolve != .lift {
            // A fresh, centered two-finger resolve after the firing lift (the canvas-resolve vocabulary).
            strokes.append(contentsOf: GesturePose.canvasResolve(resolve).strokes)
        }
        return GesturePose.DemoGesture(strokes: strokes, liftGap: 0.6)
    }

    /// Map the configurable activation threshold (`0.01…0.15`, the real trigger distance) to the demo's
    /// open-swipe length, so dragging "Activation threshold" visibly lengthens/shortens the ghost hand's
    /// opening swipe (mirrors `HubSwitcherDemo.openLength`). Always longer than the threshold so the engine
    /// activates partway through the visible swipe.
    static func openLength(forActivation threshold: Double) -> CGFloat {
        let clamped = min(0.15, max(0.01, threshold))
        let f = (clamped - 0.01) / (0.15 - 0.01)
        return CGFloat(0.18 + f * (0.44 - 0.18))
    }
}

// MARK: - §13 Sync drive (the launcher miniature follows the ghost hand)

extension HubLauncherDemo {
    /// Which autoplay script the incoming sync frames describe — the stroke-index → model-move mapping.
    enum SyncScript: Equatable {
        /// The Launcher page's attract loop: open → one band down → scrub into the grid and across the
        /// items (arming the last one) → lift.
        case teaching
        /// A band page's journey (Clipboard / Files): open → traverse the band list to the LAST band → lift.
        case bandJourney
        /// The AI page's journey: open → traverse to the AI band → the firing lift → a fresh two-finger
        /// canvas-resolve swipe (the tail drives nothing — the miniature never shows the canvas).
        case bandJourneyResolve
    }

    /// The band-step / grid-step pace, matching the real launcher's snappy selection moves.
    private static var stepAnimation: Animation { .easeInOut(duration: 0.22) }

    /// The final stroke of each script — the only lift that CLOSES the demo launcher. Earlier lifts within
    /// a loop (the AI journey's firing lift between traverse and resolve) keep the panel up, exactly as the
    /// real launcher stays up to show the canvas.
    private static func finalStrokeIndex(_ script: SyncScript) -> Int {
        switch script {
        case .teaching, .bandJourneyResolve: return 2
        case .bandJourney: return 1
        }
    }

    /// Step the model in time with one quantized ghost-hand frame. Called from the preview's `sync` seam —
    /// only while the visibility-gated clock runs (the postmortem guardrail) — and idempotent per frame:
    /// every mutation is guarded on current model state, so repeated, skipped, or resumed frames land
    /// safely anywhere in the loop.
    func drive(_ pose: GhostSyncPose, script: SyncScript) {
        guard seedState != nil else { return }
        if script != lastScript {
            lastScript = script
            scrubStep = 0
        }
        // A hover-demo plays a *candidate* excursion (a standalone resolve/discard swipe) whose stroke
        // indices mean nothing to the journey mapping: present the page's band statically underneath it
        // and drive nothing. Leaving the hover resumes the loop wherever the attract script is.
        if pose.hovering {
            presentForHover()
            return
        }
        hoverPresented = false
        if pose.lifted {
            if pose.strokeIndex >= Self.finalStrokeIndex(script) { setShown(false) }
            return
        }
        switch (script, pose.strokeIndex) {
        case (_, 0):
            openStroke(fraction: pose.fraction)
        case (.teaching, 1):
            if pose.fraction >= 0.5 { walkBands(to: min(1, model.bandCount - 1)) }
        case (.teaching, 2):
            scrubItems(fraction: pose.fraction)
        case (.bandJourney, 1), (.bandJourneyResolve, 1):
            walkBands(to: model.bandCount - 1, fraction: pose.fraction)
        default:
            // The AI resolve tail: the canvas isn't rendered in the miniature — nothing to drive.
            break
        }
    }

    /// The open swipe: short of the activation beat the panel stays hidden — and, freshly hidden from the
    /// previous loop's closing lift, quietly resets to the journey's start (home band, an instant
    /// off-screen re-seed) — then crossing the beat pops it in, the moment the real launcher appears.
    private func openStroke(fraction: Double) {
        if fraction < 0.45 {
            if !overlayShown, model.currentBand != 0 || scrubStep != 0 || model.arming || model.armed {
                scrubStep = 0
                applySeed(startBand: 0)
            }
        } else {
            setShown(true)
        }
    }

    /// Walk the band-list highlight DOWN toward `target`, one step per crossed odometer boundary (or all
    /// the way when `fraction` is omitted). Steps only while focus is on the band rail, so replayed frames
    /// can never leak steps into a grid.
    private func walkBands(to target: Int, fraction: Double = 1) {
        guard model.bandCount > 1, model.focus == .bands, target > 0 else { return }
        let desired = min(target, Int(fraction * Double(target + 1)))
        while model.currentBand < desired {
            withAnimation(Self.stepAnimation) { model.stepVertical(-1) }
        }
    }

    /// The teaching scrub: cross from the band rail into the grid, then step the highlight across the
    /// first row as the stroke advances — one step per crossed boundary, clamped like the real odometer.
    /// The stroke's settling hold dwells on the last item and ARMS it (the real dwell-to-arm), so the
    /// closing lift reads as firing the armed item.
    private func scrubItems(fraction: Double) {
        guard !model.items.isEmpty else { return }
        let itemsInRow = min(LauncherGridLayout.columns, model.items.count)
        let total = min(itemsInRow, 4)          // enter the grid + up to 3 item steps
        let desired = min(total, Int(fraction * Double(total + 1)))
        while scrubStep < desired {
            scrubStep += 1
            withAnimation(Self.stepAnimation) { model.stepHorizontal(1) }
        }
        if fraction >= 0.9, scrubStep >= total, model.focus == .grid, !model.arming, !model.armed {
            model.beginArming()
        }
    }

    /// Present the resting state under a hover-demo: the panel shown, landed on the page's band (the band
    /// pages' own band; the launcher page's home band), nothing mid-scrub. One-shot per hover entry.
    private func presentForHover() {
        guard !hoverPresented, let seed = seedState else { return }
        hoverPresented = true
        scrubStep = 0
        applySeed(startBand: seed.restBand)
        setShown(true)
    }

    private func setShown(_ shown: Bool) {
        guard overlayShown != shown else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { overlayShown = shown }
    }
}

/// The ACTUAL (native, 1:1) size of the real launcher for `model` — the size the grown rehearse overlay
/// presents at, and the natural size the small previews scale down from. This is the real launcher's own
/// `LauncherGridLayout` geometry, so the grown overlay IS the launcher at real size.
@MainActor
func launcherNaturalSize(_ model: LauncherModel) -> CGSize {
    let width = LauncherGridLayout.containerWidth
        + (model.bandCount > 1 ? LauncherGridLayout.bandColumnWidth : 0)
    let height = LauncherGridLayout.windowHeight(itemCount: model.items.count, bandCount: model.bandCount)
    return CGSize(width: width, height: height)
}

/// The §14 launcher-demo miniature: the **real** `LauncherView` over the holder's seeded model, shown small
/// (preview scale) — the preview "playing its part." The sync drive steps the model (band walk, item scrub,
/// arming) and flips `overlayShown` with the loop's open/close beats, so the clip reads as the real launcher
/// appearing, being navigated, and firing. Takes no hits (the preview disables hit-testing).
private struct LauncherDemoMiniature: View {
    @ObservedObject var demo: HubLauncherDemo
    @ObservedObject private var model: LauncherModel

    init(demo: HubLauncherDemo) {
        self.demo = demo
        _model = ObservedObject(wrappedValue: demo.model)
    }

    private let scale: CGFloat = 0.46

    var body: some View {
        let n = launcherNaturalSize(model)
        let h = min(n.height, 320)               // a compact preview slot
        LauncherView(model: model, executor: nil, availability: nil)
            .frame(width: n.width, height: h)
            .scaleEffect(scale * (demo.overlayShown ? 1.0 : 0.92))
            .opacity(demo.overlayShown ? 1 : 0)
            .frame(width: n.width * scale, height: h * scale)   // the slot is the SCALED size (no overflow)
            .allowsHitTesting(false)
    }
}

// MARK: - §13 Launcher action map (a legend of the teaching story)

/// A compact legend beneath the Launcher preview that spells out the gesture as a numbered story — the
/// launcher counterpart to `SwitcherActionMap`.
struct LauncherActionMap: View {
    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    private let steps: [Step] = [
        Step(symbol: "hand.raised.fill", title: "Slide four fingers", detail: "Swipe sideways to open your launcher"),
        Step(symbol: "hand.point.up.left.fill", title: "Lift two fingers", detail: "Keep two fingers resting to navigate"),
        Step(symbol: "arrow.up.arrow.down", title: "Up / down", detail: "Move between bands"),
        Step(symbol: "arrow.left.arrow.right", title: "Left / right", detail: "Move between items in the band"),
        Step(symbol: "checkmark.circle.fill", title: "Hold, then lift", detail: "Dwell on an item until it ticks, then lift to fire")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.accentColor.opacity(0.16)).frame(width: 26, height: 26)
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tint)
                    }
                    Image(systemName: step.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title).font(.callout).fontWeight(.medium)
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
