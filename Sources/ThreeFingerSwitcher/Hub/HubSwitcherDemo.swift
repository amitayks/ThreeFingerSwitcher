import SwiftUI
import CoreGraphics

/// The §12 holder behind the Window-Switcher preview: it owns the **real** `SwitcherModel` (rendered by a
/// real `SwitcherView`) and drives it IN SYNC with the demonstrated teaching gesture, so the highlight and
/// the Space-row reel move exactly as the ghost hand performs the move. The §11.5 launcher analogue is
/// `HubLauncherDemo`; this is its switcher counterpart.
///
/// ## The deterministic teaching story
/// Three fingers slide to **open** the switcher; then ONE finger lifts and the two resting fingers
/// **navigate** — UP to the second Space-row, back DOWN to the first, then SIDEWAYS across the windows in
/// the row, then a lift. `HubSwitcherDemo.teachingGesture(openLength:)` encodes the hand motion (a single
/// `GesturePose.DemoGesture` whose strokes change finger count via the connected-stroke `gapAfter: 0`
/// seam — open on three, then lift one and travel on two). This holder maps the hand's centroid back to
/// model state:
///   - `reset()` — the demo's `onOpen` (once per loop): snap to the home row + first window so each pass
///     teaches the same story.
///   - `navigate(_:)` — the demo's `onScrub` (every 2-finger frame): map the centroid to (row, column).
///     A hand lifted above the home band selects the row ABOVE home; the hand's x selects the window across
///     the row. Every navigate stroke is PURE-AXIS (vertical OR horizontal), so mapping both axes each
///     frame is safe — the idle axis rests at its home value and re-selects the home row / first column.
@MainActor
final class HubSwitcherDemo: ObservableObject {
    /// The real model the preview renders and the strokes drive.
    let model = SwitcherModel()

    /// The home Space-row the demo rests on — row 0 (the bottom of the reel), so an "up" step always has a
    /// row to reach. Set at `seed`.
    private var homeRow = 0

    // NOTE: A REAL swipe is NOT rehearsed in-section. On a real swipe the genuine switcher overlay itself
    // rises (driven by the real recognizer, with its commit/Mission-Control neutralized by
    // `AppCoordinator.switcherDemoActive`), so this holder only drives the IDLE self-playing teaching loop.
    // The "grow into the ACTUAL switcher" is that real overlay, not an in-section scale-up.

    // MARK: - Seeding

    /// Seed from a `HubPreviewModels`-built switcher (real windows + thumbnails, or the fabricated
    /// icon-only fallback), sized to `canvas` at the user's window-scale `maxScale`. Lands on the home
    /// (bottom) row's first window. Synchronous frames (icons / already-cached thumbnails) carry over;
    /// the page re-runs `seedThumbnails` against THIS model so live-capture retries land here.
    func seed(from source: SwitcherModel, canvas: CGSize, maxScale: CGFloat) {
        homeRow = 0
        model.setCanvas(canvas)
        model.setMaxScale(maxScale)
        model.setRows(source.rows, labels: source.rowLabels, startRow: homeRow, column: 0)
        for (id, image) in source.thumbnails { model.setThumbnail(image, for: id) }
    }

    /// Live window-size: re-solve the grid at the new uniform-scale cap, animated so the cards grow/shrink
    /// smoothly as the user drags the "Window size" slider — the slider and the preview move together.
    func setMaxScale(_ scale: CGFloat) {
        withAnimation(.easeInOut(duration: 0.25)) { model.setMaxScale(scale) }
    }

    // MARK: - Driving (called by the demo driver's closures)

    /// Loop start (`onOpen`): snap back to the home row + first window so every pass teaches the same story.
    func reset() {
        if model.currentRow != homeRow {
            withAnimation(.easeInOut(duration: 0.28)) { model.setRow(homeRow) }
        } else if model.selectedIndex != 0 {
            model.setColumn(0)
        }
    }

    /// A 2-finger navigate frame (`onScrub`): map the ghost hand's centroid to (row, column).
    func navigate(_ centroid: CGPoint) {
        // Row: a hand lifted above the home band selects the row ABOVE home; back in the band → home.
        let wantsUp = centroid.y <= Self.upBand
        let targetRow = wantsUp ? min(model.rowCount - 1, homeRow + 1) : homeRow
        if targetRow != model.currentRow {
            withAnimation(.easeInOut(duration: 0.3)) { model.setRow(targetRow) }
            return   // let the row slide settle before also moving the column this frame
        }
        // Column: the sideways window scrub, meaningful only on the home row. Map x across the pad to the
        // window index (snapped), stepping only on a change so the highlight doesn't strobe.
        guard targetRow == homeRow, model.windows.count > 1 else { return }
        let p = Self.progressX(centroid.x)
        let col = min(model.windows.count - 1, max(0, Int((p * CGFloat(model.windows.count - 1)).rounded())))
        if col != model.selectedIndex { model.setColumn(col) }
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

    // MARK: - Layout constants (shared with the gesture builders so the hand and the model stay in sync)

    /// The resting (home-row) band: the 2-finger nav begins here and the sideways scrub stays here.
    static let homeY: CGFloat = 0.58
    /// The "second row" band the up-stroke reaches.
    static let upY: CGFloat = 0.26
    /// Below this y the hand counts as "up" (selects the row above home) — sits between `upY` and `homeY`.
    static let upBand: CGFloat = 0.42
    /// The sideways scrub travels x across this range; mapped 0…1 to the windows in the row.
    static let scrubLeft: CGFloat = 0.28
    static let scrubRight: CGFloat = 0.80

    private static func progressX(_ x: CGFloat) -> CGFloat {
        min(1, max(0, (x - scrubLeft) / (scrubRight - scrubLeft)))
    }
}

// MARK: - Teaching + hover gesture builders

extension HubSwitcherDemo {
    /// The deterministic teaching gesture. Three-finger **open** (a short horizontal swipe whose length
    /// scales with the activation threshold so it reads as "just enough to trigger"), then — CONNECTED, no
    /// lift (`gapAfter: 0`) — ONE finger lifts and the two resting fingers go UP to the second row, back
    /// DOWN to the first, then SIDEWAYS across the windows, then a lift and loop. The coordinates match this
    /// holder's centroid→model mapping so the highlight tracks the hand.
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

// MARK: - The idle teaching miniature

/// The Switcher preview miniature: the real `SwitcherView` scaled to fit the available width, playing the
/// idle teaching loop. It does NOT grow on a real swipe — the "grow into the ACTUAL switcher" is the genuine
/// switcher overlay itself rising (neutralized so it never fires); see `AppCoordinator.switcherDemoActive`.
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
