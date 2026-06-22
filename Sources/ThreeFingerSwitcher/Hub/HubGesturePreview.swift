import SwiftUI
import CoreGraphics

/// The Hub's reusable, self-playing gesture preview — the macOS System-Settings-▸-Trackpad idiom,
/// brought into the configuration Hub. A caller-supplied live overlay **miniature** sits on top of the
/// First Touch wizard's stylized trackpad (`FingerDotsPad`); a ghost hand loops the feature's gesture
/// beneath it without any input, so a page leads with a clip of the very move it teaches.
///
/// The whole thing self-loops via a `TimelineView(.periodic)` driving a continuous `phase` through the
/// shared, MLX-free `GesturePose.pose(phase:fingers:axis:)` driver (the same engine behind the wizard's
/// attract loop). Three states layer over that one driver:
///   - **Attract** (default): loops `attractAxis` — the feature's *currently-bound* gesture. For band
///     pages this is a `.scripted` journey (four-finger open → traverse to the band → in-surface gesture),
///     which `HubGesturePreview.bandJourney(...)` builds.
///   - **Hover-demo**: when `demoAxis` is non-nil the loop plays that *candidate* excursion instead, so a
///     user hovering a binding dropdown sees the move before choosing it. Clearing it restores attract.
///   - **Rehearse** (the seam): when `liveDots` is non-nil those provided contacts are rendered — bright
///     and active — in place of the ghost; a later agent feeds the real ≥2-finger touch here. The pose
///     loop keeps running underneath but the pad shows the live hand.
///
/// `PulseHalo` / `BreathingGlowBackdrop` give it the wizard's "alive" feel. The pad never takes hits
/// (`allowsHitTesting(false)`), so it is presentation-only — no new permission, no gesture relocation.
///
/// ## Two ways to drive it (both supported, additive)
///   1. **Axis form** (the original): `HubGesturePreview(fingers:attractAxis:demoAxis:liveDots:) { … }` — a
///      self-looping `TimelineView` plays an `Axis` ping-pong / scripted journey. The miniature is whatever
///      the caller draws; the preview does NOT touch a model. Used by the not-yet-migrated abstract pages.
///   2. **Driven form** (§11.4, the realism path): `HubGesturePreview(driver:onOpen:onScrub:onDismiss:) { … }`
///      — a `HubDemoDriver` plays a directed-stroke `DemoGesture` and DRIVES the caller's real overlay model
///      through the injected closures, so the `SwitcherView`/`LauncherView` miniature reacts in sync with the
///      ghost hand (the switcher highlight steps, the launcher launches in / dismisses). This is the form the
///      §11.5 page agents wire. The driver also carries the hover-demo + rehearse seams (`hoverGesture`,
///      `liveDots`).
struct HubGesturePreview<Miniature: View>: View {
    /// How many fingertips the ghost hand shows (2 / 3 / 4). Matches the gesture's real finger count.
    /// (Axis form only — the driven form takes the finger count from the playing stroke.)
    var fingers: Int
    /// The gesture the attract loop plays when idle — the feature's currently-bound move. Band pages
    /// pass a `.scripted` journey from `HubGesturePreview.bandJourney(...)`. (Axis form only.)
    var attractAxis: GesturePose.Axis
    /// The HOVER-DEMO override: when non-nil the loop plays this candidate excursion instead of
    /// `attractAxis`, so hovering a binding option previews the move. `nil` ⇒ attract. (Axis form only.)
    var demoAxis: GesturePose.Axis?
    /// The REHEARSE seam: when non-nil these normalized dots are rendered (brightened / active) in place
    /// of the ghost hand — a later agent feeds the user's real contacts here. `nil` ⇒ ghost loop.
    /// (Axis form only — the driven form rehearses through `driver.liveDots`.)
    var liveDots: [CGPoint]?
    /// The §11.4 driven form's clock: when non-nil it plays a directed-stroke `DemoGesture` and drives the
    /// caller's model through its injected closures, and the pad renders `driver.liveDots ?? driver.dots`
    /// at `driver.fingerCount` fingers. `nil` ⇒ the axis form's self-looping `TimelineView` runs instead.
    @ObservedObject private var driverBox: DriverBox
    /// The live overlay miniature the caller supplies (a scaled `SwitcherView` / `LauncherView` /
    /// `AICommandCanvasView`, or a lighter abstract scene). Rendered above the pad.
    @ViewBuilder var miniature: () -> Miniature

    /// A nil-safe `@ObservedObject` wrapper: SwiftUI can't observe an optional `ObservableObject`, so the
    /// axis form holds an inert empty box (no driver) and the driven form holds the real one.
    private final class DriverBox: ObservableObject {
        let driver: HubDemoDriver?
        init(_ driver: HubDemoDriver?) { self.driver = driver }
    }

    /// Axis form — the original self-looping preview (unchanged behavior). Kept so the not-yet-migrated
    /// abstract pages and any existing callers keep compiling and rendering exactly as before.
    init(
        fingers: Int = 3,
        attractAxis: GesturePose.Axis = .horizontal,
        demoAxis: GesturePose.Axis? = nil,
        liveDots: [CGPoint]? = nil,
        @ViewBuilder miniature: @escaping () -> Miniature
    ) {
        self.fingers = fingers
        self.attractAxis = attractAxis
        self.demoAxis = demoAxis
        self.liveDots = liveDots
        self.driverBox = DriverBox(nil)
        self.miniature = miniature
    }

    /// §11.4 driven form — render the **real** overlay `miniature` and drive its model from the `driver`'s
    /// directed-stroke gesture, in sync. The `driver` is built by the page (`HubDemoDriver(gesture:…)`) with
    /// the model-driving closures already injected; this view just renders its `dots`/`fingerCount` on the
    /// pad and starts/stops its loop on appear/disappear. Hover-demo (`driver.hoverGesture`) and rehearse
    /// (`driver.liveDots`) are set on the driver by the page.
    init(
        driver: HubDemoDriver,
        @ViewBuilder miniature: @escaping () -> Miniature
    ) {
        self.fingers = 3
        self.attractAxis = .horizontal
        self.demoAxis = nil
        self.liveDots = nil
        self.driverBox = DriverBox(driver)
        self.miniature = miniature
    }

    /// The axis currently driving the ghost hand — the candidate while hovering, otherwise the bound one.
    private var activeAxis: GesturePose.Axis { demoAxis ?? attractAxis }

    /// True while the user's real fingers (the rehearse seam) are driving the pad. In the driven form this
    /// reads the driver's rehearse seam; in the axis form it reads the local `liveDots`.
    private var isRehearsing: Bool { driverBox.driver?.isRehearsing ?? (liveDots != nil) }

    var body: some View {
        VStack(spacing: 14) {
            miniature()
                .allowsHitTesting(false)
                .background(
                    BreathingGlowBackdrop()
                        .opacity(isRehearsing ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: isRehearsing)
                )

            if let driver = driverBox.driver {
                drivenPad(driver)
            } else {
                axisPad
            }
        }
    }

    /// §11.4 driven pad: render the driver's published ghost (or rehearse) dots + finger count; the driver's
    /// own 30 Hz loop already advanced them and drove the model. Start/stop the loop with the view's lifetime.
    @ViewBuilder
    private func drivenPad(_ driver: HubDemoDriver) -> some View {
        let dots = driver.liveDots ?? driver.dots
        ZStack {
            PulseHalo(size: 150, intensity: isRehearsing ? 1.2 : 0.7)
                .opacity(0.8)
            FingerDotsPad(dots: dots, live: isRehearsing)
        }
        .allowsHitTesting(false)
        // Bridge the REHEARSE seam into the driver. `RehearsablePreview` (wired by `HubFeatureHeader`
        // with the page's token + `HubRehearseController`) sets the struct's `liveDots` to the user's
        // real contacts while this preview is the active target — but the driven pad renders
        // `driver.liveDots`, so forward it. Without this the real fingers never replace the ghost in the
        // driven form (the migrated pages), and §2.3/§2.4 rehearse would be silently dead.
        .onAppear { driver.start(); driver.liveDots = liveDots }
        .onDisappear { driver.stop() }
        .onChange(of: liveDots) { _, new in driver.liveDots = new }
    }

    /// The original self-playing pad: a `TimelineView` advances `phase`, the pose driver turns it into a
    /// ghost hand. When rehearsing, the provided live dots replace the ghost instead.
    @ViewBuilder
    private var axisPad: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate * GesturePose.phaseStep * 30
            let ghost = GesturePose.pose(phase: phase, fingers: fingers, axis: activeAxis).dots
            ZStack {
                PulseHalo(size: 150, intensity: isRehearsing ? 1.2 : 0.7)
                    .opacity(0.8)
                FingerDotsPad(dots: liveDots ?? ghost, live: isRehearsing)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - §2.2 Scripted-journey helper

extension HubGesturePreview {
    /// Build the band pages' `.scripted` demo path as keyframes: a four-finger launcher **open** at one
    /// side of the pad, a **traverse** across the bands to the target, a **land** on it, and the band's
    /// **in-surface** excursion. This is the full open → band → in-surface journey the band-feature
    /// previews (Clipboard / Files / AI) play instead of a single isolated excursion. Pure — it only
    /// composes normalized `GesturePose.Keyframe`s, so it is `swift test`-able and side-effect-free.
    ///
    /// - Parameters:
    ///   - bandFraction: where the target band sits along the traverse, 0 (first) … 1 (last) — the
    ///     centroid lands proportionally across the pad. Clamped to the pad's safe `[lowerBound, upperBound]`.
    ///   - inSurface: the in-surface gesture played after landing — `.lift` rests on the band (Files /
    ///     Clipboard land-and-open), `.swipeDown` / `.swipeUp` / `.swipeHorizontal` trace the canvas resolve.
    static func bandJourney(
        bandFraction: CGFloat,
        inSurface: BandInSurfaceGesture = .lift
    ) -> GesturePose.Axis {
        let lo = GesturePose.lowerBound
        let hi = GesturePose.upperBound
        let mid: CGFloat = 0.42                       // the attract loop's resting Y
        let land = max(lo, min(hi, lo + (hi - lo) * bandFraction))

        var keys: [GesturePose.Keyframe] = [
            .init(x: lo, y: mid),                     // open: four fingers enter from the left
            .init(x: (lo + land) / 2, y: mid),        // traverse: step across the bands
            .init(x: land, y: mid)                    // land on the target band
        ]
        keys.append(contentsOf: inSurface.keyframes(at: land, mid: mid))
        return .scripted(keys)
    }

    /// The in-surface gesture a band-journey ends on, expressed as a short keyframe tail from the landing
    /// point. Each returns to the landing point so the whole journey loops cleanly.
    enum BandInSurfaceGesture {
        /// Rest on the band (a dwell-and-lift open — Files / Clipboard).
        case lift
        /// Trace a downward resolve (the canvas commit default).
        case swipeDown
        /// Trace an upward resolve.
        case swipeUp
        /// Trace a horizontal resolve (the canvas dismiss default).
        case swipeHorizontal

        func keyframes(at land: CGFloat, mid: CGFloat) -> [GesturePose.Keyframe] {
            let lo = GesturePose.lowerBound
            let hi = GesturePose.upperBound
            switch self {
            case .lift:
                // A small settling dwell on the band, then back — reads as land-and-open.
                return [.init(x: land, y: mid)]
            case .swipeDown:
                return [.init(x: land, y: lo), .init(x: land, y: mid)]
            case .swipeUp:
                return [.init(x: land, y: hi), .init(x: land, y: mid)]
            case .swipeHorizontal:
                let to = max(lo, min(hi, land - 0.25))
                return [.init(x: to, y: mid), .init(x: land, y: mid)]
            }
        }
    }
}

#if DEBUG
#Preview("HubGesturePreview — attract (axis form)") {
    HubGesturePreview(fingers: 3, attractAxis: .horizontal) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.thinMaterial)
            .frame(height: 120)
            .overlay(Text("miniature").foregroundStyle(.secondary))
    }
    .frame(width: 320)
    .padding()
}

/// §11.4 driven form — the shape the §11.5 page agents wire: build a real overlay model (here a
/// `SwitcherModel`), a `HubDemoDriver` whose `onScrub` maps the centroid into the model (the switcher's
/// `centroid.x → setColumn`, exactly like `FirstTouchWizardModel.attractTick`), then render the real
/// `SwitcherView` as the miniature. Replace the model build with `HubPreviewModels.makeSwitcherModel(...)`
/// in the live page (this preview fabricates a tiny one so it stands alone).
private struct DrivenSwitcherDemoPreview: View {
    @StateObject private var model = SwitcherModel()
    @StateObject private var driver: HubDemoDriver
    @State private var seeded = false

    init() {
        let m = SwitcherModel()
        _model = StateObject(wrappedValue: m)
        // `onScrub` maps the navigate stroke's centroid.x to the highlighted window — the page's job.
        _driver = StateObject(wrappedValue: HubDemoDriver(
            gesture: GesturePose.switcherDemo(),
            onScrub: { [weak m] centroid in
                guard let m, m.windows.count > 1 else { return }
                let col = min(m.windows.count - 1, max(0, Int(centroid.x * CGFloat(m.windows.count))))
                if col != m.selectedIndex { m.setColumn(col) }
            }))
    }

    var body: some View {
        HubGesturePreview(driver: driver) {
            SwitcherView(model: model)
                .scaleEffect(0.5)
                .frame(height: 120)
        }
        .frame(width: 360)
        .padding()
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let ids: [CGWindowID] = [9_001, 9_002, 9_003, 9_004]
            let windows = ids.enumerated().map { i, id in
                WindowInfo(id: id, pid: 0, appName: "App \(i + 1)", title: "App \(i + 1)",
                           appIcon: nil, frame: .zero, axElement: nil,
                           isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
            }
            model.setCanvas(CGSize(width: 820, height: 108))
            model.setRows([windows], labels: ["1"], startRow: 0, column: 2)
        }
    }
}

#Preview("HubGesturePreview — driven (switcher)") {
    DrivenSwitcherDemoPreview()
}
#endif
