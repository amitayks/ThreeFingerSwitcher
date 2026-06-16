import AppKit
import Combine
import SwiftUI

/// Drives the First Touch wizard: the persisted act progression, the embedded switcher demo (the
/// attract loop that hands over to the user's real fingers), the permission-upgrade reactions, the
/// lanes apply, and the playground's launcher demo. Pure presentation state — every system effect
/// goes through `WizardContext` closures.
@MainActor
final class FirstTouchWizardModel: ObservableObject {
    let context: WizardContext
    private let store: FirstRunStore

    /// The act currently on stage. Persisted on every transition so any interruption resumes.
    @Published private(set) var stage: FirstRunStage = .overture

    // Act I — the demo strip and the live hand.
    let demo = SwitcherModel()
    /// Normalized (0..1, trackpad space) fingertip positions while live touch drives the demo.
    @Published var fingerDots: [CGPoint] = []
    /// The attract loop's ghost hand: three faint fingertips sweeping the pad in step with the
    /// strip's self-scrub, demonstrating the gesture until real fingers replace them.
    @Published private(set) var ghostDots: [CGPoint] = []
    /// True once the user's own fingers took over from the attract loop.
    @Published var liveTouchActive = false
    /// The hand act auto-advances on the lift that completes the gesture (scrub, then lift) — the
    /// user never clicks Continue; the wizard moves with their hand. True when a lift happened
    /// without any scrub, so the act re-offers a quiet manual way forward instead of dead-ending.
    @Published private(set) var liftedWithoutScrub = false
    /// Whether the user's live touch actually scrubbed the strip (the column moved) — the
    /// "successfully moved between windows" half of the hand act's completion gesture.
    private var scrubbedDuringLiveTouch = false
    /// True once the demo strip shows the user's real windows (post-Accessibility upgrade).
    @Published private(set) var demoShowsRealWindows = false
    /// Bumped on every in-place transformation of the demo scene (the hand taking over, sample
    /// cards becoming real windows, faces arriving) — the view answers each bump with a light
    /// sweep across the strip, so every upgrade is *seen* happening, never just swapped.
    @Published private(set) var sceneUpgradePulse = 0

    // Act III — the lanes.
    @Published var lanes = LaneChoices()
    @Published var lanesOutcome: LanesApplyOutcome?

    // Live-state snapshots for the acts. SwiftUI body must NEVER invoke the context's
    // gesture-state closures directly: those shell out to /usr/bin/defaults and block on
    // waitUntilExit, which pumps a nested run loop — re-entering the AppKit update cycle
    // mid-render is a segfault (observed: SIGSEGV in UpdateCycle from LanesAct.body). Every act
    // renders from these published snapshots, taken in `prepareStage` (before the act's first
    // frame) and refreshed at the few moments they can change.
    /// Lanes act: the three-finger horizontal lane is already claimed (replay/done state).
    @Published private(set) var lanesTrackpadClaimed = false
    /// Lanes act: Spaces auto-rearrange is on, so the fixed-order choice is offerable.
    @Published private(set) var lanesSpacesChoiceAvailable = false
    /// Playground act: the four-finger lanes are already effective (the recognizer then drives the
    /// tour; until they are, the raw touch feed does — see `handleTourTouch`).
    @Published private(set) var launcherTourLive = false
    /// Playground act: four fingers are down and driving the tour RIGHT NOW — the demo morphs to
    /// full size while true (the user plays the actual launcher) and back when the hand lifts.
    @Published private(set) var tourPlayActive = false
    /// Playground act: the four-finger relocation awaits its re-login (the lane row's caption).
    @Published private(set) var launcherLanePending = false
    /// Playground act: the lane toggle's write failed (managed Mac) — surfaced inline on the row.
    @Published private(set) var launcherLaneFailed = false
    /// Curtain act: relocations still await their re-login (the amber ribbon).
    @Published private(set) var relocationsStillPending = false
    /// Curtain act: current Open-at-Login registration.
    @Published private(set) var openAtLogin = false

    // Act IV — the playground's embedded launcher.
    let launcherDemo = LauncherModel()
    /// True once the user completed the full gesture contract in the tour (slide → dwell-arm →
    /// lift on an item): the act's hold-button converts to a plain Continue.
    @Published private(set) var tourCompleted = false

    private var attractTimer: Timer?
    private var attractPhase: Double = 0
    /// The faces-arrived sweep fires once — thumbnails stream in card by card, so the sweep is
    /// scheduled a beat after the first seed rather than per capture.
    private var thumbnailRevealPulsed = false
    private var overtureAdvance: DispatchWorkItem?
    /// The grant-detected auto-advance: a permission act flows to the next act on its own once the
    /// grant lands — after a beat that lets the seal stamp and the scene transformation play.
    private var grantAdvance: DispatchWorkItem?
    /// The grant beats (seconds): Accessibility transforms the cards instantly so a short beat is
    /// enough; Screen Recording's faces stream in, so its beat covers the reveal sweep. Internal
    /// so tests can shrink them.
    var grantBeats: (ax: TimeInterval, sr: TimeInterval) = (1.4, 2.4)
    /// The tour's four-finger drive: centroid position at the last emitted step (re-anchored per
    /// step so travel accumulates naturally), nil while no four-finger contact.
    private var tourTouchAnchor: CGPoint?
    /// Normalized trackpad travel per step in the tour's raw drive — tuned to feel like the
    /// recognizer's stepping (a fine horizontal item step, a deliberate vertical row/band step).
    static let tourStepX: CGFloat = 0.085
    static let tourStepY: CGFloat = 0.13
    /// The playground tour's dwell (the shared driver, so it charges exactly like the launcher).
    private let tourDwell = DwellArmDriver()
    private var cancellables: Set<AnyCancellable> = []

    /// The acts that keep the demo strip on stage. The scene stays ALIVE under the hand through
    /// all of them — the touch feed and the attract loop span the trio, so a permission grant
    /// upgrades a strip the user is still driving (not a frozen picture).
    private static let demoStages: Set<FirstRunStage> = [.hand, .permAX, .permSR]

    init(context: WizardContext, store: FirstRunStore) {
        self.context = context
        self.store = store
        seedSampleDemo()
        observePermissionUpgrades()
        observeTourToggles()
    }

    // MARK: - Stage progression

    /// Enter the wizard at the right act for the persisted progress (launch, relaunch, re-login).
    func resume() {
        let target = FirstRunMachine.resumeStage(persisted: store.stage,
                                                 relocationsStillPending: context.relocationsPending())
        transition(to: target)
    }

    /// The linear next act.
    func advance() {
        transition(to: FirstRunMachine.next(after: stage))
    }

    private func transition(to newStage: FirstRunStage) {
        leaveCurrentStage()
        // Anything the act's FIRST frame renders from is prepared BEFORE the stage flips, so the
        // whole scene arrives together (no launcher popping in a beat after the background).
        prepareStage(newStage)
        withAnimation(WizardMotion.actAnimation) {
            stage = newStage
        }
        store.stage = newStage
        enterStage(newStage)
    }

    /// State the incoming act's first render depends on — runs before the stage is published.
    /// This is also where the context's process-spawning state closures are allowed to run (and
    /// ONLY here / in event handlers — never from body; see the snapshot block above).
    private func prepareStage(_ stage: FirstRunStage) {
        switch stage {
        case .lanes:
            lanesTrackpadClaimed = context.trackpadClaimed()
            lanesSpacesChoiceAvailable = context.spacesAutoRearrangeOn()
            lanes.fixedSpaces = lanesSpacesChoiceAvailable
        case .playground:
            launcherTourLive = context.launcherLive()
            launcherLanePending = context.relocationsPending()
            launcherLaneFailed = false
            seedLauncherDemo()
        case .curtain:
            relocationsStillPending = context.relocationsPending()
            openAtLogin = context.isOpenAtLogin()
        default:
            break
        }
    }

    /// The curtain's Open-at-Login switch: flip via the context, then re-read the registration
    /// into the snapshot (registration can fail, e.g. outside /Applications — the switch shows
    /// the truth, not the wish).
    func toggleOpenAtLogin() {
        context.toggleOpenAtLogin()
        openAtLogin = context.isOpenAtLogin()
    }

    private func enterStage(_ stage: FirstRunStage) {
        // The demo trio keeps the strip alive under the hand; the playground reads the same feed
        // for its four-finger drive; every other act releases it.
        if Self.demoStages.contains(stage) || stage == .playground {
            context.subscribeTouch { [weak self] frame in self?.handleTouch(frame) }
        } else {
            context.unsubscribeTouch()
        }
        if Self.demoStages.contains(stage) {
            startAttract()
        } else {
            stopAttract()
            fingerDots = []
        }
        switch stage {
        case .overture:
            // The brand moment points at where the app lives: the actual menu-bar mark pulses
            // in sync with the overture's halo.
            context.pulseMenuBarMark()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.stage == .overture else { return }
                self.advance()
            }
            overtureAdvance = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
        case .permAX:
            // Already granted at entry (resume/replay): the act states its done state for a
            // beat, then flows on — grants never ask for a second click. (Checked before the
            // poll starts; the poll's sink covers any later flip.)
            if context.permissions.accessibility == .granted {
                scheduleGrantAdvance(after: grantBeats.ax)
            }
            context.permissions.startPolling()
            refreshDemoForPermissions()
        case .permSR:
            if context.permissions.screenRecording == .granted {
                scheduleGrantAdvance(after: grantBeats.sr)   // the reveal beat: faces stream in
            }
            context.permissions.startPolling()
            refreshDemoForPermissions()
        case .curtain:
            // "The app lives in your menu bar" — show, don't tell: the mark pulses as the
            // curtain says it.
            context.pulseMenuBarMark()
        default:
            break
        }
    }

    private func leaveCurrentStage() {
        switch stage {
        case .overture:
            overtureAdvance?.cancel()
            overtureAdvance = nil
        case .permAX, .permSR:
            context.permissions.stopPolling()
            grantAdvance?.cancel()
            grantAdvance = nil
        case .playground:
            tourDwell.cancel()
            tourPlayActive = false
            tourTouchAnchor = nil
        default:
            break
        }
    }

    /// One grant → one motion: the permission act advances itself after `delay`, unless the act
    /// changes first (skip, window close). Re-scheduling replaces the pending advance.
    private func scheduleGrantAdvance(after delay: TimeInterval) {
        grantAdvance?.cancel()
        let expected = stage
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stage == expected else { return }
            self.advance()
        }
        grantAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Wizard teardown (window closing): release timers and the touch feed. Progress is already
    /// persisted — closing mid-flow is "later", and the next launch resumes here.
    func suspend() {
        leaveCurrentStage()
        stopAttract()
        context.unsubscribeTouch()
        fingerDots = []
        tourDwell.cancel()
    }

    // MARK: - Act I: the demo strip

    /// The canvas the demo grid solves into — sized to the wizard's demo strip (the `SwitcherView` is
    /// framed at ~`panelHeight * 0.85`, minus the grid's padding/title chrome) so the sample windows
    /// land as one clean row rather than wrapping or clipping.
    nonisolated static let demoCanvas = CGSize(width: 820, height: 108)

    /// Stylized sample "windows" — art, not fake apps — so the strip is alive before any permission.
    private func seedSampleDemo() {
        let cards: [(String, NSColor, NSColor)] = [
            ("Canvas", NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.91, alpha: 1), NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)),
            ("Notes", NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.25, alpha: 1), NSColor(calibratedRed: 0.93, green: 0.35, blue: 0.42, alpha: 1)),
            ("Music", NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.55, alpha: 1), NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.60, alpha: 1)),
            ("Mail", NSColor(calibratedRed: 0.60, green: 0.40, blue: 0.86, alpha: 1), NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.75, alpha: 1))
        ]
        let windows = cards.enumerated().map { index, card in
            WindowInfo(id: CGWindowID(910_000 + index), pid: 0, appName: card.0, title: card.0,
                       appIcon: nil, frame: .zero, axElement: nil,
                       isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
        }
        demo.setCanvas(Self.demoCanvas)   // size the grid solve to the wizard's demo strip
        demo.setRows([windows], labels: ["1"], startRow: 0, column: 1)
        for (index, card) in cards.enumerated() {
            demo.setThumbnail(Self.gradientArt(from: card.1, to: card.2), for: CGWindowID(910_000 + index))
        }
    }

    /// Post-Accessibility: the same strip, now made of the user's actual windows.
    private func refreshDemoForPermissions() {
        if context.permissions.accessibility == .granted, !demoShowsRealWindows {
            upgradeDemoToRealWindows()
        }
        if context.permissions.screenRecording == .granted, demoShowsRealWindows {
            context.seedThumbnails(demo)
            pulseThumbnailRevealOnce()
        }
    }

    func upgradeDemoToRealWindows() {
        let rows = context.realWindowRows()
        guard let row = rows.first, !row.isEmpty else { return }
        demoShowsRealWindows = true
        sceneUpgradePulse += 1   // the light sweep rides the cards' transformation
        demo.setCanvas(Self.demoCanvas)   // keep the grid solve sized to the wizard's demo strip
        withAnimation(.easeInOut(duration: 0.32)) {
            demo.setRows([Array(row.prefix(4))], labels: ["1"], startRow: 0,
                         column: min(1, max(0, row.count - 1)))
        }
        if context.permissions.screenRecording == .granted {
            context.seedThumbnails(demo)
            pulseThumbnailRevealOnce()
        }
    }

    /// The faces-arrived sweep: thumbnails stream into the strip asynchronously, so the sweep
    /// plays once, a beat after the first seed — washing over cards as their faces land.
    private func pulseThumbnailRevealOnce() {
        guard !thumbnailRevealPulsed else { return }
        thumbnailRevealPulsed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, Self.demoStages.contains(self.stage) else { return }
            self.sceneUpgradePulse += 1
        }
    }

    private func observePermissionUpgrades() {
        context.permissions.$accessibility
            .removeDuplicates()
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, status == .granted,
                          self.stage == .permAX || self.stage == .permSR else { return }
                    self.upgradeDemoToRealWindows()
                    // The grant is the click: the act seals, the scene transforms, and after the
                    // beat the wizard flows to the next ask on its own.
                    if self.stage == .permAX { self.scheduleGrantAdvance(after: self.grantBeats.ax) }
                }
            }
            .store(in: &cancellables)
        context.permissions.$screenRecording
            .removeDuplicates()
            .sink { [weak self] status in
                MainActor.assumeIsolated {
                    guard let self, status == .granted else { return }
                    if self.demoShowsRealWindows {
                        self.context.seedThumbnails(self.demo)
                        self.pulseThumbnailRevealOnce()
                    }
                    if self.stage == .permSR { self.scheduleGrantAdvance(after: self.grantBeats.sr) }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Act I: attract loop → live hand

    /// The strip plays itself until real fingers arrive — no waiting state, no timeout. The loop
    /// is a ghost hand: three faint fingertips sweep the trackpad pad continuously, and the strip's
    /// highlight follows the SAME centroid→column mapping the user's real fingers will use — pad
    /// and strip move as one body, demonstrating the exact gesture they invite.
    private func startAttract() {
        guard attractTimer == nil, !liveTouchActive else { return }
        attractTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in self.attractTick() }
        }
    }

    private func stopAttract() {
        attractTimer?.invalidate()
        attractTimer = nil
        ghostDots = []
    }

    private func attractTick() {
        guard !liveTouchActive else { return }
        attractPhase += Self.attractPhaseStep
        let pose = Self.attractPose(phase: attractPhase)
        ghostDots = pose.dots
        let count = demo.windows.count
        guard count > 1 else { return }
        let column = min(count - 1, max(0, Int(pose.centroid.x * CGFloat(count))))
        if column != demo.selectedIndex { demo.setColumn(column) }
    }

    /// One full pad sweep ≈ 6.5 s at the 30 Hz tick — unhurried, self-evidently alive.
    nonisolated static let attractPhaseStep = (2 * Double.pi) / (6.5 * 30)

    /// One ghost-hand pose: a three-fingertip arc whose centroid ping-pongs across the trackpad
    /// (normalized 0..1 coordinates), each fingertip carrying a faint organic wobble so the hand
    /// reads as a hand, not a cursor. Pure — unit-tested for bounds and shape.
    nonisolated static func attractPose(phase: Double) -> (centroid: CGPoint, dots: [CGPoint]) {
        let x = 0.5 + 0.40 * sin(phase)
        let y = 0.42 + 0.05 * sin(phase * 0.63)
        let offsets: [(CGFloat, CGFloat)] = [(-0.16, 0.10), (0, 0.17), (0.16, 0.10)]
        let dots = offsets.enumerated().map { index, offset in
            CGPoint(x: min(0.95, max(0.05, x + offset.0 + 0.012 * sin(phase * 1.7 + Double(index)))),
                    y: min(0.95, max(0.05, y + offset.1 + 0.012 * cos(phase * 1.3 + Double(index)))))
        }
        return (CGPoint(x: x, y: y), dots)
    }

    private func handleTouch(_ frame: TouchFrame) {
        if Self.demoStages.contains(stage) {
            handleDemoTouch(frame)
        } else if stage == .playground {
            handleTourTouch(frame)
        }
    }

    private func handleDemoTouch(_ frame: TouchFrame) {
        if frame.fingerCount >= 3 {
            if !liveTouchActive {
                liveTouchActive = true     // the script yields to the hand
                stopAttract()
                sceneUpgradePulse += 1     // the takeover sweep: the scene salutes its new driver
                DwellArmDriver.hapticTick()
            }
            liftedWithoutScrub = false     // the hand is back — the quiet fallback stands down
            fingerDots = frame.contacts.map { CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y)) }
            // Absolute mapping: the hand's place on the trackpad IS the place in the strip.
            let count = demo.windows.count
            guard count > 0 else { return }
            let column = min(count - 1, max(0, Int(frame.centroid.x * CGFloat(count))))
            if column != demo.selectedIndex {
                scrubbedDuringLiveTouch = true
                demo.setColumn(column)
            }
        } else if frame.fingerCount == 0 {
            fingerDots = []
            // The hand act's completion gesture IS the product's: scrub, then lift. The lift
            // advances — the user is already on the permission act while their fingers rise
            // (the strip stays live under them there). A lift that never scrubbed re-offers a
            // quiet manual way forward instead.
            if stage == .hand, liveTouchActive {
                if scrubbedDuringLiveTouch {
                    advance()
                } else {
                    liftedWithoutScrub = true
                }
            }
        }
    }

    // The playground's four-finger drive: until the lanes are effective the recognizer can't
    // deliver launcher intents, so the raw touch feed does — four fingers down morphs the demo to
    // full size and drives it with the same step/dwell/lift contract; the lift morphs it back
    // (and never fires anything). Once the lanes ARE live the recognizer takes over (it forwards
    // real intents through `launcherTour*`) and this path stands down.
    private func handleTourTouch(_ frame: TouchFrame) {
        guard !launcherTourLive else { return }
        if frame.fingerCount >= 4 {
            guard let anchor = tourTouchAnchor else {
                tourTouchAnchor = frame.centroid
                tourPlayActive = true
                launcherTourActivate()
                return
            }
            let dx = frame.centroid.x - anchor.x
            let dy = frame.centroid.y - anchor.y
            if abs(dx) >= Self.tourStepX {
                launcherTourStepItem(dx > 0 ? 1 : -1)
                tourTouchAnchor?.x = frame.centroid.x
            }
            if abs(dy) >= Self.tourStepY {
                launcherTourStepContext(dy > 0 ? 1 : -1)
                tourTouchAnchor?.y = frame.centroid.y
            }
        } else if frame.fingerCount == 0, tourPlayActive {
            tourPlayActive = false
            tourTouchAnchor = nil
            launcherTourEnd()              // armed lift completes the contract; never fires
        }
        // 1–3 fingers: a re-grip mid-play — keep the session, wait for the hand to settle.
    }

    // MARK: - Act II: the relaunch edge

    /// Persist the relaunch stage FIRST, then quit-and-reopen — the fresh process resumes on the
    /// Screen Recording act with live thumbnails as the reveal.
    func relaunchNow() {
        store.stage = .awaitingRelaunch
        context.relaunchNow()
    }

    // MARK: - Act III: the lanes

    func applyLanes() {
        lanesOutcome = context.applyLanes(lanes)
        if context.relocationsPending() {
            transition(to: .awaitingRelogin)
        } else {
            transition(to: .playground)
        }
    }

    func skipLanes() {
        lanesOutcome = nil
        transition(to: .playground)
    }

    func logOutNow() {
        store.stage = .awaitingRelogin   // survive the logout; the next login resumes past it
        context.logOutNow()
    }

    // MARK: - Act IV: the playground

    /// Seed (or re-seed) the tour from the context's band composition. Toggle parameters carry the
    /// EMITTED values from the optional-feature switches — `@Published` fires on willSet, so a
    /// property re-read in those observers would still see the old value.
    private func seedLauncherDemo(clipboardOn: Bool? = nil, aiOn: Bool? = nil) {
        let clipboard = clipboardOn ?? context.settings.keepClipboardHistory
        let ai = aiOn ?? context.settings.aiCommandsEnabled
        let bands = context.launcherBands(clipboard, ai)
        guard !bands.isEmpty else { return }
        launcherDemo.dwell = context.settings.dwellToArmDuration
        launcherDemo.setBands(bands.map(\.items),
                              names: bands.map(\.name),
                              colors: bands.map(\.color),
                              icons: bands.map(\.resolvedIcon),
                              startBand: 0,
                              column: 0,
                              clipboardBandIndex: bands.firstIndex(where: ClipboardBandBuilder.isClipboardBand))
    }

    /// Re-seed the tour live when the optional-feature toggles change on the playground act, so
    /// flipping Clipboard / AI immediately shows (or removes) the band it controls.
    private func observeTourToggles() {
        context.settings.$keepClipboardHistory
            .dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self, self.stage == .playground else { return }
                    // Animated: the band a toggle controls slides into (or out of) the tour.
                    withAnimation(.easeInOut(duration: 0.3)) { self.seedLauncherDemo(clipboardOn: on) }
                }
            }
            .store(in: &cancellables)
        context.settings.$aiCommandsEnabled
            .dropFirst()
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self, self.stage == .playground else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { self.seedLauncherDemo(aiOn: on) }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Act IV: the launcher lane toggle

    /// The playground's own claim on the four-finger lanes — for the user who opted out on the
    /// lanes act and changed their mind here, mid-play. ON applies the launcher relocation (same
    /// unified path, pristine backups, one re-login); OFF quietly restores the backed-up setting.
    /// Event-time only (the toggle's set side) — the context closures spawn processes.
    func setLauncherLane(_ on: Bool) {
        if on {
            let outcome = context.applyLanes(LaneChoices(spaceRows: false, launcher: true, fixedSpaces: false))
            launcherLaneFailed = outcome.failed.contains(.launcher)
        } else {
            context.restoreLauncherLane()
            launcherLaneFailed = false
        }
        launcherTourLive = context.launcherLive()
        launcherLanePending = context.relocationsPending()
    }

    // MARK: - Act IV: the live launcher tour

    // When the four-finger lanes are already effective (a post-re-login resume, or a replay on a
    // configured machine), the recognizer's REAL launcher intents are forwarded here by the
    // coordinator — the embedded demo responds to the user's actual four-finger gestures, with the
    // product's own dwell/arm semantics (the shared driver). Lift never fires an item: the tour
    // teaches the contract; the real launcher takes over the moment the wizard closes.

    func launcherTourActivate() {
        guard stage == .playground else { return }
        tourPlayActive = true     // the morph: the demo grows to full size under the hand
        manageTourDwell()
    }

    func launcherTourStepItem(_ direction: Int) {
        guard stage == .playground else { return }
        launcherDemo.stepHorizontal(direction)
        manageTourDwell()
    }

    func launcherTourStepContext(_ direction: Int) {
        guard stage == .playground else { return }
        launcherDemo.stepVertical(direction)
        manageTourDwell()
    }

    /// Mirrors `LauncherOverlayController.focusIsOnBandList` so the recognizer applies the coarse
    /// band-step on the band list and the fine item-step in the grid — identical feel to the product.
    var launcherTourFocusOnBandList: Bool {
        stage == .playground && launcherDemo.focus == .bands
    }

    func launcherTourEnd() {
        tourDwell.cancel()
        guard stage == .playground else { return }
        tourPlayActive = false    // the lift: the launcher settles back into its demo slot
        if launcherDemo.armed {
            // The full contract — slide, dwell-arm, lift — completed on a real item: the act's
            // hold-button converts to a plain Continue so finishing the stage is obvious.
            tourCompleted = true
        }
        launcherDemo.disarm()   // the lift: reset the charge — the tour never fires the item
    }

    /// The controller's manageDwell, verbatim semantics: charge on a grid item, disarm elsewhere.
    private func manageTourDwell() {
        tourDwell.cancel()
        if launcherDemo.focus == .grid, launcherDemo.selectedItem != nil {
            launcherDemo.beginArming()
            tourDwell.charge(after: launcherDemo.dwell) { [weak self] in
                guard let self, self.launcherDemo.arming else { return }
                self.launcherDemo.setArmed()
                DwellArmDriver.hapticTick()
            }
        } else {
            launcherDemo.disarm()
        }
    }

    // MARK: - Act V: the curtain

    func finish() {
        leaveCurrentStage()
        stage = .completed
        context.finish()   // records completion (+ legacy flags) and closes the window
    }

    // MARK: - Demo art

    /// A soft diagonal gradient "window" — deliberately abstract (art, not a fake screenshot).
    private static func gradientArt(from: NSColor, to: NSColor) -> NSImage {
        let size = NSSize(width: 400, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: from, ending: to)?
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 230, width: 200, height: 26), xRadius: 13, yRadius: 13).fill()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 40, width: 356, height: 170), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        return image
    }
}
