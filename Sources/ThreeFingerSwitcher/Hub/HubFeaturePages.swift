import SwiftUI

// Feature detail pages — the controls from the former Settings window, re-homed onto Hub pages and
// bound to the same `AppSettings` properties (same keys, defaults, and reset semantics). Each page
// leads with its master enable toggle; a disabled feature keeps its page with controls disabled.

// MARK: - Window Switcher

struct SwitcherPage: View {
    /// Stable identity for this page's gesture preview, so the rehearse controller can track which
    /// preview is focused across re-renders (a fresh `UUID()` per render would thrash registration).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §11.5 — the REAL mini switcher: a `SwitcherView` over the user's currently open windows (live
    /// thumbnails when Screen Recording is granted, icons otherwise), seeded once on appear and driven
    /// in sync with the ghost hand by `driver` (the `switcherDemo` directed strokes: 3-finger open →
    /// 2-finger scrub). The driver's `onScrub` maps the navigate-stroke centroid to the highlighted
    /// window (`centroid.x → setColumn`), exactly like `FirstTouchWizardModel.attractTick`.
    @StateObject private var switcherModel = SwitcherModel()
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false
    /// The hover-demo override pushed into the preview's driver by the direction pickers: hovering the
    /// windows-axis control demos a horizontal scrub, the Spaces-axis control a vertical one. `nil` ⇒
    /// the attract loop (the base `switcherDemo`).
    @State private var demoGesture: GesturePose.DemoGesture?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let model = SwitcherModel()
        _switcherModel = StateObject(wrappedValue: model)
        // `onScrub` maps the directed scrub's centroid.x → the highlighted window — the page's job
        // (the driver only knows strokes). Hover-demo retargets `driver.gesture` (below).
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: GesturePose.switcherDemo(),
            onScrub: { [weak model] centroid in
                guard let model, model.windows.count > 1 else { return }
                let col = min(model.windows.count - 1, max(0, Int(centroid.x * CGFloat(model.windows.count))))
                if col != model.selectedIndex { model.setColumn(col) }
            }))
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

    /// The Spaces-axis hover-demo: a three-finger open, then a decisive two-finger VERTICAL scrub
    /// (down then back) — the up/down Space-row slide, mirroring `switcherDemo`'s horizontal scrub.
    private static let spacesScrubDemo = GesturePose.DemoGesture(strokes: [
        GesturePose.Stroke(fingers: 3, from: CGPoint(x: 0.5, y: 0.30), to: CGPoint(x: 0.5, y: 0.55)),
        GesturePose.Stroke(fingers: 2, from: CGPoint(x: 0.5, y: 0.28), to: CGPoint(x: 0.5, y: 0.72))
    ], liftGap: 0.5)

    /// Seed the mini switcher once with the user's real windows + live thumbnails (degrades to sample
    /// art / icons through `HubPreviewModels`). The holder builds a fully seeded model; its rows + any
    /// synchronous frames are copied into the rendered `@StateObject`, then `seedThumbnails` is re-run
    /// against the rendered model so the post-reveal retry sweeps land its live captures HERE. Sized to a
    /// wide-but-short mini canvas so the scaled grid reads as the real switcher strip.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let canvas = CGSize(width: 820, height: 150)
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        let seededModel = models.makeSwitcherModel(canvas: canvas)
        switcherModel.setCanvas(canvas)
        switcherModel.setRows(seededModel.rows, labels: seededModel.rowLabels,
                              startRow: 0, column: seededModel.selectedIndex)
        // Carry over the holder's synchronous frames (sample art for the no-windows fallback, or any
        // already-captured live thumbnails) — `setRows` cleared the rendered model's thumbnail map.
        for (id, image) in seededModel.thumbnails { switcherModel.setThumbnail(image, for: id) }
        // Re-run seeding against the RENDERED model (now populated with windows) so the live-capture
        // retry sweeps target it, not the discarded holder model.
        context.seedThumbnails(switcherModel)
    }

    var body: some View {
        HubPage(HubDestination.switcher.title,
                subtitle: "Switch windows with a three-finger horizontal swipe — and Spaces by sliding up/down.") {
            HubSection {
                HubFeatureHeader(
                    preview: HubGesturePreview(driver: driver) {
                        SwitcherView(model: switcherModel)
                            .scaleEffect(0.42)
                            .frame(width: 360, height: 92)
                    },
                    icon: HubDestination.switcher.systemImage,
                    title: HubDestination.switcher.title,
                    subtitle: "Switch windows with three fingers; switch Spaces by sliding up/down.",
                    isOn: $settings.enabled,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
                )
                .onAppear { seedIfNeeded() }
                // Hover the windows-axis control ⇒ demo the horizontal scrub; the Spaces-axis control ⇒
                // a vertical scrub. The pickers below drive `demoGesture`; clearing it restores the base.
                .onChange(of: demoGesture) { _, new in driver.hoverGesture = new }
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
                .onHover { demoGesture = $0 ? GesturePose.switcherDemo() : nil }
                Toggle("Require exactly three fingers", isOn: $settings.requireExactlyThree)
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
                .onHover { demoGesture = $0 ? Self.spacesScrubDemo : nil }
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
        }
    }
}

// MARK: - Launcher

struct LauncherPage: View {
    /// Stable identity for this page's gesture preview (see `SwitcherPage.previewToken`).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §11.5 — the REAL launcher demo, owned by a `HubLauncherDemo` holder so the driver's one-shot
    /// open/dismiss + per-frame scrub closures (captured in `init`) can drive the same model + launch-in
    /// flag the view observes. Driven by `launcherOpen()` (4-finger open → 2-finger navigate → 4-finger
    /// dismiss) — exactly the onboarding playground's launch-in / dismiss.
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: GesturePose.launcherOpen(),
            onScrub: { [weak holder] centroid in holder?.scrub(centroid) },
            onOpen: { [weak holder] in holder?.open() },
            onDismiss: { [weak holder] in holder?.dismiss() }))
    }

    /// Seed the launcher once with the user's real bands (favorites only — clipboard/AI off here). Lands
    /// on the band list at the home band, exactly as the real launcher does.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: false, aiOn: false,
                                                 dwell: settings.dwellToArmDuration))
    }

    var body: some View {
        HubPage(HubDestination.launcher.title,
                subtitle: "A four-finger launcher of your apps, scripts, and commands.") {
            HubSection(footnote: "Slide four fingers horizontally to open a launcher of your favorite apps, scripts, and presets; dwell on an item and lift to fire it. Frees the native four-finger swipe gestures (Mission Control / App Exposé stay on three-finger up/down). Changes a system setting that needs a logout/restart to take effect and stays applied until you turn it off.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(driver: driver) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.launcher.systemImage,
                    title: HubDestination.launcher.title,
                    subtitle: "Open a launcher of apps, scripts, and commands with four fingers.",
                    isOn: $settings.enableLauncher,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
                )
                .onAppear { seedIfNeeded() }
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
    /// Stable identity for this page's gesture preview (see `SwitcherPage.previewToken`).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §11.5 — the REAL launcher showing its CLIPBOARD band: a `LauncherView` seeded with the clipboard
    /// band on (it is the last band), driven by `bandJourney(bandFraction: 1.0, inSurface: .lift)` — the
    /// full path: 4-finger open → 2-finger traverse to the Clipboard band → land/lift. The holder's
    /// `scrub` traverses toward the target band in sync with the traverse stroke.
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: GesturePose.bandJourney(bandFraction: 1.0, inSurface: .lift),
            onScrub: { [weak holder] centroid in holder?.scrub(centroid) },
            onOpen: { [weak holder] in holder?.open() },
            onDismiss: { [weak holder] in holder?.dismiss() }))
    }

    private var maxBytesMB: Binding<Double> {
        Binding(get: { Double(settings.clipboardMaxBytes) / (1024 * 1024) },
                set: { settings.clipboardMaxBytes = Int($0 * 1024 * 1024) })
    }

    /// Seed once with the clipboard band on, then point the holder's scrub at the Clipboard band (the last
    /// band) so the traverse stroke lands on it.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: true, aiOn: false,
                                                 dwell: settings.dwellToArmDuration),
                  traverseToLastBand: true)
    }

    var body: some View {
        HubPage(HubDestination.clipboard.title,
                subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.") {
            HubSection(footnote: "Records what you copy — text, images, files, colors, links — into a Clipboard band shown as the last band in the four-finger launcher. Scrub to an entry and lift to paste it where you were. Stored only on this Mac; password-manager copies and excluded apps are never recorded. No new permission or logout needed. Off by default.") {
                HubFeatureHeader(
                    preview: HubGesturePreview(driver: driver) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.clipboard.systemImage,
                    title: HubDestination.clipboard.title,
                    subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.",
                    isOn: $settings.keepClipboardHistory,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
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
    /// Stable identity for this page's gesture preview (see `SwitcherPage.previewToken`).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var models: ModelManager

    /// §11.5 — the REAL launcher showing its AI band (the hero): a `LauncherView` seeded with the AI band
    /// on (the last band), driven by `bandJourney(bandFraction: 0.5, inSurface: .swipeDown)` — the full
    /// path: 4-finger open → 2-finger traverse to the AI band → a directed two-finger downward commit
    /// swipe. The holder's `scrub` traverses toward the AI band in sync with the traverse stroke.
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false
    /// The hover-demo override pushed into the preview's driver by the canvas-resolve binding rows:
    /// hovering a row demos that action's currently-bound excursion as a directed canvas-resolve swipe.
    @State private var demoGesture: GesturePose.DemoGesture?
    /// The excursion the hovered binding row maps to — stashed by the picker's `demoAxis` closure (an
    /// event-handler call) so the `demo` closure can build the matching directed candidate swipe. The
    /// `HubBindingPicker` is a shared component that speaks `GesturePose.Axis`; this bridges its hover
    /// signal to the driven preview's `DemoGesture` candidate without changing the component.
    @State private var hoveredExcursion: GestureBindings.CanvasExcursion?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        _models = ObservedObject(wrappedValue: context.models)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: Self.aiJourney,
            onScrub: { [weak holder] centroid in holder?.scrub(centroid) },
            onOpen: { [weak holder] in holder?.open() },
            onDismiss: { [weak holder] in holder?.dismiss() }))
    }

    /// The preview's attract journey: open the four-finger launcher → traverse to the AI band → a directed
    /// downward canvas-commit swipe. The hover-demo override (`demoGesture`) plays a candidate resolve.
    private static let aiJourney = GesturePose.bandJourney(bandFraction: 0.5, inSurface: .swipeDown)

    /// The coarse axis a canvas excursion sweeps along (up/down ⇒ vertical, left/right ⇒ horizontal) —
    /// the `GesturePose.Axis` the shared `HubBindingPicker` component expects from `demoAxis`.
    private func axis(for excursion: GestureBindings.CanvasExcursion) -> GesturePose.Axis {
        switch excursion {
        case .swipeUp, .swipeDown:    return .vertical
        case .swipeLeft, .swipeRight: return .horizontal
        }
    }

    /// Map a canvas excursion to the directed resolve swipe its hover-demo should play (a standalone
    /// two-finger `canvasResolve` in that direction) — driven into the preview's `driver.hoverGesture`.
    private func candidate(for excursion: GestureBindings.CanvasExcursion) -> GesturePose.DemoGesture {
        switch excursion {
        case .swipeUp:    return GesturePose.canvasResolve(.swipeUp)
        case .swipeDown:  return GesturePose.canvasResolve(.swipeDown)
        case .swipeLeft:  return GesturePose.canvasResolve(.swipeLeft)
        case .swipeRight: return GesturePose.canvasResolve(.swipeRight)
        }
    }

    /// Seed once with the AI band on, then point the holder's scrub at the AI band (the last band) so the
    /// traverse stroke lands on it.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let previewModels = HubPreviewModels(realWindowRows: context.realWindowRows,
                                             seedThumbnails: context.seedThumbnails,
                                             launcherBands: context.launcherBands)
        demo.seed(from: previewModels.makeLauncherModel(clipboardOn: false, aiOn: true,
                                                        dwell: settings.dwellToArmDuration),
                  traverseToLastBand: true)
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
                HubFeatureHeader(
                    preview: HubGesturePreview(driver: driver) {
                        LauncherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.ai.systemImage,
                    title: HubDestination.ai.title,
                    subtitle: "Run on-device AI commands on your selection, clipboard, or screen.",
                    isOn: $settings.aiCommandsEnabled,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
                )
                .onAppear { seedIfNeeded() }
                .onChange(of: demoGesture) { _, new in driver.hoverGesture = new }
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
                        demoGesture = (axis == nil) ? nil : hoveredExcursion.map { candidate(for: $0) }
                    }
                )
                .disabled(!settings.aiCommandsEnabled)
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
            HubSection("Reasoning",
                       footnote: "Let the model think before answering for higher-quality results (a bit slower). Thinking is never shown or pasted — only the final result.") {
                Toggle("Reasoning", isOn: $settings.aiReasoningEnabled)
                    .disabled(!settings.aiCommandsEnabled)
            }
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
            dangerZone
        }
    }

    // MARK: - Danger zone

    private var dangerZone: some View {
        HubSection("Danger zone",
                   footnote: "Each category is deleted only if its switch is on. Clearing app data or permissions relaunches the app; a data wipe restores any gesture relocations first (their backups live in the app data) and replays the welcome tour.") {
            ToggleRow(title: "App data & settings", isOn: $wipeAppData,
                      caption: "Preferences, bands, AI commands, keyboard-language memory, clipboard history, project outputs, first-run state.")
            Divider()
            ToggleRow(title: "Caches", isOn: $wipeCaches,
                      caption: "The app's cache and HTTP storage directories.")
            Divider()
            ToggleRow(title: "AI models", isOn: $wipeAIModels,
                      caption: "The downloaded on-device model weights (multi-GB, re-downloadable). Turns the AI opt-in off.")
            Divider()
            ToggleRow(title: "Permissions", isOn: $wipePermissions,
                      caption: "Resets every permission the app can hold (Accessibility, Screen Recording, Input Monitoring, Automation, Calendar, Reminders, Contacts) — macOS will prompt again.")
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

// MARK: - §11.5 Driven launcher demo (the real overlay, in sync with the ghost hand)

/// The §11.5 holder behind the Launcher / Clipboard / AI previews: it owns the **real** `LauncherModel`
/// (rendered by a real `LauncherView`) and the launch-in flag, and exposes the three driving entry
/// points the `HubDemoDriver`'s stroke closures call so the launcher reacts in sync with the demonstrated
/// gesture — `open()` launches it in on the 4-finger open stroke, `scrub(_:)` traverses / navigates on
/// the 2-finger strokes, `dismiss()` recedes it on the 4-finger dismiss. It is an `ObservableObject` so
/// the driver's closures (captured at the page's `init`, before any `@State` exists) can drive the same
/// model + flag the view observes — the `@State`-binding-in-`init` problem the wizard's demo model also
/// sidesteps by owning its model.
///
/// Two modes, set at `seed`: a plain launcher (navigate items within the home band) and a **band
/// journey** (`traverseToLastBand`) that steps the band selection across to the last band (the
/// Clipboard / AI band, appended last by `WizardTourBands.compose`) as the traverse stroke crosses the
/// pad — so the demo's "traverse to the band" reads on the real launcher.
@MainActor
final class HubLauncherDemo: ObservableObject {
    /// The real launcher model the preview renders + the strokes drive.
    let model = LauncherModel()
    /// The launch-in flag: `true` between an open stroke and the matching dismiss (the launcher is shown
    /// morphed on); `false` at rest (it recedes). Animated by the view.
    @Published private(set) var launched = false

    /// When true (Clipboard / AI), `scrub` traverses the band selection toward the LAST band; when false
    /// (Launcher), `scrub` navigates item selection within the current band.
    private var traverseToLastBand = false
    /// The last band index — the traverse target (the Clipboard / AI band is appended last).
    private var lastBandIndex = 0

    /// Seed the model from a `HubPreviewModels`-built launcher (the user's real bands). `traverseToLastBand`
    /// selects the band-journey mode. Lands on the band list at the home band, exactly as the real launcher.
    func seed(from source: LauncherModel, traverseToLastBand: Bool = false) {
        self.traverseToLastBand = traverseToLastBand
        self.lastBandIndex = max(0, source.bandCount - 1)
        model.setBands(source.bands, names: source.bandNames, colors: source.bandColors,
                       icons: source.bandIcons, startBand: 0, column: 0,
                       clipboardBandIndex: source.clipboardBandIndex)
    }

    /// The open stroke landed: launch the launcher in and reset to a clean starting state (the home band
    /// list for a journey; crossed one step into the grid for the plain launcher, so item scrub has room).
    func open() {
        // Reset selection to the home band before showing — re-running the loop starts clean.
        model.setBands(model.bands, names: model.bandNames, colors: model.bandColors,
                       icons: model.bandIcons, startBand: 0, column: 0,
                       clipboardBandIndex: model.clipboardBandIndex)
        if !traverseToLastBand, model.bandCount > 0 {
            model.stepHorizontal(1)   // cross into the grid so the navigate stroke moves items
        }
        withAnimation(.easeOut(duration: 0.32)) { launched = true }
    }

    /// The dismiss stroke landed: recede the launcher.
    func dismiss() {
        withAnimation(.easeIn(duration: 0.28)) { launched = false }
    }

    /// A navigate-stroke frame: step the model toward the journey's target (the last band) or, for the
    /// plain launcher, toward the item nearest the stroke's centroid.x — so the band selection / highlight
    /// advances in sync with the ghost hand. Idempotent per target (only steps on a change). In journey
    /// mode the target is ALWAYS the last band (the Clipboard / AI band): the `bandFraction` controls only
    /// where the GHOST HAND lands on the pad, not which band is the destination, so a half-way ghost
    /// landing (AI) must still traverse to the final band.
    func scrub(_ centroid: CGPoint) {
        if traverseToLastBand {
            stepBand(toward: lastBandIndex)
        } else {
            stepItem(toward: progressAcross(centroid.x))
        }
    }

    /// Normalize a pad x in `[lowerBound, upperBound]` to 0…1 travel.
    private func progressAcross(_ x: CGFloat) -> CGFloat {
        let lo = GesturePose.lowerBound, hi = GesturePose.upperBound
        return min(1, max(0, (x - lo) / (hi - lo)))
    }

    /// Step the active band toward `target` (clamped). Band switching lives on the band list, so make sure
    /// the focus is there first; `stepVertical(-1)` moves to the NEXT band (down the list), `+1` previous.
    private func stepBand(toward target: Int) {
        let clamped = min(lastBandIndex, max(0, target))
        guard clamped != model.currentBand else { return }
        guard model.focus == .bands else {
            // Crossed into the grid earlier (shouldn't happen in journey mode); cross back so the
            // vertical band step applies.
            model.stepHorizontal(-1)
            return
        }
        let dir = clamped > model.currentBand ? -1 : 1   // down the list = next band = dir -1
        // One step per frame toward the target — the eased stroke visits enough frames to arrive.
        model.stepVertical(dir)
    }

    /// Step the grid selection toward the item nearest `progress` (0…1 across the current band's items).
    private func stepItem(toward progress: CGFloat) {
        guard model.focus == .grid, !model.items.isEmpty else { return }
        let target = min(model.items.count - 1, max(0, Int((progress * CGFloat(model.items.count)).rounded(.down))))
        guard target != model.selectedIndex else { return }
        model.stepHorizontal(target > model.selectedIndex ? 1 : -1)
    }
}

/// The §11.5 launcher-demo miniature: the **real** `LauncherView` over the holder's seeded model, scaled
/// to a tasteful Hub mini and launched in / receded with the holder's `launched` flag (a soft morph, like
/// the onboarding playground). Takes no hits (the preview disables hit-testing).
private struct LauncherDemoMiniature: View {
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
