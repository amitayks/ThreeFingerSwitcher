import SwiftUI
import CoreGraphics

/// The §12 holder behind the Window-Switcher preview: it owns the **real** `SwitcherModel` (rendered by a
/// real `SwitcherView`), seeded once with the user's real windows so the preview shows the actual switcher.
/// The model is **static** — the ghost-hand autoplay plays the teaching gesture *over* it, but nothing drives
/// the model in sync (the old `HubDemoDriver`-driven form was removed to stop the idle main-thread spin; see
/// `docs/postmortem-idle-cpu-spin.md`). The only live behavior kept is the window-size control, which
/// re-solves the grid so the static preview cards grow/shrink as the user drags the slider.
@MainActor
final class HubSwitcherDemo: ObservableObject {
    /// The real model the preview renders (seeded once, not driven).
    let model = SwitcherModel()

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
    /// fits the idle miniature to the available width.
    var renderedNaturalSize: CGSize {
        let content = model.maxContentSize
        let gutter = model.rowCount > 1 ? SwitcherLayout.rowIndicatorGutter : 0
        return CGSize(
            width: content.width + 2 * SwitcherLayout.gridContainerPadding + gutter,
            height: content.height + 2 * SwitcherLayout.gridContainerPadding + 10 + SwitcherLayout.titleAreaHeight)
    }
}

// MARK: - Teaching + hover gesture builders (autoplay scripts for the ghost hand)

extension HubSwitcherDemo {
    /// The resting (home-row) band: the 2-finger nav begins here and the sideways scrub stays here.
    static let homeY: CGFloat = 0.58
    /// The "second row" band the up-stroke reaches.
    static let upY: CGFloat = 0.26
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

    private let steps: [Step] = [
        Step(symbol: "hand.raised.fill", title: "Slide three fingers", detail: "Swipe sideways to open the switcher"),
        Step(symbol: "hand.point.up.left.fill", title: "Lift one finger", detail: "Keep two fingers resting to navigate"),
        Step(symbol: "arrow.up.arrow.down", title: "Up / down", detail: "Move between Spaces (rows)"),
        Step(symbol: "arrow.left.arrow.right", title: "Left / right", detail: "Move between windows in the row"),
        Step(symbol: "checkmark.circle.fill", title: "Lift to select", detail: "Raise the highlighted window")
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

// MARK: - The idle teaching miniature (static)

/// The Switcher preview miniature: the real `SwitcherView` scaled to fit the available width, showing the
/// seeded windows. It is **static** — the ghost-hand autoplay plays over it; the model is not driven.
struct SwitcherDemoMiniature: View {
    @ObservedObject var demo: HubSwitcherDemo

    private let reservedHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let natural = demo.renderedNaturalSize
            let fit = min(1.0,
                          min((geo.size.width - 16) / max(natural.width, 1),
                              (geo.size.height - 12) / max(natural.height, 1)))
            SwitcherView(model: demo.model)
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(fit, anchor: .center)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: reservedHeight)
    }
}
