import SwiftUI
import CoreGraphics

/// The §12 holder behind the Window-Switcher preview: it owns the **real** `SwitcherModel` (rendered by a
/// real `SwitcherView`), seeded once with the user's real windows so the preview shows the actual switcher.
/// The model follows the ghost hand through the preview's **sync seam** (`drive(_:script:)`): the open swipe
/// pops the panel in at the activation beat, the up/down strokes slide the Space reel, the sideways scrub
/// steps the highlight card by card, and the lift commits — the panel pops out until the next loop. This is
/// NOT the old free-running `HubDemoDriver` (removed for the idle main-thread spin,
/// `docs/postmortem-idle-cpu-spin.md`): there is no clock here — frames arrive only from the preview's
/// visibility-gated `TimelineView`, so a hidden Hub drives nothing and every mutation is state-guarded
/// (idempotent per frame). The window-size control stays live, re-solving the grid as the slider drags.
@MainActor
final class HubSwitcherDemo: ObservableObject {
    /// The real model the preview renders (seeded once; stepped only by the sync drive).
    let model = SwitcherModel()

    /// Whether the mini switcher is "open" in the teaching story: `true` while the ghost hand navigates,
    /// `false` between loops (after the lift-to-select, until the next open swipe crosses the activation
    /// beat). The miniature pops in/out on this, mirroring the real overlay's lifecycle. Defaults `true` so
    /// an undriven preview (hidden Hub's static frame, bare `#Preview`) still shows the switcher.
    @Published private(set) var overlayShown = true

    // MARK: - Seeding

    /// Seed from a `HubPreviewModels`-built switcher (real windows + thumbnails, or the fabricated
    /// icon-only fallback), sized to `canvas` at the user's window-scale `maxScale`. Lands on the home
    /// (bottom) row's first window. Synchronous frames (icons / already-cached thumbnails) carry over;
    /// the page re-runs `seedThumbnails` against THIS model so live-capture retries land here.
    func seed(from source: SwitcherModel, canvas: CGSize, maxScale: CGFloat) {
        model.setCanvas(canvas)
        model.setMaxScale(maxScale)
        model.setRows(source.rows, labels: source.rowLabels, startRow: 0, column: 0)
        for (id, image) in source.thumbnails { model.setThumbnail(image, for: id) }
    }

    /// Live window-size: re-solve the grid at the new uniform-scale cap, animated so the cards grow/shrink
    /// smoothly as the user drags the "Window size" slider — the slider and the preview move together.
    func setMaxScale(_ scale: CGFloat) {
        withAnimation(.easeInOut(duration: 0.25)) { model.setMaxScale(scale) }
    }

    /// The switcher's rendered natural size (grid content + chrome), so the preview can compute a scale that
    /// fits the idle miniature to the available width. Mirrors `SwitcherView.container` exactly: the reel at
    /// content height, a 10pt gap swallowed by the title bar's `titleAreaHeight - 10` frame, and the
    /// container padding (+ the row-indicator gutter when several Spaces show).
    var renderedNaturalSize: CGSize {
        let content = model.maxContentSize
        let gutter = model.rowCount > 1 ? SwitcherLayout.rowIndicatorGutter : 0
        return CGSize(
            width: content.width + 2 * SwitcherLayout.gridContainerPadding + gutter,
            height: content.height + 2 * SwitcherLayout.gridContainerPadding + SwitcherLayout.titleAreaHeight)
    }

    // MARK: - Sync drive (the miniature follows the ghost hand)

    /// Which autoplay script the incoming sync frames describe — the stroke-index → model-move mapping.
    /// `.teaching` is the attract loop (open → up → down → scrub); the hover scripts match the
    /// `windowsHoverGesture()` / `spacesHoverGesture()` stroke lists.
    enum SyncScript: Equatable {
        case teaching
        case windowsHover
        case spacesHover
    }

    /// The Space-slide pace — the real switcher's `OverlayController.slideDuration` feel, so the preview's
    /// reel moves exactly like the overlay it teaches.
    private static let rowSlide = Animation.easeInOut(duration: 0.34)

    /// The scrub stroke's last emitted highlight step, so each crossed boundary emits exactly ONE
    /// `moveHorizontal` — the odometer idiom in miniature.
    private var scrubStep = 0
    private var lastScript: SyncScript = .teaching

    /// Step the model in time with one quantized ghost-hand frame. Called from the preview's `sync` seam —
    /// i.e. only while the visibility-gated clock runs (the postmortem guardrail) — and idempotent per
    /// frame: every mutation is guarded on current model state, so repeated, skipped, or resumed frames
    /// land safely anywhere in the loop.
    func drive(_ pose: GhostSyncPose, script: SyncScript) {
        if script != lastScript {
            lastScript = script
            scrubStep = 0
        }
        if pose.lifted {
            // The lift after the final stroke: the selection commits and the switcher goes away.
            setShown(false)
            return
        }
        switch (script, pose.strokeIndex) {
        case (_, 0):
            openStroke(fraction: pose.fraction)
        case (.teaching, 1), (.spacesHover, 1):
            if pose.fraction >= 0.5, model.rowCount > 1, model.currentRow == 0 {
                withAnimation(Self.rowSlide) { model.setRowEntering(1, upward: true) }
            }
        case (.teaching, 2), (.spacesHover, 2):
            if pose.fraction >= 0.5, model.currentRow != 0 {
                withAnimation(Self.rowSlide) { model.setRowEntering(0, upward: false) }
            }
        case (.teaching, 3), (.windowsHover, 1):
            stepScrub(fraction: pose.fraction)
        default:
            break
        }
    }

    /// The open swipe: while the stroke is still short of the activation beat the panel stays hidden — and,
    /// freshly hidden from the previous loop's commit, quietly resets to the home row's first window (an
    /// instant, off-screen snap) — then crossing the beat pops it in, the moment the real switcher appears.
    private func openStroke(fraction: Double) {
        if fraction < 0.45 {
            if !overlayShown, model.currentRow != 0 || model.selectedIndex != 0 || scrubStep != 0 {
                scrubStep = 0
                model.setRowAndColumn(0, column: 0)
            }
        } else {
            setShown(true)
        }
    }

    /// The sideways scrub: step the highlight card by card across the current visual row as the stroke
    /// advances — one step per crossed boundary, clamped at the row's end exactly like the real odometer.
    private func stepScrub(fraction: Double) {
        let gridRow = model.currentGridRow
        guard model.gridLayout.rows.indices.contains(gridRow) else { return }
        let rowLength = model.gridLayout.rows[gridRow].count
        guard rowLength > 1 else { return }
        let steps = min(rowLength - 1, 4)
        let desired = min(steps, Int(fraction * Double(steps + 1)))
        while scrubStep < desired {
            scrubStep += 1
            model.moveHorizontal(1, wrap: false)
        }
    }

    private func setShown(_ shown: Bool) {
        guard overlayShown != shown else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { overlayShown = shown }
    }
}

// MARK: - Teaching + hover gesture builders (autoplay scripts for the ghost hand)

extension HubSwitcherDemo {
    /// The resting (home-row) band: the 2-finger nav begins here and the sideways scrub stays here.
    /// Pose coordinates are y-UP (trackpad bottom-left origin — the pad renderer flips), so the home
    /// band sits BELOW `upY`.
    static let homeY: CGFloat = 0.42
    /// The "second row" band the up-stroke reaches (higher on the pad = larger y).
    static let upY: CGFloat = 0.74
    /// The sideways scrub travels x across this range.
    static let scrubLeft: CGFloat = 0.28
    static let scrubRight: CGFloat = 0.80

    /// The deterministic teaching gesture the ghost hand autoplays. Three-finger **open** (a short horizontal
    /// swipe whose length scales with the activation threshold so it reads as "just enough to trigger"), then
    /// — CONNECTED, no lift (`gapAfter: 0`, so two fingers lift while two stay down) — ONE finger lifts and the
    /// two resting fingers go UP to the second row, back DOWN to the first, then SIDEWAYS across the windows,
    /// then a lift and loop.
    static func teachingGesture(openLength: CGFloat) -> GesturePose.DemoGesture {
        let openL = max(0.10, min(0.46, openLength))
        let xL = scrubLeft, xR = scrubRight, yB = homeY, yT = upY
        // Three-finger open: a leftward swipe ending at the nav column (`xL`), so the 2-finger nav + scrub
        // start at the left with room to travel right. `gapAfter: 0` keeps the hand DOWN — the next stroke
        // drops to two fingers, which reads as "lift one finger and keep going".
        let open  = GesturePose.Stroke(fingers: 3,
                                       from: CGPoint(x: min(GesturePose.upperBound, xL + openL), y: yB),
                                       to: CGPoint(x: xL, y: yB), gapAfter: 0)
        let up    = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: yB), to: CGPoint(x: xL, y: yT),
                                       hold: 0.12, gapAfter: 0)
        let down  = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: yT), to: CGPoint(x: xL, y: yB),
                                       hold: 0.05, gapAfter: 0)
        let scrub = GesturePose.Stroke(fingers: 2, from: CGPoint(x: xL, y: yB), to: CGPoint(x: xR, y: yB),
                                       hold: 0.18)   // default liftGap ⇒ lift + loop
        return GesturePose.DemoGesture(strokes: [open, up, down, scrub], liftGap: 0.6)
    }

    /// Hover demo for the WINDOWS-axis control: open, then a sideways scrub (no row change) — the move the
    /// windows direction binding governs.
    static func windowsHoverGesture() -> GesturePose.DemoGesture {
        let open  = GesturePose.Stroke(fingers: 3, from: CGPoint(x: scrubLeft + 0.16, y: homeY),
                                       to: CGPoint(x: scrubLeft, y: homeY), gapAfter: 0)
        let scrub = GesturePose.Stroke(fingers: 2, from: CGPoint(x: scrubLeft, y: homeY),
                                       to: CGPoint(x: scrubRight, y: homeY), hold: 0.15)
        return GesturePose.DemoGesture(strokes: [open, scrub], liftGap: 0.6)
    }

    /// Hover demo for the SPACES-axis control: open, then a vertical scrub up to the second row and back —
    /// the move the Spaces direction binding governs.
    static func spacesHoverGesture() -> GesturePose.DemoGesture {
        let open  = GesturePose.Stroke(fingers: 3, from: CGPoint(x: scrubLeft + 0.16, y: homeY),
                                       to: CGPoint(x: scrubLeft, y: homeY), gapAfter: 0)
        let up    = GesturePose.Stroke(fingers: 2, from: CGPoint(x: scrubLeft, y: homeY),
                                       to: CGPoint(x: scrubLeft, y: upY), hold: 0.15, gapAfter: 0)
        let down  = GesturePose.Stroke(fingers: 2, from: CGPoint(x: scrubLeft, y: upY),
                                       to: CGPoint(x: scrubLeft, y: homeY), hold: 0.05)
        return GesturePose.DemoGesture(strokes: [open, up, down], liftGap: 0.6)
    }

    /// Map the configurable activation threshold (`0.01…0.15`, the real trigger distance) to the demo's
    /// open-swipe length, so dragging "Activation threshold" visibly lengthens/shortens the ghost hand's
    /// opening swipe. Mapped into a *visible* pad range (a feather-light threshold is still a clear swipe).
    static func openLength(forActivation threshold: Double) -> CGFloat {
        let clamped = min(0.15, max(0.01, threshold))
        let f = (clamped - 0.01) / (0.15 - 0.01)
        return CGFloat(0.16 + f * (0.44 - 0.16))
    }
}

// MARK: - The action "map" (a legend of the teaching story)

/// A compact legend beneath the Switcher preview that spells out the gesture as a numbered story, so the
/// looping ghost hand has a written counterpart: open with three fingers → lift one → up/down for Spaces →
/// left/right for windows → lift to select.
struct SwitcherActionMap: View {
    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    // `static`: a stored instance property was rebuilt with the view struct on every parent
    // re-render, minting five fresh UUIDs each time — ForEach then tore down and rebuilt all rows.
    private static let steps: [Step] = [
        Step(symbol: "hand.raised.fill", title: "Slide three fingers", detail: "Swipe sideways to open the switcher"),
        Step(symbol: "hand.point.up.left.fill", title: "Lift one finger", detail: "Keep two fingers resting to navigate"),
        Step(symbol: "arrow.up.arrow.down", title: "Up / down", detail: "Move between Spaces (rows)"),
        Step(symbol: "arrow.left.arrow.right", title: "Left / right", detail: "Move between windows in the row"),
        Step(symbol: "checkmark.circle.fill", title: "Lift to select", detail: "Raise the highlighted window")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.steps.enumerated()), id: \.element.id) { index, step in
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

// MARK: - The teaching miniature

/// The Switcher preview miniature: the real `SwitcherView` scaled to fit the available slot, showing the
/// seeded windows. The sync drive steps the model (highlight scrub, Space slides) and flips `overlayShown`
/// with the loop's open/commit beats, so the clip reads as the real switcher appearing, being navigated,
/// and committing. Observes the **model** directly — the holder publishes almost nothing itself, and the
/// fit scale must recompute the moment the seeded grid lands (observing only the holder left the view at
/// its pre-seed size: the mini switcher rendered unscaled and overflowed the page).
struct SwitcherDemoMiniature: View {
    @ObservedObject var demo: HubSwitcherDemo
    @ObservedObject private var model: SwitcherModel

    init(demo: HubSwitcherDemo) {
        self.demo = demo
        _model = ObservedObject(wrappedValue: demo.model)
    }

    private let reservedHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let natural = demo.renderedNaturalSize
            let fit = min(1.0,
                          min((geo.size.width - 16) / max(natural.width, 1),
                              (geo.size.height - 12) / max(natural.height, 1)))
            SwitcherView(model: model)
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(fit * (demo.overlayShown ? 1.0 : 0.92), anchor: .center)
                .opacity(demo.overlayShown ? 1 : 0)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: reservedHeight)
    }
}
