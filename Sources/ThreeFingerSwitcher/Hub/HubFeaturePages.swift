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

    /// §12 — the REAL mini switcher: a `SwitcherView` over the user's open windows grouped into Space-rows
    /// (true proportions + live thumbnails; icon-only fallbacks), owned by a `HubSwitcherDemo` holder so the
    /// driver's one-shot `onOpen` + per-frame `onScrub` closures (captured in `init`) drive the same model
    /// the view observes. The demo teaches the full deterministic story — three-finger open → lift one →
    /// up/down Spaces → sideways windows — with the highlight + Space reel moving in sync.
    @StateObject private var demo: HubSwitcherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false
    /// The hover-demo override pushed into the preview's driver by the direction pickers: hovering the
    /// windows-axis control demos a sideways window scrub, the Spaces-axis control an up/down Space move.
    /// `nil` ⇒ the base teaching demo.
    @State private var demoGesture: GesturePose.DemoGesture?

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubSwitcherDemo()
        _demo = StateObject(wrappedValue: holder)
        // The driver plays the teaching gesture; its closures drive the holder's model in sync — `onOpen`
        // resets to the home row each loop, `onScrub` maps the 2-finger centroid to (row, column). The open
        // swipe length tracks the activation threshold so the demo reflects the real trigger distance.
        let settingsRef = context.settings
        let demoDriver = HubDemoDriver(
            gesture: HubSwitcherDemo.teachingGesture(
                openLength: HubSwitcherDemo.openLength(forActivation: settingsRef.activationThreshold)),
            onScrub: { [weak holder] centroid in holder?.navigate(centroid) },
            onOpen: { [weak holder] in holder?.reset() })
        // A REAL swipe is NOT rehearsed in-section. While the user is on this page the genuine switcher
        // overlay itself rises (the real recognizer drives it) and is neutralized so it never fires — see
        // `AppCoordinator.switcherDemoActive`. So `onRehearse` is intentionally left unwired: the in-section
        // miniature stays the idle teaching loop, and the "grow into the ACTUAL switcher" is the real overlay.
        _driver = StateObject(wrappedValue: demoDriver)
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
                    preview: HubGesturePreview(driver: driver) {
                        SwitcherDemoMiniature(demo: demo)
                    },
                    icon: HubDestination.switcher.systemImage,
                    title: HubDestination.switcher.title,
                    subtitle: "Switch windows with three fingers; switch Spaces by sliding up/down.",
                    isOn: $settings.enabled,
                    rehearseToken: Self.previewToken,
                    rehearseController: context.rehearse
                )
                .onAppear { seedIfNeeded() }
                // Hover the windows-axis control ⇒ demo a sideways window scrub; the Spaces-axis control ⇒
                // an up/down Space move. The pickers below drive `demoGesture`; clearing it restores the base.
                .onChange(of: demoGesture) { _, new in driver.hoverGesture = new }
                // Live window-size: dragging "Window size" grows/shrinks the preview cards in real time.
                .onChange(of: settings.switcherWindowScale) { _, scale in
                    demo.setMaxScale(SwitcherLayout.kMax * CGFloat(scale))
                }
                // The demo's opening swipe tracks the real activation distance as you tune it.
                .onChange(of: settings.activationThreshold) { _, threshold in
                    driver.gesture = HubSwitcherDemo.teachingGesture(
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
                .onHover { demoGesture = $0 ? HubSwitcherDemo.windowsHoverGesture() : nil }
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
                .onHover { demoGesture = $0 ? HubSwitcherDemo.spacesHoverGesture() : nil }
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

    /// §13 — the user's REAL launcher demo. The `HubLauncherDemo` holder owns the model + the grow flag; the
    /// driver plays the deterministic teaching story (4-finger open → lift two → up/down bands → left/right
    /// items) and, via `onRehearse`, hands the user's real fingers to the same settings-driven engine so a
    /// real swipe GROWS the launcher and navigates it (never fires). The open swipe length tracks the
    /// activation threshold; all tunables update the preview live (`.onChange`s below).
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        let driver = HubDemoDriver(
            gesture: HubLauncherDemo.teachingGesture(
                openLength: HubLauncherDemo.openLength(forActivation: context.settings.launcherActivationThreshold)),
            onScrub: { [weak holder] centroid in holder?.idleNavigate(centroid) },
            onOpen: { [weak holder] in holder?.idleOpen() })
        // Real-finger rehearse: drive the engine (grow + navigate) from the user's live touch; the lift edge
        // (`nil, 0`) recedes + disarms — never fires.
        driver.onRehearse = { [weak holder] centroid, fingers in
            if let centroid { holder?.rehearseFrame(centroid, fingerCount: fingers) } else { holder?.rehearseEnd() }
        }
        _driver = StateObject(wrappedValue: driver)
    }

    /// Seed the launcher once with the user's real bands (favorites only — clipboard/AI off here) and load the
    /// live tunables into the engine. Lands on the band list at the home band, exactly as the real launcher.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: false, aiOn: false, dwell: settings.dwellToArmDuration),
                  mode: .launcher, dwell: settings.dwellToArmDuration,
                  activation: CGFloat(settings.launcherActivationThreshold),
                  itemStep: CGFloat(settings.launcherStepDistance),
                  bandStep: CGFloat(settings.launcherContextStepDistance))
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
                // The opening swipe tracks the real activation distance; every tunable reflects in the preview
                // live (single source of truth — the engine reads the same settings the real launcher does).
                .onChange(of: settings.launcherActivationThreshold) { _, t in
                    driver.gesture = HubLauncherDemo.teachingGesture(openLength: HubLauncherDemo.openLength(forActivation: t))
                    demo.updateDistances(activation: CGFloat(t),
                                         itemStep: CGFloat(settings.launcherStepDistance),
                                         bandStep: CGFloat(settings.launcherContextStepDistance))
                }
                .onChange(of: settings.launcherStepDistance) { _, s in
                    demo.updateDistances(activation: CGFloat(settings.launcherActivationThreshold),
                                         itemStep: CGFloat(s),
                                         bandStep: CGFloat(settings.launcherContextStepDistance))
                }
                .onChange(of: settings.launcherContextStepDistance) { _, b in
                    demo.updateDistances(activation: CGFloat(settings.launcherActivationThreshold),
                                         itemStep: CGFloat(settings.launcherStepDistance),
                                         bandStep: CGFloat(b))
                }
                .onChange(of: settings.dwellToArmDuration) { _, d in demo.setDwell(d) }
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
        // While a real rehearsal opens the launcher, it morphs into the user's ACTUAL launcher floating over
        // the page at real size, navigable by their own fingers — never fires.
        .overlay { GrownLauncherOverlay(demo: demo) }
    }
}

// MARK: - Clipboard

struct ClipboardPage: View {
    /// Stable identity for this page's gesture preview (see `SwitcherPage.previewToken`).
    static let previewToken = UUID()

    let context: HubContext
    @ObservedObject private var settings: AppSettings

    /// §13 — the REAL launcher showing its CLIPBOARD band: a `LauncherView` seeded with the clipboard band on
    /// (it is the last band), playing the full path — 4-finger open → 2-finger traverse down to the Clipboard
    /// band → land. A real four-finger rehearsal GROWS it under the hand (`onRehearse`), never firing.
    @StateObject private var demo: HubLauncherDemo
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
        let holder = HubLauncherDemo()
        _demo = StateObject(wrappedValue: holder)
        let driver = HubDemoDriver(
            gesture: HubLauncherDemo.bandJourneyGesture(
                openLength: HubLauncherDemo.openLength(forActivation: context.settings.launcherActivationThreshold)),
            onScrub: { [weak holder] centroid in holder?.idleNavigate(centroid) },
            onOpen: { [weak holder] in holder?.idleOpen() })
        driver.onRehearse = { [weak holder] centroid, fingers in
            if let centroid { holder?.rehearseFrame(centroid, fingerCount: fingers) } else { holder?.rehearseEnd() }
        }
        _driver = StateObject(wrappedValue: driver)
    }

    private var maxBytesMB: Binding<Double> {
        Binding(get: { Double(settings.clipboardMaxBytes) / (1024 * 1024) },
                set: { settings.clipboardMaxBytes = Int($0 * 1024 * 1024) })
    }

    /// Seed once with the clipboard band on, in band-journey mode (traverse to the last band) with the live
    /// launcher tunables loaded.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let models = HubPreviewModels(realWindowRows: context.realWindowRows,
                                      seedThumbnails: context.seedThumbnails,
                                      launcherBands: context.launcherBands)
        demo.seed(from: models.makeLauncherModel(clipboardOn: true, aiOn: false, dwell: settings.dwellToArmDuration),
                  mode: .bandJourney, dwell: settings.dwellToArmDuration,
                  activation: CGFloat(settings.launcherActivationThreshold),
                  itemStep: CGFloat(settings.launcherStepDistance),
                  bandStep: CGFloat(settings.launcherContextStepDistance))
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
        // A real rehearsal morphs the preview into the actual launcher (showing the Clipboard band) at real
        // size, floating over the page, navigable — never fires.
        .overlay { GrownLauncherOverlay(demo: demo) }
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
        let driver = HubDemoDriver(
            gesture: Self.aiJourney,
            onScrub: { [weak holder] centroid in holder?.idleNavigate(centroid) },
            onOpen: { [weak holder] in holder?.idleOpen() })
        driver.onRehearse = { [weak holder] centroid, fingers in
            if let centroid { holder?.rehearseFrame(centroid, fingerCount: fingers) } else { holder?.rehearseEnd() }
        }
        _driver = StateObject(wrappedValue: driver)
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
        demo.seed(from: previewModels.makeLauncherModel(clipboardOn: false, aiOn: true, dwell: settings.dwellToArmDuration),
                  mode: .bandJourney, dwell: settings.dwellToArmDuration,
                  activation: CGFloat(settings.launcherActivationThreshold),
                  itemStep: CGFloat(settings.launcherStepDistance),
                  bandStep: CGFloat(settings.launcherContextStepDistance))
    }

    /// Picker binding: maps `aiSelectedModelID` (nil = registry default) to the picker's optional-string.
    private var modelSelection: Binding<String?> {
        Binding(get: { settings.aiSelectedModelID },
                set: { settings.aiSelectedModelID = $0 })
    }

    /// The fleet roster's ACTIVE CHAT radio binding (`aiSelectedChatModelID`; nil = chat default).
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

    // MARK: - Parked sessions (design D1 — the auto-dismiss countdown)

    /// The auto-dismiss countdown surfaced in MINUTES (design D1): a parked/idle (or task-completed)
    /// session untouched this long is dismissed forever. `agentParkAutoDismissCountdown` is persisted in
    /// SECONDS, so this binding divides on read / multiplies on write, keeping the Hub slider human (minutes,
    /// default 5). Clamped to whole minutes so the readout is clean.
    private var autoDismissMinutes: Binding<Double> {
        Binding(get: { (settings.agentParkAutoDismissCountdown / 60).rounded() },
                set: { settings.agentParkAutoDismissCountdown = max(1, $0.rounded()) * 60 })
    }

    @ViewBuilder private var parkedSessionsSection: some View {
        HubSection("Parked sessions",
                   footnote: "A conversation you park to the notch waits for you here. Untouched past this countdown — or once its task finishes — it's dismissed for good (only ongoing work and sessions that need you stay). Raise the cap to keep more parked at once.") {
            LabeledSlider(title: "Auto-dismiss after (minutes)", value: autoDismissMinutes,
                          range: 1...30, format: "%.0f",
                          help: "How long a parked, idle session waits before it's dismissed forever. Default 5 minutes.")
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
            }
            // Release Full Potential: the master gate + five cost-disclosing sub-toggles for the heavy
            // fleet capabilities (`ai-full-potential-toggle`, addendum §D1).
            fullPotentialSection
            HubSection("Reasoning",
                       footnote: "Let the model think before answering for higher-quality results (a bit slower). Thinking is never shown or pasted — only the final result.") {
                Toggle("Reasoning", isOn: $settings.aiReasoningEnabled)
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
        // A real rehearsal morphs the preview into the actual launcher (showing the AI band) at real size,
        // floating over the page, navigable — never fires.
        .overlay { GrownLauncherOverlay(demo: demo) }
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

// MARK: - §13 Driven launcher demo (the user's REAL launcher — real story, grow on rehearse, live tunables)

/// The §13 holder behind the Launcher / Clipboard / Files / AI previews: it owns the **real** `LauncherModel`
/// (rendered by a real `LauncherView`) and drives it IN SYNC with the demonstrated gesture, exactly the way
/// `HubSwitcherDemo` does for the switcher. Two upgrades over the old §11.5 holder make this the user's
/// *actual* launcher rather than a faithful mini:
///   1. **Grow on rehearse.** A real four-finger swipe (the `HubDemoDriver`'s `onRehearse` seam, gated to
///      ≥2 fingers) crosses the activation distance and MORPHS the launcher from idle preview scale to
///      near-real size under the hand (`playing`), the onboarding `tourPlayActive` morph — then recedes on
///      the lift. The grow is **rehearse-only**; the idle self-playing demo stays at preview scale.
///   2. **Live tunables via `LauncherTourEngine`.** Both the idle ghost demo and a real rehearsal feed one
///      settings-driven odometer (`engine`), so the activation distance, item/band stepping, and dwell-to-arm
///      all reflect the user's tunables — and what is demonstrated is what the real launcher does. The tour
///      **never fires an item**: a lift only recedes + disarms (the `launcherTourEnd` contract).
///
/// Two modes (set at `seed`): `.launcher` navigates items/bands with the engine (the hero); `.bandJourney`
/// traverses the band selection toward the **last** band (the Clipboard / Files / AI band, appended last by
/// `WizardTourBands.compose`) so the band pages' "open → traverse to the band" reads on the real launcher.
@MainActor
final class HubLauncherDemo: ObservableObject {
    enum Mode { case launcher, bandJourney }

    /// The real launcher model the preview renders + the gesture drives.
    let model = LauncherModel()
    /// The GROW flag: `true` while a real rehearsing hand has opened the launcher (it is morphed up to
    /// near-real size and the fingers drive it); `false` at rest and throughout the idle demo (preview scale).
    @Published private(set) var playing = false

    private var mode: Mode = .launcher
    /// The band-journey target — the last band (Clipboard / Files / AI appended last).
    private var lastBandIndex = 0

    /// The settings-driven odometer. Both the idle ghost frames and the real rehearse frames feed it, so the
    /// activation distance + item/band steps reflect the live tunables in both.
    private var engine = LauncherTourEngine(activationThreshold: 0.05, itemStep: 0.04, bandStep: 0.09)
    /// The dwell-to-arm driver (the controller's `manageDwell` semantics, verbatim): charge on a grid item,
    /// disarm elsewhere; on arm the highlight ticks. The tour never *fires* on the lift.
    private let dwellDriver = DwellArmDriver()
    private var dwellDuration: Double = 0.5
    /// True while a real rehearsal is in flight, so the first rehearse frame resets the engine (the idle and
    /// real odometers never bleed) and the idle path stands down.
    private var inRehearse = false

    // MARK: - Seeding + live tunables

    /// Seed the model from a `HubPreviewModels`-built launcher (the user's real bands), set the mode, and load
    /// the live tunables into the engine + dwell. Lands on the band list at the home band, exactly as the real
    /// launcher does.
    func seed(from source: LauncherModel, mode: Mode, dwell: Double,
              activation: CGFloat, itemStep: CGFloat, bandStep: CGFloat) {
        self.mode = mode
        self.lastBandIndex = max(0, source.bandCount - 1)
        self.dwellDuration = dwell
        model.dwell = dwell
        engine.updateDistances(activationThreshold: activation, itemStep: itemStep, bandStep: bandStep)
        model.setBands(source.bands, names: source.bandNames, colors: source.bandColors,
                       icons: source.bandIcons, startBand: 0, column: 0,
                       clipboardBandIndex: source.clipboardBandIndex)
    }

    /// Live: dragging a Tuning slider retargets the engine's distances without disturbing an in-flight tour.
    func updateDistances(activation: CGFloat, itemStep: CGFloat, bandStep: CGFloat) {
        engine.updateDistances(activationThreshold: activation, itemStep: itemStep, bandStep: bandStep)
    }

    /// Live: the dwell-to-arm slider changes how long a rehearsed item takes to arm.
    func setDwell(_ dwell: Double) {
        dwellDuration = dwell
        model.dwell = dwell
    }

    // MARK: - Idle ghost demo (driven by the driver's onOpen / onScrub)

    /// The ghost's open stroke landed (`onOpen`): snap to a clean home and arm the engine for the two-finger
    /// navigate strokes that follow. The idle demo stays at preview scale — no grow.
    func idleOpen() {
        snapToHome()
        engine.reset()
        engine.beginNavigation()
    }

    /// A ghost two-finger navigate frame (`onScrub`): feed the engine (launcher) or step toward the band
    /// target (journey), so the highlight / band advances in sync with the ghost hand — at the configured
    /// step distances. Never grows (idle).
    func idleNavigate(_ centroid: CGPoint) {
        switch mode {
        case .launcher:
            if !engine.isActive { engine.beginNavigation() }   // self-heal if a loop resumed mid-stroke
            for intent in engine.feed(fingerCount: 2, centroid: centroid, onBandList: model.focus == .bands) {
                applyStep(intent)
            }
        case .bandJourney:
            stepBand(toward: lastBandIndex)
            manageDwell()
        }
    }

    // MARK: - Rehearse (the user's REAL fingers — driven by the driver's onRehearse seam)

    /// A real rehearse frame: the user's live centroid + finger count drive the SAME engine, so the launcher
    /// GROWS on the four-finger activation and the two fingers then navigate it — all at the live tunables. The
    /// first frame of a rehearsal resets the engine so it gates fresh (a clean four-finger open → grow).
    func rehearseFrame(_ centroid: CGPoint, fingerCount: Int) {
        if !inRehearse { inRehearse = true; engine.reset() }
        let onBandList = model.focus == .bands
        for intent in engine.feed(fingerCount: fingerCount, centroid: centroid, onBandList: onBandList) {
            switch intent {
            case .activate:
                snapToHome()
                withAnimation(.easeOut(duration: 0.32)) { playing = true }   // the grow morph
            case .end:
                recede()
            case .stepHorizontal, .stepVertical:
                if mode == .launcher { applyStep(intent) }
            }
        }
        // Band journey: while the tour is live, traverse toward the target band each frame (the engine's
        // item-steps don't apply to a vertical band traverse).
        if mode == .bandJourney, engine.isActive {
            stepBand(toward: lastBandIndex)
            manageDwell()
        }
    }

    /// The rehearsing fingers lifted (`onRehearse(nil, 0)`): recede the grow and disarm — NEVER fire the item.
    func rehearseEnd() {
        _ = engine.feed(fingerCount: 0, centroid: CGPoint(x: 0.5, y: 0.5), onBandList: model.focus == .bands)
        inRehearse = false
        recede()
    }

    // MARK: - Applying intents

    /// Apply a navigation step intent to the model + (re)charge the dwell on the new selection.
    private func applyStep(_ intent: LauncherTourEngine.Intent) {
        switch intent {
        case .stepHorizontal(let dir): model.stepHorizontal(dir)
        case .stepVertical(let dir): model.stepVertical(dir)
        case .activate, .end: break
        }
        manageDwell()
    }

    /// Recede the launcher to preview scale and disarm (the tour never fires). Idempotent.
    private func recede() {
        if playing { withAnimation(.easeIn(duration: 0.28)) { playing = false } }
        dwellDriver.cancel()
        model.disarm()
    }

    /// Reset selection to the home band so each demo loop / each fresh open starts clean.
    private func snapToHome() {
        model.setBands(model.bands, names: model.bandNames, colors: model.bandColors,
                       icons: model.bandIcons, startBand: 0, column: 0,
                       clipboardBandIndex: model.clipboardBandIndex)
    }

    /// The controller's `manageDwell`, verbatim semantics: charge the dwell on a grid item, disarm elsewhere.
    /// On arm the highlight ticks — but the tour NEVER fires the item (no `onFire` is wired in a preview).
    private func manageDwell() {
        dwellDriver.cancel()
        if model.focus == .grid, model.selectedItem != nil {
            model.beginArming()
            dwellDriver.charge(after: dwellDuration) { [weak self] in
                guard let self, self.model.arming else { return }
                self.model.setArmed()
            }
        } else {
            model.disarm()
        }
    }

    /// Step the active band one toward `target` (clamped). Band switching lives on the band list; ensure focus
    /// is there first. `stepVertical(-1)` moves to the NEXT band (down the list), `+1` to the previous.
    private func stepBand(toward target: Int) {
        let clamped = min(lastBandIndex, max(0, target))
        guard clamped != model.currentBand else { return }
        guard model.focus == .bands else { model.stepHorizontal(-1); return }   // cross back to the band list
        model.stepVertical(clamped > model.currentBand ? -1 : 1)               // one step toward the target
    }
}

// MARK: - §13 Launcher teaching gestures (real grammar via the connected-stroke seam)

extension HubLauncherDemo {
    /// The launcher's deterministic teaching gesture — the real usage story, mirroring
    /// `HubSwitcherDemo.teachingGesture`. A **four-finger** open swipe whose length tracks the activation
    /// distance, then — CONNECTED, no lift (`gapAfter: 0`, so two fingers lift while two stay down) — a
    /// two-finger DOWN step to switch a band, then a two-finger RIGHT scrub into the grid and across the
    /// items, then a lift and loop. The coordinates match the engine's centroid math so the highlight tracks
    /// the hand.
    static func teachingGesture(openLength: CGFloat) -> GesturePose.DemoGesture {
        let openL = max(0.10, min(0.46, openLength))
        let xL: CGFloat = 0.30, xR: CGFloat = 0.74, homeY: CGFloat = 0.50, downY: CGFloat = 0.66
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
    /// bands"; the open length still tracks the activation distance.
    static func bandJourneyGesture(openLength: CGFloat) -> GesturePose.DemoGesture {
        let openL = max(0.10, min(0.46, openLength))
        let xL: CGFloat = 0.34, topY: CGFloat = 0.34, botY: CGFloat = 0.80
        let open = GesturePose.Stroke(fingers: 4,
                                      from: CGPoint(x: max(GesturePose.lowerBound, xL - openL), y: topY),
                                      to: CGPoint(x: xL, y: topY), gapAfter: 0)
        let traverse = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: topY), to: CGPoint(x: xL, y: botY),
                                          hold: 0.22)
        return GesturePose.DemoGesture(strokes: [open, traverse], liftGap: 0.6)
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
/// (preview scale) — the preview "playing its part." It does NOT grow in place; while a real rehearsal is
/// live (`demo.playing`) it recedes so the user's attention goes to the grown, actual-size launcher floating
/// over the page (`GrownLauncherOverlay`). Takes no hits (the preview disables hit-testing).
private struct LauncherDemoMiniature: View {
    @ObservedObject var demo: HubLauncherDemo
    @ObservedObject var model: LauncherModel

    init(demo: HubLauncherDemo) {
        _demo = ObservedObject(wrappedValue: demo)
        _model = ObservedObject(wrappedValue: demo.model)
    }

    private let scale: CGFloat = 0.46

    var body: some View {
        let n = launcherNaturalSize(model)
        let h = min(n.height, 320)               // a compact preview slot; the grown overlay shows the full height
        LauncherView(model: model, executor: nil, availability: nil)
            .frame(width: n.width, height: h)
            .scaleEffect(scale)
            .frame(width: n.width * scale, height: h * scale)   // the slot is the SCALED size (no overflow)
            .allowsHitTesting(false)
            .opacity(demo.playing ? 0.2 : 1)     // recede behind the grown actual-size launcher
            .animation(.easeInOut(duration: 0.25), value: demo.playing)
    }
}

/// The §14 grow-on-rehearse presentation: while the user is really rehearsing (`demo.playing`), the small
/// preview "morphs" into the user's **ACTUAL launcher** — the real `LauncherView` at its native 1:1 size,
/// floating over the page on a dim backdrop, **navigable by the user's own fingers** (the model is driven by
/// the `onRehearse` seam, so this teaches the real thing). It is scaled down ONLY if the Hub window can't fit
/// the full launcher; otherwise it is exactly actual size. Presentation-only — the trackpad navigates it, not
/// the mouse (`allowsHitTesting(false)`). Applied as a page-level `.overlay` so it floats above the scrolling
/// section content (never clipped by it), and recedes on the lift (`playing == false`).
struct GrownLauncherOverlay: View {
    @ObservedObject var demo: HubLauncherDemo
    @ObservedObject var model: LauncherModel

    init(demo: HubLauncherDemo) {
        _demo = ObservedObject(wrappedValue: demo)
        _model = ObservedObject(wrappedValue: demo.model)
    }

    var body: some View {
        ZStack {
            if demo.playing {
                Rectangle().fill(.black.opacity(0.32)).ignoresSafeArea()
                GeometryReader { geo in
                    let n = launcherNaturalSize(model)
                    // Actual size whenever it fits the available area; scaled down (never clipped) if not.
                    let fit = min(1.0, max(0.2, (geo.size.width - 32) / n.width),
                                       max(0.2, (geo.size.height - 32) / n.height))
                    ZStack {
                        LauncherView(model: model, executor: nil, availability: nil)
                            .frame(width: n.width, height: n.height)
                            .scaleEffect(min(1.0, fit))
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)   // center in the page
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: demo.playing)
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
