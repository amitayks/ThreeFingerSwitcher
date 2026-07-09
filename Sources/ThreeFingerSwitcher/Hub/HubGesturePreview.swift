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
/// fingertips on the pad. The miniature is whatever the caller draws and is **never manipulated** — the
/// preview touches no overlay model. Two autoplay states layer over the one driver:
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
        @ViewBuilder miniature: @escaping () -> Miniature
    ) {
        self.gesture = gesture
        self.hoverGesture = hoverGesture
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
    /// gate. When hidden it draws the resting pose statically (no periodic tick, no invalidation, no spin).
    @ViewBuilder
    private var pad: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate * GesturePose.phaseStep * 30
                dots(GesturePose.pose(phase: phase, gesture: activeGesture))
            }
        } else {
            // Hidden Hub: a single static frame, no clock. (Resting pose of the active gesture.)
            dots(GesturePose.pose(phase: 0, gesture: activeGesture))
        }
    }

    /// Render one pose frame (the ghost fingertips) on the pad, under a soft pulse halo.
    @ViewBuilder
    private func dots(_ frame: (dots: [CGPoint], fingerCount: Int, centroid: CGPoint,
                               strokeIndex: Int, progress: Double, lifted: Bool)) -> some View {
        ZStack {
            // `PulseHalo` carries its OWN internal `TimelineView`, so it must be gated on visibility too —
            // otherwise it keeps ticking in the hidden/retained Hub window and spins the main thread even
            // though the pose clock (`pad`) is already gated (docs/postmortem-idle-cpu-spin.md).
            if isVisible {
                PulseHalo(size: 150, intensity: 0.7)
                    .opacity(0.8)
            }
            FingerDotsPad(dots: frame.lifted ? [] : frame.dots, live: false)
        }
        .allowsHitTesting(false)
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
