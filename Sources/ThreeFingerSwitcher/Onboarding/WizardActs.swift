import SwiftUI

// The First Touch wizard's acts. Copy is honest everywhere: what a permission unlocks before it is
// asked for, what a relocation writes, what is backed up, what a re-login is for. No act blocks;
// every act can be skipped or deferred, and skipping everything is a first-class path.
//
// Motion is the other voice: every act draws from `WizardMotion` — content blooms in on the
// cascade, state changes morph (never cut), arrivals land on a settle spring with a ring and the
// product's single haptic, and waiting states breathe. The acts share the choreography so the
// whole wizard moves as one performance.

// MARK: - Act 0: Overture

struct OvertureAct: View {
    @State private var iconShown = false
    @State private var titleShown = false
    @State private var lineShown = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                PulseHalo(size: 210)
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)
                    .scaleEffect(iconShown ? 1 : 0.82)
                    .opacity(iconShown ? 1 : 0)
            }
            Text("ThreeFingerSwitcher")
                .font(.system(size: 30, weight: .bold))
                .opacity(titleShown ? 1 : 0)
                .offset(y: titleShown ? 0 : 14)
            Text("Your windows, under your fingers.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .opacity(lineShown ? 1 : 0)
                .offset(y: lineShown ? 0 : 10)
        }
        .onAppear {
            // The brand breathes in: mark, then name, then the line — one inhale, three beats.
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) { iconShown = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.22)) { titleShown = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.42)) { lineShown = true }
        }
    }
}

// MARK: - Act I: The Hand

/// Act I completes by the product's own gesture: scrub, then lift — the lift advances the wizard
/// (no Continue click; the strip stays live under the hand on the next act). A quiet fallback
/// remains for the no-trackpad cinema path, and re-appears if a lift never scrubbed.
struct HandAct: View {
    @ObservedObject var model: FirstTouchWizardModel

    var body: some View {
        WizardActPanel(
            headline: model.liveTouchActive ? "That's it. That's the switcher." : "Put three fingers on the trackpad",
            line: model.liveTouchActive
                ? "Slide left and right — the highlight follows your hand. Lift when you're done: the wizard moves on with you."
                : "…and slide. The strip above will follow your fingers — nothing to click, nothing to learn."
        ) {
            EmptyView()
        } actions: {
            Group {
                if !model.liveTouchActive {
                    Button("Continue without the trackpad") { model.advance() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if model.liftedWithoutScrub {
                    Button("Continue") { model.advance() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .animation(WizardMotion.pop, value: model.liveTouchActive)
            .animation(WizardMotion.pop, value: model.liftedWithoutScrub)
        }
    }
}

// MARK: - Act II: Accessibility — "let it see your windows"

struct AccessibilityAct: View {
    @ObservedObject var model: FirstTouchWizardModel
    @ObservedObject private var permissions: PermissionsService

    init(model: FirstTouchWizardModel) {
        self.model = model
        self.permissions = model.context.permissions
    }

    private var granted: Bool { permissions.accessibility == .granted }

    var body: some View {
        WizardActPanel(
            headline: granted ? "Now they're your windows" : "Let it see your windows",
            line: granted
                ? "The cards above are your real windows now. One more permission gives them their faces."
                : "Accessibility lets the switcher list and raise your windows — across every Space. Grant it in System Settings and watch the demo above become real."
        ) {
            Group {
                if granted {
                    GrantedSeal()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(WizardMotion.arrival, value: granted)
        } actions: {
            PermissionActionsRow(granted: granted) {
                Button("Grant Accessibility") { model.context.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Skip for now") { model.advance() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Act II: Screen Recording — "give the windows their faces"

struct ScreenRecordingAct: View {
    @ObservedObject var model: FirstTouchWizardModel
    @ObservedObject private var permissions: PermissionsService

    init(model: FirstTouchWizardModel) {
        self.model = model
        self.permissions = model.context.permissions
    }

    private var granted: Bool { permissions.screenRecording == .granted }

    var body: some View {
        WizardActPanel(
            headline: granted ? "There they are" : "Give the windows their faces",
            line: granted
                ? "Live thumbnails — the strip above is your actual desktop now."
                : "Screen Recording draws live window thumbnails on the cards. Without it, cards show icons and titles only. macOS applies this grant when the app reopens — the relaunch takes two seconds and the wizard resumes right here."
        ) {
            Group {
                if granted {
                    GrantedSeal()
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(WizardMotion.arrival, value: granted)
        } actions: {
            PermissionActionsRow(granted: granted) {
                Button("Grant Screen Recording") { model.context.requestScreenRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Relaunch now") { model.relaunchNow() }
                    .buttonStyle(.bordered)
                Button("Skip for now") { model.advance() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The permission acts' action row. The grant IS the continue: when it lands, the request buttons
/// morph away (scale+fade on the arrival spring) and the act flows onward by itself after the
/// seal's beat — one click in System Settings, zero clicks here.
private struct PermissionActionsRow<Request: View>: View {
    let granted: Bool
    @ViewBuilder var request: () -> Request

    var body: some View {
        HStack(spacing: 12) {
            if !granted {
                request()
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(WizardMotion.arrival, value: granted)
    }
}

/// The grant-detected moment: the Setup page's "Ready" seal motif — stamped in on the arrival
/// spring with a radiating ring and the product's haptic tick. Scales for the curtain's finale.
struct GrantedSeal: View {
    var size: CGFloat = 34
    var halo = false
    @State private var shown = false

    var body: some View {
        ZStack {
            if halo {
                PulseHalo(color: .green, size: size * 3.4, intensity: 0.7)
            }
            if shown {
                RippleRing(color: .green, baseSize: size * 1.5)
            }
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size))
                .foregroundStyle(.green)
                .scaleEffect(shown ? 1 : 0.4)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(WizardMotion.arrival) { shown = true }
            DwellArmDriver.hapticTick()
        }
    }
}

// MARK: - Act III: Claim the Lanes

struct LanesAct: View {
    @ObservedObject var model: FirstTouchWizardModel

    private var anyFailure: Bool {
        guard let outcome = model.lanesOutcome else { return false }
        return !outcome.failed.isEmpty || outcome.spacesFailed
    }

    var body: some View {
        WizardActPanel(
            headline: "Claim the lanes",
            line: "macOS uses some trackpad lanes for its own gestures. Everything below is on because together it's the app at its best — switch off anything you don't want. Each change saves the current setting first (restorable anytime from Setup), and one log-out makes them all live."
        ) {
            VStack(spacing: 10) {
                LaneRow(symbol: "arrow.left.and.right",
                        title: "Three fingers, sideways",
                        now: "Switch full-screen apps",
                        after: "Scrub your windows — the switcher",
                        state: model.lanesTrackpadClaimed ? .included : .done)
                    .wizardBloom(0)
                LaneRow(symbol: "arrow.up.and.down",
                        title: "Three fingers, up and down",
                        now: "Mission Control / App Exposé",
                        after: "Hop between Spaces mid-scrub (Mission Control stays on idle up/down)",
                        state: .choice($model.lanes.spaceRows))
                    .wizardBloom(1)
                LaneRow(symbol: "square.grid.3x3",
                        title: "Four fingers",
                        now: "Full-screen swipe / Mission Control",
                        after: "Your launcher — favorites under your hand",
                        state: .choice($model.lanes.launcher))
                    .wizardBloom(2)
                LaneRow(symbol: "rectangle.split.3x1",
                        title: "Spaces order",
                        now: "Rearranged by recent use",
                        after: "Fixed — each Space stays put (takes effect immediately)",
                        state: model.lanesSpacesChoiceAvailable ? .choice($model.lanes.fixedSpaces) : .done)
                    .wizardBloom(3)
                if let outcome = model.lanesOutcome, anyFailure {
                    LanesFailureNotice(outcome: outcome)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(WizardMotion.pop, value: anyFailure)
        } actions: {
            HStack(spacing: 12) {
                Button("Claim the lanes") { model.applyLanes() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Not now") { model.skipLanes() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One trackpad lane: what macOS does with it now, what it becomes, and the choice (or its
/// done/included state). Flipping the switch plays the claim in place: the "now" strikes through,
/// the "after" takes the light, the arrow leans forward, and the row warms with an accent edge.
struct LaneRow: View {
    enum LaneState {
        case included            // part of the core switcher — always claimed
        case done                // already in the desired state — nothing to change
        case choice(Binding<Bool>)
    }

    let symbol: String
    let title: String
    let now: String
    let after: String
    let state: LaneState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(now).strikethrough(isOn).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .offset(x: isOn ? 2 : 0)
                    Text(after).foregroundStyle(isOn ? .primary : .secondary)
                }
                .font(.system(size: 11))
            }
            Spacer()
            switch state {
            case .included:
                Text("The switcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .choice(let binding):
                Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
            }
        }
        .padding(12)
        .background(HubGlass(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(chosen ? 0.45 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.22), value: isOn)
    }

    private var isOn: Bool {
        switch state {
        case .included: return true
        case .done: return false
        case .choice(let binding): return binding.wrappedValue
        }
    }

    /// Only a *choice* the user made glows — the always-included row states itself quietly.
    private var chosen: Bool {
        if case .choice(let binding) = state { return binding.wrappedValue }
        return false
    }
}

/// Managed-Mac degradation, in place and non-modal: which changes did not land, and where to do
/// them by hand. The affected features stay off.
struct LanesFailureNotice: View {
    let outcome: LanesApplyOutcome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some settings couldn't be changed")
                    .font(.system(size: 12, weight: .semibold))
                Text("If this Mac is managed (MDM), trackpad settings may be locked. You can change them manually in System Settings ▸ Trackpad ▸ More Gestures. The affected features stay off until then.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(HubGlass(cornerRadius: 12))
    }
}

// MARK: - The one re-login moment

struct ReloginAct: View {
    @ObservedObject var model: FirstTouchWizardModel

    var body: some View {
        WizardActPanel(
            headline: "One log-out hands you the lanes",
            line: "macOS routes trackpad gestures at login, so the lanes you claimed go live the next time you log in. Everything else keeps working right now — log out whenever suits you."
        ) {
            // A waiting state, so it breathes: the door glyph rests in a slow halo, its glow
            // rising and falling — alive, unhurried, no urgency manufactured.
            ZStack {
                PulseHalo(size: 130)
                TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { ctx in
                    let phase = ctx.date.timeIntervalSinceReferenceDate
                    Image(systemName: "arrow.right.square")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                        .opacity(0.75 + 0.25 * (0.5 + 0.5 * sin(phase * 1.6)))
                }
            }
        } actions: {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button("Log Out Now…") { model.logOutNow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Later — keep going") { model.advance() }
                        .buttonStyle(.bordered)
                }
                Text("Log Out Now sends the standard ⇧⌘Q — macOS will ask to confirm. (Or use the Apple menu anytime.)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Act IV: The Playground

struct PlaygroundAct: View {
    @ObservedObject var model: FirstTouchWizardModel
    @ObservedObject private var settings: AppSettings
    /// Observed directly: the act renders conditionally on the demo's bands, so it must observe
    /// the demo itself — the seed lands via `enterStage`, and an unobserved first evaluation would
    /// otherwise stick on the empty fallback forever.
    @ObservedObject private var launcherDemo: LauncherModel

    init(model: FirstTouchWizardModel) {
        self.model = model
        self.settings = model.context.settings
        self.launcherDemo = model.launcherDemo
    }

    /// The tour's natural (unscaled) size, boxed explicitly: `scaleEffect` is visual-only, so
    /// without the outer frame the launcher's intrinsic width would blow the act's layout open
    /// (cards pushed to the window edges).
    private var tourSize: CGSize {
        let width = LauncherGridLayout.containerWidth
            + (launcherDemo.bandCount > 1 ? LauncherGridLayout.bandColumnWidth : 0)
        let height = min(LauncherGridLayout.windowHeight(itemCount: launcherDemo.items.count,
                                                         bandCount: launcherDemo.bandCount), 400)
        return CGSize(width: width, height: height)
    }

    private let tourScale: CGFloat = 0.5

    /// Play scale: as close to actual size as the stage allows — the real launcher is wider than
    /// the wizard window, so "full size" is capped to fit with breathing room.
    private var playScale: CGFloat {
        min(1.0, 880 / max(tourSize.width, 1), 470 / max(tourSize.height, 1))
    }

    var body: some View {
        let playing = model.tourPlayActive
        WizardActPanel(
            headline: model.tourCompleted ? "That's the whole trick" : "Four fingers — your launcher",
            line: model.tourCompleted
                ? "Slide, hold, lift — the launcher is yours. Pick any extras below, then continue."
                : (launcherDemo.bandCount > 0
                    ? "Put four fingers on the trackpad and the demo becomes the real launcher, live under your hand: slide to an item, hold until it ticks, lift. (The tour never fires anything.) The button below charges the same way."
                    : "A few optional features — each states its real cost, all of them off until you say so.")
        ) {
            VStack(spacing: 14) {
                if launcherDemo.bandCount > 0 {
                    // One launcher, two sizes: at rest it idles at demo scale in a fixed slot;
                    // the moment four fingers land it MORPHS to (near-)actual size, floating
                    // over the act while the hand plays the real thing, and settles back into
                    // its slot on the lift. The slot never changes size, so nothing reflows.
                    LauncherView(model: launcherDemo, executor: nil, availability: nil)
                        .frame(width: tourSize.width, height: tourSize.height)
                        // Completing the contract washes light across the tour — the scene's
                        // applause for the hand that just learned it.
                        .shimmerSweep(trigger: model.tourCompleted ? 1 : 0, cornerRadius: 30)
                        .scaleEffect(playing ? playScale : tourScale)
                        .frame(width: tourSize.width * tourScale, height: tourSize.height * tourScale)
                        .zIndex(playing ? 2 : 0)
                        .allowsHitTesting(false)
                        .animation(WizardMotion.arrival, value: playing)
                        .animation(.easeInOut(duration: 0.3), value: launcherDemo.bandCount)
                        // The box's size now genuinely varies per band (item rows vs band-list
                        // demand, like the real panel) — animate the SIZE value too, at the
                        // launcher panel's exact re-fit timing, or the frames snap ("cut") on
                        // band switches and the slot reflows the act column without motion.
                        .animation(.easeInOut(duration: 0.24), value: tourSize)
                }
                // While the hand plays full-size, everything else steps back into the wings.
                Group {
                    LauncherLaneRow(model: model, settings: settings)
                        .wizardBloom(0)
                    HStack(spacing: 10) {
                        OptionalFeatureCard(
                            symbol: "doc.on.clipboard", title: "Clipboard history",
                            cost: "Records what you copy. Stays on this Mac. No permission, instant.",
                            isOn: $settings.keepClipboardHistory, index: 1)
                        OptionalFeatureCard(
                            symbol: "sparkles", title: "AI commands",
                            cost: "On-device Gemma model — a one-time multi-gigabyte download. Apple Silicon only.",
                            isOn: $settings.aiCommandsEnabled, index: 2)
                        OptionalFeatureCard(
                            symbol: "globe", title: "Keyboard language",
                            cost: "Remembers your input source per app. No permission, no re-login.",
                            isOn: $settings.keyboardLanguageEnabled, index: 3)
                    }
                    Text("Tip: add favorites from any app via the menu-bar icon — “Add Front App to Band”.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .opacity(playing ? 0.15 : 1)
                .animation(.easeOut(duration: 0.25), value: playing)
            }
        } actions: {
            // The hold-button *becomes* Continue the moment the contract completes in the tour —
            // a morph on the arrival spring, the affordance graduating with its user.
            Group {
                if model.tourCompleted {
                    Button("Continue") { model.advance() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    HoldToContinueButton(label: "Hold to continue — feel the tick, then lift",
                                         dwell: settings.dwellToArmDuration) {
                        model.advance()
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(WizardMotion.arrival, value: model.tourCompleted)
            .opacity(playing ? 0.15 : 1)
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }
}

/// The four-finger lane, claimable right where the launcher makes its case: the user who opted
/// out on the lanes act (or skipped it) can change their mind mid-play without going back. ON
/// applies the same unified relocation (current setting saved first, one re-login); OFF quietly
/// restores the backup. The caption always tells the truth about the lane's state.
private struct LauncherLaneRow: View {
    @ObservedObject var model: FirstTouchWizardModel
    @ObservedObject var settings: AppSettings

    private var caption: String {
        if model.launcherLaneFailed {
            return "The trackpad setting couldn't be written (managed Mac?). System Settings ▸ Trackpad ▸ More Gestures does it manually."
        }
        if !settings.enableLauncher {
            return "macOS keeps the four-finger swipes for itself. Claim them and four fingers open the launcher anywhere — the current setting is saved first; one log-out makes it live."
        }
        return model.launcherTourLive
            ? "Live — four fingers open the launcher anywhere."
            : "Claimed — goes live at your next log-in. The tour above already plays the real thing."
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 18))
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Four-finger launcher").font(.system(size: 13, weight: .medium))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(model.launcherLaneFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.enableLauncher },
                set: { model.setLauncherLane($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(12)
        .background(HubGlass(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(settings.enableLauncher ? 0.45 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.22), value: settings.enableLauncher)
        .animation(WizardMotion.copy, value: caption)
    }
}

/// An optional feature offered honestly: name, true cost, a switch. Writes the same persisted
/// preference as the Hub page; declining is the default. Cards ripple in with the act; a chosen
/// card warms — accent edge, soft lift — so the user's yes is visible at a glance.
struct OptionalFeatureCard: View {
    let symbol: String
    let title: String
    let cost: String
    @Binding var isOn: Bool
    var index: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .opacity(isOn ? 1 : 0.7)
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(cost)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubGlass(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isOn ? 0.5 : 0), lineWidth: 1)
        )
        .shadow(color: Color.accentColor.opacity(isOn ? 0.18 : 0), radius: 10)
        .animation(.easeOut(duration: 0.22), value: isOn)
        .wizardBloom(index)
    }
}

// MARK: - Act V: The Curtain

struct CurtainAct: View {
    @ObservedObject var model: FirstTouchWizardModel

    var body: some View {
        WizardActPanel(
            headline: "Ready",
            line: "The app lives in your menu bar; everything is configurable in the Hub (menu bar ▸ Open Hub…). You can replay this tour anytime from Hub ▸ Setup."
        ) {
            VStack(spacing: 14) {
                GrantedSeal(size: 44, halo: true)
                    .wizardBloom(0)
                if model.relocationsStillPending {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                        Text("Your claimed lanes go live after the next log-out — until then those gestures stay with macOS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(HubGlass(cornerRadius: 10))
                    .wizardBloom(1)
                }
                Toggle(isOn: Binding(
                    get: { model.openAtLogin },
                    set: { _ in model.toggleOpenAtLogin() }
                )) {
                    Text("Open at Login — so it's always under your fingers")
                        .font(.system(size: 13))
                }
                .toggleStyle(.switch)
                .wizardBloom(2)
            }
        } actions: {
            Button("Start using ThreeFingerSwitcher") { model.finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
