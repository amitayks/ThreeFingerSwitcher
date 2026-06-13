import SwiftUI

/// A live visualization of the anchored-positional navigation zones (change `positional-navigation`):
/// a stylized trackpad that, while it's on screen, mirrors the user's **real fingertips** and draws the
/// **center**, **deadzone**, and the **item / band outer rings** sized to their actual finger footprint —
/// so the abstract slider values become physical zones the user can see around their fingers. The same
/// `AppSettings` values drive both this preview and the live navigation, so adjusting a slider resizes a
/// ring in real time.
///
/// It reads frames through a coordinator-provided subscription (the running `TouchEngine`'s stream,
/// mirrored — no second listener, no new permission) and stops observing when it disappears. With no live
/// touch it shows the zones at a neutral resting center with a hint, never blank.
struct PositionalTrackpadPreview: View {
    @ObservedObject var settings: AppSettings
    /// Subscribe a frame handler (the coordinator points its `onHubTouchFrame` at it).
    let subscribe: (@escaping (TouchFrame) -> Void) -> Void
    /// Tear the subscription down on disappear.
    let unsubscribe: () -> Void

    @StateObject private var model = TrackpadPreviewModel()

    /// Mac trackpads are wider than tall; this aspect keeps the normalized zones' physical shape honest
    /// (an iso-normalized circle reads as the wider-than-tall ellipse it actually is on the pad).
    private let aspect: CGFloat = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                // The anchor: live centroid, or a neutral resting center with no touch.
                let cN = model.centroid ?? CGPoint(x: 0.5, y: 0.5)
                let center = CGPoint(x: cN.x * w, y: (1 - cN.y) * h)
                // Deflection scale = footprint·factor (or the fixed fallback), in normalized units — the
                // exact value `PositionalAnchor` uses, so the box matches the model.
                let spread = model.spread ?? 0
                let scale: CGFloat = spread > 0.0001
                    ? CGFloat(settings.positionalFootprintFactor) * spread
                    : CGFloat(settings.positionalFallbackScale)
                let box = CGFloat(settings.positionalPaddingRadius) * scale   // padding-box half-size (offset → norm)
                let item = CGFloat(settings.launcherStepDistance) * scale     // one item step (offset → norm)
                let edge = CGFloat(settings.positionalEdgeMargin)             // absolute border band

                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(model.live ? 0.08 : 0.05))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(model.live ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.14),
                                      lineWidth: 1)

                    // The fixed edge-margin band (accelerate) — an inset frame hugging the border.
                    if edge > 0 {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .inset(by: 1)
                            .strokeBorder(Color.orange.opacity(model.live ? 0.55 : 0.28),
                                          lineWidth: max(1, edge * min(w, h)))
                            .allowsHitTesting(false)
                    }

                    // The padding box (step zone): leave it → accelerate. An ellipse on the wide pad.
                    zoneEllipse(rx: box * w, ry: box * h, center: center)
                        .stroke(Color.accentColor.opacity(model.live ? 0.85 : 0.4), lineWidth: 1.5)
                    // One item-step ring (faint) so the step granularity inside the box is visible.
                    zoneEllipse(rx: item * w, ry: item * h, center: center)
                        .stroke(Color.accentColor.opacity(model.live ? 0.35 : 0.18),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // The anchored center.
                    Circle().fill(Color.white.opacity(model.live ? 0.8 : 0.3))
                        .frame(width: 5, height: 5).position(center)

                    // The user's actual fingertips.
                    ForEach(Array(model.points.enumerated()), id: \.offset) { _, p in
                        ZStack {
                            Circle().fill(Color.accentColor.opacity(0.30)).frame(width: 44, height: 44).blur(radius: 9)
                            Circle().fill(Color.accentColor.opacity(0.80)).frame(width: 26, height: 26)
                        }
                        .position(x: p.x * w, y: (1 - p.y) * h)
                        .animation(.easeOut(duration: 0.06), value: model.points)
                    }

                    if !model.live {
                        Text("Rest two fingers on the trackpad to see your padding box")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 8)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: model.centroid)
                .animation(.easeOut(duration: 0.25), value: model.live)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: 170)

            // Legend.
            HStack(spacing: 14) {
                legendItem(color: .accentColor, label: "Padding box", filled: false)
                legendItem(color: .accentColor, label: "Item step", filled: false, dashed: true)
                legendItem(color: .orange, label: "Edge margin", filled: false)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.start(subscribe) }
        .onDisappear { model.stop(unsubscribe) }
    }

    private func zoneEllipse(rx: CGFloat, ry: CGFloat, center: CGPoint) -> Path {
        Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
    }

    private func legendItem(color: Color, label: String, filled: Bool, dashed: Bool = false) -> some View {
        HStack(spacing: 5) {
            ZStack {
                if filled {
                    Circle().fill(color.opacity(0.4)).frame(width: 10, height: 10)
                } else {
                    Circle().strokeBorder(color.opacity(0.8),
                                          style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
                        .frame(width: 10, height: 10)
                }
            }
            Text(label)
        }
    }
}

/// Holds the latest live trackpad state for `PositionalTrackpadPreview`. Frames arrive on the main actor
/// (the engine's `onFrame`), so updating `@Published` state here is main-thread-safe; an empty frame
/// (fingers lifted) flips `live` off and clears the dots so the preview falls back to its neutral resting
/// view rather than freezing on the last touch.
@MainActor
final class TrackpadPreviewModel: ObservableObject {
    @Published var points: [CGPoint] = []
    @Published var centroid: CGPoint?
    @Published var spread: CGFloat?
    @Published var live = false

    func start(_ subscribe: (@escaping (TouchFrame) -> Void) -> Void) {
        subscribe { [weak self] frame in self?.ingest(frame) }
    }

    func stop(_ unsubscribe: () -> Void) {
        unsubscribe()
        live = false
        points = []
        centroid = nil
        spread = nil
    }

    /// Test seam: drive `ingest` directly with a fabricated frame (the live path is `start`'s subscription).
    func ingestForTesting(_ frame: TouchFrame) { ingest(frame) }

    private func ingest(_ frame: TouchFrame) {
        guard frame.fingerCount > 0 else {        // lift → neutral resting view
            live = false
            points = []
            centroid = nil
            spread = nil
            return
        }
        points = frame.normalizedContactPoints
        centroid = frame.centroid
        spread = frame.footprintSpread
        live = true
    }
}
