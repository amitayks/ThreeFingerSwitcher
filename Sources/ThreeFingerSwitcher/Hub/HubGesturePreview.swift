import SwiftUI
import AppKit
import CoreGraphics

/// The Hub's reusable, self-playing gesture preview — the macOS System-Settings-▸-Trackpad idiom,
/// brought into the configuration Hub. A caller-supplied **static** miniature (a scaled-down real overlay,
/// seeded once) sits above the First Touch wizard's stylized trackpad (`FingerDotsPad`); a ghost hand loops
/// the feature's gesture beneath it without any input, so a page leads with a clip of the very move it
/// teaches.
///
/// ## Autoplay-only (deliberately simple)
/// This is **pure autoplay**: a `TimelineView(.periodic)` advances a continuous `phase` through the shared,
/// MLX-free directed-stroke pose driver (`GesturePose.pose(phase:gesture:)`) and renders the resulting ghost
/// fingertips on the pad. The miniature is whatever the caller draws; the preview itself touches no overlay
/// model — a page that wants its miniature to follow the hand observes the optional `sync` seam (quantized
/// pose frames, emitted only while the clock runs) and steps its own model. Two autoplay states layer over
/// the one driver:
///   - **Attract** (default): loops `gesture` — the feature's currently-bound move (a `switcherDemo`,
///     `launcherOpen`, a `bandJourney`, or a `canvasResolve`, built by the page from `GesturePose`).
///   - **Hover-demo**: when `hoverGesture` is non-nil the loop plays that *candidate* excursion instead, so a
///     user hovering a binding dropdown sees the move before choosing it. Clearing it restores attract.
///
/// The earlier "rehearse" seam (real fingers replacing the ghost + driving the miniature) and the "driven
/// form" (a `HubDemoDriver` stepping the caller's real `SwitcherView`/`LauncherView` model in sync) were
/// **removed**: they kept a perpetual 30 Hz loop + Auto-Layout/Observation churn alive inside the retained,
/// hidden Hub window, pinning the main thread — see `docs/postmortem-idle-cpu-spin.md`. What remains is a
/// self-contained ghost-hand demo over a static miniature, which does nothing when the Hub is not visible.
///
/// ## No idle spin — the visibility gate (HARD requirement)
/// The `TimelineView` is instantiated **only while the Hub is genuinely on screen**. Two independent gates
/// AND together: the coordinator-driven `HubPreviewActivity.isActive` flag (set false the instant the Hub
/// closes/miniaturizes — SwiftUI's `.onAppear`/`.onDisappear` do NOT fire reliably for a hidden but
/// *retained* window, so we cannot rely on them), and the window's own `occlusionState` (observed via
/// `NSWindow.didChangeOcclusionStateNotification`). When either says "not visible" the preview renders a
/// single **static** pose and the periodic clock is never created — so a closed / occluded / ordered-out Hub
/// costs zero: no perpetual tick, no layout invalidation, no CPU spin.
///
/// The pad never takes hits (`allowsHitTesting(false)`) — presentation-only, no new permission, no gesture
/// relocation.
struct HubGesturePreview<Miniature: View>: View {
    /// The gesture the attract loop plays when idle — the feature's currently-bound move. Pages build this
    /// from `GesturePose` (`switcherDemo()`, `launcherOpen()`, `bandJourney(…)`, `canvasResolve(…)`).
    var gesture: GesturePose.DemoGesture
    /// The HOVER-DEMO override: when non-nil the loop plays this candidate excursion instead of `gesture`,
    /// so hovering a binding option previews the move. `nil` ⇒ attract.
    var hoverGesture: GesturePose.DemoGesture?
    /// The optional sync seam: called with each **quantized** pose frame (`GhostSyncPose`), so a page can
    /// step its miniature's model in time with the ghost hand (highlight scrubs, Space slides). Fired ONLY
    /// from inside the visibility-gated `TimelineView` (via `.onChange`, i.e. outside the view update), so
    /// a hidden Hub drives nothing — the same no-idle-spin guarantee as the clock itself
    /// (`docs/postmortem-idle-cpu-spin.md`). The receiver must be idempotent per frame.
    var sync: ((GhostSyncPose) -> Void)?
    /// The static overlay miniature the caller supplies (a scaled `SwitcherView` / `LauncherView`, seeded
    /// once and never driven). Rendered above the pad.
    @ViewBuilder var miniature: () -> Miniature

    /// The Hub-window visibility flag (coordinator-driven), injected by `HubView`. When absent (a bare
    /// SwiftUI `#Preview` with no coordinator) the preview treats itself as active so it still animates.
    @EnvironmentObject private var activity: HubPreviewActivity

    /// The window's real occlusion state — the SECOND, self-sufficient gate. Starts visible and is updated
    /// by `NSWindow.didChangeOcclusionStateNotification`; a hidden/occluded window flips it false.
    @State private var windowVisible = true

    init(
        gesture: GesturePose.DemoGesture,
        hoverGesture: GesturePose.DemoGesture? = nil,
        sync: ((GhostSyncPose) -> Void)? = nil,
        @ViewBuilder miniature: @escaping () -> Miniature
    ) {
        self.gesture = gesture
        self.hoverGesture = hoverGesture
        self.sync = sync
        self.miniature = miniature
    }

    /// The gesture actually playing right now — the candidate while hovering, otherwise the bound one.
    private var activeGesture: GesturePose.DemoGesture { hoverGesture ?? gesture }

    /// True only when BOTH gates agree the Hub is on screen. The clock runs (and the ghost animates) solely
    /// while this holds; otherwise the pad shows a static frame and no `TimelineView` is created.
    private var isVisible: Bool { activity.isActive && windowVisible }

    var body: some View {
        VStack(spacing: 14) {
            miniature()
                .allowsHitTesting(false)

            pad
        }
        // Track the real window's occlusion so the clock stops even if the coordinator flag is missed. The
        // pad is attached to the window when the notification fires, so `NSApp.keyWindow`/its window drives it.
        .background(WindowOcclusionReader(visible: $windowVisible))
    }

    /// The self-playing pad. Only mounts a `TimelineView` while the Hub is visible — the whole point of the
    /// gate. When hidden it draws the resting pose statically (no periodic tick, no invalidation, no spin —
    /// and no `sync` frames, so a driven miniature freezes with it).
    @ViewBuilder
    private var pad: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate * GesturePose.phaseStep * 30
                let frame = GesturePose.pose(phase: phase, gesture: activeGesture)
                dots(frame)
                    // The sync seam: publish the QUANTIZED pose to the page's driver. `.onChange` runs the
                    // action after the view update (never during), and only when the quantized value moves —
                    // a bounded number of firings per stroke, not one per 30 Hz frame. `initial: true`
                    // re-seeds the driver whenever the clock (re)mounts on a visibility flip.
                    .onChange(of: GhostSyncPose(frame: frame, hovering: hoverGesture != nil),
                              initial: true) { _, pose in
                        sync?(pose)
                    }
            }
        } else {
            // Hidden Hub: a single static frame, no clock. (Resting pose of the active gesture.)
            dots(GesturePose.pose(phase: 0, gesture: activeGesture))
        }
    }

    /// Render one pose frame (the ghost fingertips) on the stylized trackpad.
    @ViewBuilder
    private func dots(_ frame: (dots: [CGPoint], fingerCount: Int, centroid: CGPoint,
                               strokeIndex: Int, progress: Double, lifted: Bool)) -> some View {
        HubTrackpadPad(dots: frame.lifted ? [] : frame.dots)
            .allowsHitTesting(false)
    }
}

// MARK: - Sync seam

/// One **quantized** ghost-hand frame — the value a page's miniature driver observes to stay in step with
/// the autoplay. Progress is bucketed into `ticksPerStroke` sub-steps so the preview's `.onChange` fires a
/// bounded number of times per stroke (not per 30 Hz frame); `hovering` distinguishes the hover-demo script
/// from the attract script, so a driver never misreads one script's stroke indices as the other's.
struct GhostSyncPose: Equatable {
    /// Sub-steps per stroke — fine enough that a scrub reads smooth, coarse enough to bound the churn.
    static let ticksPerStroke = 24

    var strokeIndex: Int
    var tick: Int
    var lifted: Bool
    var hovering: Bool

    /// The stroke's progress this frame represents, recovered from the quantized tick (0…1).
    var fraction: Double { Double(tick) / Double(Self.ticksPerStroke) }

    init(strokeIndex: Int, tick: Int, lifted: Bool, hovering: Bool) {
        self.strokeIndex = strokeIndex
        self.tick = tick
        self.lifted = lifted
        self.hovering = hovering
    }

    init(frame: (dots: [CGPoint], fingerCount: Int, centroid: CGPoint,
                 strokeIndex: Int, progress: Double, lifted: Bool),
         hovering: Bool) {
        self.init(strokeIndex: frame.strokeIndex,
                  tick: min(Self.ticksPerStroke, max(0, Int(frame.progress * Double(Self.ticksPerStroke)))),
                  lifted: frame.lifted,
                  hovering: hovering)
    }
}

// MARK: - The stylized trackpad

/// The Hub previews' trackpad — the wizard's `FingerDotsPad` idiom restyled for the Hub's darker, denser
/// pages: a soft top-lit slab with a hairline gradient rim, and crisper fingertip dots so the ghost hand
/// reads clearly against the page (the former ambient `PulseHalo` blob is gone — the motion itself is the
/// liveness). Purely presentational; the wizard keeps its own pad untouched.
private struct HubTrackpadPad: View {
    let dots: [CGPoint]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let slab = RoundedRectangle(cornerRadius: 15, style: .continuous)
                slab.fill(
                    LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom))
                slab.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.30))
                            .frame(width: 24, height: 24)
                            .blur(radius: 5)
                        Circle()
                            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.95),
                                                          Color.accentColor.opacity(0.55)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 14, height: 14)
                        Circle()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                            .frame(width: 14, height: 14)
                    }
                    .position(x: dot.x * geo.size.width,
                              y: (1 - dot.y) * geo.size.height)
                    .animation(.easeOut(duration: 0.06), value: dots)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.75), value: dots.count)
        }
        .frame(width: 188, height: 118)
    }
}

// MARK: - Visibility gate

/// The single, coordinator-driven "is the Hub actually on screen?" flag, injected into the Hub's SwiftUI
/// environment. `AppCoordinator` sets `isActive = false` the instant the Hub window closes / miniaturizes and
/// `true` when it returns (reopen / deminiaturize) — the authoritative signal SwiftUI's own
/// `.onAppear`/`.onDisappear` can't provide for a hidden-but-retained window. Every `HubGesturePreview`
/// observes it and refuses to run its `TimelineView` while it is false, so the closed Hub never spins the
/// main thread (see `docs/postmortem-idle-cpu-spin.md`).
@MainActor
final class HubPreviewActivity: ObservableObject {
    /// True while the Hub is presented on screen. Defaults true so a first open animates before any signal.
    @Published var isActive: Bool = true
    init() {}
}

/// A zero-size AppKit probe that reports its host window's `occlusionState` into a SwiftUI binding — the
/// preview's SECOND, self-sufficient visibility gate. It observes `NSWindow.didChangeOcclusionStateNotification`
/// for the window it lands in, so a Hub that is ordered-out / behind another window flips `visible` false and
/// the preview's clock stops even without the coordinator flag. Cheap: one observer, no timers.
private struct WindowOcclusionReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onOcclusionChange = { isVisible in
            // Publish only real transitions (avoid redundant writes that would thrash the view).
            if visible != isVisible { visible = isVisible }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// The probe: latches onto its window when moved into one, tracks occlusion, and tears the observer down
    /// on removal / window change so nothing leaks past the (retained) Hub window's lifetime.
    private final class ProbeView: NSView {
        var onOcclusionChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard let window else { onOcclusionChange?(false); return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.onOcclusionChange?(window.occlusionState.contains(.visible))
            }
            // Seed the current state immediately (the notification only fires on CHANGE).
            onOcclusionChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

#if DEBUG
#Preview("HubGesturePreview — attract") {
    HubGesturePreview(gesture: GesturePose.switcherDemo()) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.thinMaterial)
            .frame(height: 120)
            .overlay(Text("miniature").foregroundStyle(.secondary))
    }
    .environmentObject(HubPreviewActivity())
    .frame(width: 320)
    .padding()
}
#endif
