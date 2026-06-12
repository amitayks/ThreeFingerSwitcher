import SwiftUI

// The First Touch wizard's motion system — defined once, drawn from everywhere, so the whole
// performance moves as one piece. The overlays' runtime vocabulary (0.12–0.16 s easeOut pops,
// 0.24–0.32 s easeInOut container moves, the asymmetric slide+fade) stays untouched at runtime;
// the wizard layers its own performance vocabulary over it: settle springs for arrivals, a
// staggered bloom for act content, a light sweep for in-place scene transformations, and
// breathing halos for waiting states. Every state change in the wizard routes through one of
// these primitives — nothing cuts, everything flows.
enum WizardMotion {
    /// The river: the animation that carries one act out and the next in. A settle spring —
    /// organic deceleration with no bounce-past — so acts arrive like they have weight.
    static var actAnimation: Animation { .spring(response: 0.55, dampingFraction: 0.86) }

    /// Acts drift out the top and rise in from the bottom (the switcher's own Space-row direction),
    /// breathing slightly in scale so the stage feels like it inhales each act.
    static var actTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity)
                .combined(with: .scale(scale: 0.97)),
            removal: .move(edge: .top).combined(with: .opacity)
                .combined(with: .scale(scale: 0.97))
        )
    }

    /// Arrival: the settle of something that just became true — a seal stamping, a charge arming,
    /// a hand taking over. Slightly under-damped so the moment lands with a felt beat.
    static var arrival: Animation { .spring(response: 0.38, dampingFraction: 0.72) }

    /// The product's quick pop for small state flips (button sets morphing, dots appearing).
    static var pop: Animation { .easeOut(duration: 0.14) }

    /// Crossfade for copy whose meaning changes in place (a headline reacting to a grant).
    static var copy: Animation { .easeInOut(duration: 0.28) }

    /// The act-content cascade: headline, supporting line, content, actions bloom in order —
    /// each on its own delayed settle spring, so an act unfolds rather than appears.
    static func cascade(_ index: Int) -> Animation {
        .spring(response: 0.5, dampingFraction: 0.85).delay(0.08 + 0.07 * Double(index))
    }
}

// MARK: - Cascade / bloom

/// Staggered bloom driven by the act panel's reveal flag: the indexed element rises 12 pt and
/// fades in on its own delay, so the act's structure (headline → line → content → actions)
/// unfolds top-to-bottom as one gesture.
private struct WizardCascade: ViewModifier {
    let index: Int
    let revealed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 12)
            .animation(WizardMotion.cascade(index), value: revealed)
    }
}

/// Self-contained bloom for repeated items inside an act's content (lane rows, feature cards,
/// curtain elements): each reveals itself on appearance, staggered by its index, riding on top of
/// the act's own cascade so lists ripple in.
private struct WizardBloomIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)
                    .delay(0.05 + 0.06 * Double(index))) { shown = true }
            }
    }
}

extension View {
    /// Act-structure cascade (see `WizardCascade`). `index` orders the bloom; `revealed` is the
    /// act panel's single reveal flag.
    func wizardCascade(_ index: Int, revealed: Bool) -> some View {
        modifier(WizardCascade(index: index, revealed: revealed))
    }

    /// Item-level ripple inside act content (see `WizardBloomIn`).
    func wizardBloom(_ index: Int) -> some View {
        modifier(WizardBloomIn(index: index))
    }
}

// MARK: - Arrival ring

/// A single expanding ring fired once on appearance — the radiating edge of an arrival moment
/// (a permission seal, the Ready seal). Pairs with `WizardMotion.arrival` on the sealed mark.
struct RippleRing: View {
    var color: Color = .green
    var baseSize: CGFloat = 48
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(expanded ? 0 : 0.5), lineWidth: 2)
            .frame(width: baseSize, height: baseSize)
            .scaleEffect(expanded ? 2.4 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.8).delay(0.05)) { expanded = true }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Breathing halo

/// A soft breathing halo — the AI canvas's sparkle-pulse idiom generalized: `TimelineView`-driven
/// (no bound state), calm enough to wait on. Used behind the brand mark, behind waiting states
/// (the re-login door), and under the demo strip while the user's hand drives it.
struct PulseHalo: View {
    var color: Color = .accentColor
    var size: CGFloat = 120
    var intensity: Double = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(phase * 1.6)
            Circle()
                .fill(RadialGradient(
                    colors: [color.opacity((0.20 + 0.14 * breath) * intensity), .clear],
                    center: .center, startRadius: 0, endRadius: size / 2))
                .frame(width: size, height: size)
                .scaleEffect(0.92 + 0.10 * breath)
        }
        .allowsHitTesting(false)
    }
}

/// The glow that lives under the demo strip while the user's real fingers drive it — a wide soft
/// ellipse breathing gently, so the scene visibly comes alive under the hand.
struct BreathingGlowBackdrop: View {
    var color: Color = .accentColor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(phase * 1.4)
            Ellipse()
                .fill(RadialGradient(
                    colors: [color.opacity(0.16 + 0.10 * breath), .clear],
                    center: .center, startRadius: 0, endRadius: 220))
                .scaleEffect(x: 1.15, y: 0.9 + 0.06 * breath)
                .blur(radius: 18)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Transformation sweep

/// A band of light washed across a view whenever `trigger` increments — the visual of a scene
/// being transformed in place: sample cards becoming real windows, faces arriving on the cards,
/// the user's hand taking over the scrub, the tour contract completing. The sweep starts parked
/// off the leading edge and exits past the trailing edge, clipped to the view's rounded shape.
struct ShimmerSweep: ViewModifier {
    let trigger: Int
    var cornerRadius: CGFloat = 22
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.20), .clear],
                        startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: phase * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            )
            .onChange(of: trigger) { _, _ in
                var park = Transaction()
                park.disablesAnimations = true
                withTransaction(park) { phase = -0.6 }
                withAnimation(.easeInOut(duration: 0.85)) { phase = 1.1 }
            }
    }
}

extension View {
    /// Wash a band of light across this view each time `trigger` increments.
    func shimmerSweep(trigger: Int, cornerRadius: CGFloat = 22) -> some View {
        modifier(ShimmerSweep(trigger: trigger, cornerRadius: cornerRadius))
    }
}
