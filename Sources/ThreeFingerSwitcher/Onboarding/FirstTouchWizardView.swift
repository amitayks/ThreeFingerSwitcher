import SwiftUI

/// The First Touch wizard's stage: one chromeless glass slab, acts flowing through it on the
/// motion system in `WizardMotion` — each act drifts out the top as the next rises from the
/// bottom, and unfolds in a cascade once it lands. The demo strip persists across the acts that
/// feature it (the hand and the two permission upgrades) so each grant visibly transforms a scene
/// that is already alive — the strip is lifted out of the per-act transition for that continuity.
struct FirstTouchWizardView: View {
    @ObservedObject var model: FirstTouchWizardModel

    private var showsDemoStrip: Bool {
        model.stage == .hand || model.stage == .permAX || model.stage == .permSR
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDemoStrip {
                WizardDemoStrip(model: model)
                    .padding(.top, 44)
                    .transition(.move(edge: .top).combined(with: .opacity)
                        .combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            ZStack {
                actContent
                    .id(model.stage)
                    .transition(WizardMotion.actTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
            WizardProgressDots(stage: model.stage)
                .padding(.bottom, 18)
        }
        .frame(width: 960, height: 640)
        .background(HubGlass(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(WizardMotion.actAnimation, value: model.stage)
        .animation(WizardMotion.actAnimation, value: showsDemoStrip)
    }

    @ViewBuilder
    private var actContent: some View {
        switch model.stage {
        case .fresh, .overture:        OvertureAct()
        case .hand:                    HandAct(model: model)
        case .permAX:                  AccessibilityAct(model: model)
        case .permSR, .awaitingRelaunch: ScreenRecordingAct(model: model)
        case .lanes:                   LanesAct(model: model)
        case .awaitingRelogin:         ReloginAct(model: model)
        case .playground:              PlaygroundAct(model: model)
        case .curtain, .completed:     CurtainAct(model: model)
        }
    }
}

/// The persistent demo: the real `SwitcherView` over fabricated (then real) model data. The scene
/// is choreographed as alive: a breathing glow blooms beneath it while the user's own hand drives
/// the scrub, it leans in slightly the moment the hand takes over, and a band of light sweeps
/// across it on every transformation (the takeover, the real-windows upgrade, the faces arriving).
/// The finger pad below shows the attract loop's ghost hand until real fingertips replace it.
private struct WizardDemoStrip: View {
    @ObservedObject var model: FirstTouchWizardModel

    var body: some View {
        VStack(spacing: 14) {
            SwitcherView(model: model.demo)
                .shimmerSweep(trigger: model.sceneUpgradePulse, cornerRadius: 22)
                .scaleEffect(model.liveTouchActive ? 0.845 : 0.82)
                .frame(height: SwitcherLayout.panelHeight * 0.85)
                .allowsHitTesting(false)
                .background(
                    BreathingGlowBackdrop()
                        .opacity(model.liveTouchActive ? 1 : 0)
                        .animation(.easeInOut(duration: 0.6), value: model.liveTouchActive)
                )
                .animation(WizardMotion.arrival, value: model.liveTouchActive)
            if model.stage == .hand {
                FingerDotsPad(dots: model.liveTouchActive ? model.fingerDots : model.ghostDots,
                              live: model.liveTouchActive)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }
}

/// A stylized trackpad. Before the user touches it, the attract loop's ghost hand sweeps across
/// it (three faint fingertips, in step with the strip's self-scrub — the pad demonstrates the
/// gesture it invites). The moment real touch frames arrive the ghosts yield: the dots brighten,
/// the border warms to accent, and the user's actual fingertips drive both pad and strip.
struct FingerDotsPad: View {
    let dots: [CGPoint]
    let live: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(live ? 0.08 : 0.05))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(live ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.14),
                                  lineWidth: 1)
                ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(live ? 0.30 : 0.14))
                            .frame(width: 28, height: 28)
                            .blur(radius: 6)
                        Circle()
                            .fill(Color.accentColor.opacity(live ? 0.75 : 0.38))
                            .frame(width: 16, height: 16)
                    }
                    .position(x: dot.x * geo.size.width,
                              y: (1 - dot.y) * geo.size.height)
                    .animation(.easeOut(duration: 0.06), value: dots)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(WizardMotion.pop, value: dots.count)
            .animation(.easeOut(duration: 0.3), value: live)
        }
        .frame(width: 190, height: 124)
    }
}

/// The quiet progress affordance: one mark per act. The current act stretches into a glowing
/// capsule; acts already performed keep a warm tint trail; acts to come wait faint. Every change
/// morphs — the switcher's row-indicator idiom, grown a heartbeat.
struct WizardProgressDots: View {
    let stage: FirstRunStage

    private static let acts: [FirstRunStage] = [.hand, .permAX, .permSR, .lanes, .playground, .curtain]

    private var activeIndex: Int? {
        switch stage {
        case .awaitingRelaunch: return Self.acts.firstIndex(of: .permSR)
        case .awaitingRelogin:  return Self.acts.firstIndex(of: .lanes)
        case .completed:        return Self.acts.count - 1
        default:                return Self.acts.firstIndex(of: stage)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.acts.indices, id: \.self) { index in
                Capsule()
                    .fill(fill(for: index))
                    .frame(width: index == activeIndex ? 22 : 7, height: 7)
                    .shadow(color: index == activeIndex ? Color.accentColor.opacity(0.5) : .clear,
                            radius: 4)
            }
        }
        .animation(WizardMotion.arrival, value: activeIndex)
        .opacity(stage == .overture || stage == .fresh ? 0 : 1)
        .animation(.easeOut(duration: 0.3), value: stage == .overture || stage == .fresh)
    }

    private func fill(for index: Int) -> Color {
        guard let active = activeIndex else { return Color.white.opacity(0.25) }
        if index == active { return .accentColor }
        if index < active { return Color.accentColor.opacity(0.40) }
        return Color.white.opacity(0.25)
    }
}

/// Hold-to-continue: the wizard's primary advance affordance on the playground act — the launcher's
/// dwell-to-arm taught by using it. Press begins the charge (the same linear tint ramp as the
/// launcher's `SelectionSquare`, with a barely-perceptible inflate as it fills), the shared
/// `DwellArmDriver` arms it with the product's haptic tick — the button pops and glows — and
/// RELEASING once armed fires — exactly the launcher's hold → tick → lift contract. An abandoned
/// charge deflates softly back to rest.
struct HoldToContinueButton: View {
    let label: String
    let dwell: Double
    let action: () -> Void

    @State private var driver = DwellArmDriver()
    @State private var charging = false
    @State private var armed = false
    @State private var intensity: CGFloat = 0

    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 26)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10 + 0.42 * intensity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(armed ? 1 : 0.45), lineWidth: armed ? 2 : 1)
            )
            .scaleEffect(armed ? 1.06 : 1.0 + 0.02 * intensity)
            .shadow(color: Color.accentColor.opacity(armed ? 0.45 : 0), radius: armed ? 14 : 0)
            .animation(WizardMotion.arrival, value: armed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginChargeIfNeeded() }
                    .onEnded { _ in release() }
            )
            .accessibilityHint("Hold until it arms, then release — the same dwell the launcher uses.")
    }

    private func beginChargeIfNeeded() {
        guard !charging else { return }
        charging = true
        armed = false
        withAnimation(.linear(duration: dwell)) { intensity = 1 }
        driver.charge(after: dwell) {
            armed = true
            DwellArmDriver.hapticTick()
        }
    }

    private func release() {
        driver.cancel()
        charging = false
        if armed {
            action()
        } else {
            withAnimation(.easeOut(duration: 0.2)) { intensity = 0 }
        }
        armed = false
    }
}

/// Shared act scaffold: headline, supporting line, content, and the action row — every act reads
/// the same way and arrives the same way: the four slots bloom top-to-bottom on the cascade, and
/// copy that changes meaning in place (a headline reacting to a grant) crossfades rather than cuts.
struct WizardActPanel<Content: View, Actions: View>: View {
    let headline: String
    let line: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    @State private var revealed = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(headline)
                    .font(.system(size: 26, weight: .bold))
                    .contentTransition(.opacity)
                    .wizardCascade(0, revealed: revealed)
                if let line {
                    Text(line)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .wizardCascade(1, revealed: revealed)
                }
            }
            .animation(WizardMotion.copy, value: headline)
            .animation(WizardMotion.copy, value: line)
            content()
                .wizardCascade(2, revealed: revealed)
            actions()
                .wizardCascade(3, revealed: revealed)
        }
        // Clamp the act's content column so cards and copy keep breathing room from the window
        // edges (children with greedy widths stop at the column, not the glass border).
        .frame(maxWidth: 820)
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity)
        .onAppear { revealed = true }
    }
}
