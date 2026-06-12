import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `FirstTouchWizardModel`'s seeding/teardown logic (Onboarding/FirstTouchWizardModel.swift).
/// Regression coverage for the playground act rendering empty: the launcher demo must be seeded from
/// the context's bands whenever the playground stage is entered (directly via resume, or by advancing),
/// and the tour drivers must respect the stage gate.
@MainActor
final class FirstTouchWizardModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: FirstRunStore!
    private var context: WizardContext!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.FirstTouchWizardModel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
        store = FirstRunStore(defaults: defaults)
        let settings = AppSettings(defaults: defaults)
        settings.keepClipboardHistory = false
        settings.aiCommandsEnabled = false
        context = WizardContext(settings: settings, permissions: PermissionsService())
        context.launcherBands = { clipboardOn, _ in
            var bands = [ContextBand(name: "Work", color: ItemColor(red: 0, green: 0, blue: 1),
                                     items: [LaunchItem(title: "Thing", icon: .sfSymbol("star"),
                                                        kind: .url(URL(string: "https://example.com")!))])]
            if clipboardOn {
                bands.append(ClipboardBandBuilder.build(from: WizardSampleContent.clipboardEntries()))
            }
            return bands
        }
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testResumeDirectlyIntoPlaygroundSeedsTheLauncherDemo() {
        store.stage = .playground   // mid-flow quit persisted here; the next launch resumes in place
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertEqual(model.stage, .playground)
        XCTAssertEqual(model.launcherDemo.bandCount, 1, "the tour must show the user's bands on resume")
        XCTAssertFalse(model.launcherDemo.items.isEmpty)
    }

    func testAdvancingIntoPlaygroundSeedsTheLauncherDemo() {
        store.stage = .lanes
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.skipLanes()           // lanes → playground
        XCTAssertEqual(model.stage, .playground)
        XCTAssertEqual(model.launcherDemo.bandCount, 1)
    }

    func testEmptyBandsLeaveTheDemoEmptyWithoutError() {
        context.launcherBands = { _, _ in [] }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertEqual(model.launcherDemo.bandCount, 0, "no bands → the act's fallback copy, no crash")
    }

    func testTogglingClipboardOnThePlaygroundReseedsTheTour() {
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertEqual(model.launcherDemo.bandCount, 1)
        context.settings.keepClipboardHistory = true   // the optional-feature card's switch
        XCTAssertEqual(model.launcherDemo.bandCount, 2, "the Clipboard band appears live, with example content")
        context.settings.keepClipboardHistory = false
        XCTAssertEqual(model.launcherDemo.bandCount, 1, "and disappears when toggled back off")
    }

    func testToggleOutsideThePlaygroundDoesNotReseed() {
        store.stage = .hand
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        context.settings.keepClipboardHistory = true
        XCTAssertEqual(model.launcherDemo.bandCount, 0, "the tour seeds only on (or re-seeds during) the playground")
    }

    func testSampleClipboardEntriesAreWellFormed() {
        let entries = WizardSampleContent.clipboardEntries()
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertFalse(entry.key.isEmpty)
            XCTAssertFalse(entry.representations.isEmpty, "each example must be previewable")
        }
    }

    func testCompletingTheGestureContractMarksTheTourComplete() {
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertFalse(model.tourCompleted)
        // Slide to an item, dwell-arm (simulated — the driver's timer is real time), then lift.
        model.launcherTourStepItem(1)
        model.launcherDemo.setArmed()
        model.launcherTourEnd()
        XCTAssertTrue(model.tourCompleted, "an armed lift completes the contract → the button converts to Continue")
        XCTAssertFalse(model.launcherDemo.armed, "the lift still resets the charge")
    }

    func testLauncherTourIgnoresIntentsOutsideThePlayground() {
        store.stage = .hand
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.launcherTourStepItem(1)
        model.launcherTourStepContext(1)
        XCTAssertFalse(model.launcherTourFocusOnBandList)
        XCTAssertFalse(model.launcherDemo.arming, "tour intents are inert outside the playground act")
    }

    // MARK: - Auto-continue: the hand act completes by gesture (scrub, then lift)

    private func resumeWithTouchFeed(at stage: FirstRunStage) -> (FirstTouchWizardModel, (TouchFrame) -> Void) {
        var handler: ((TouchFrame) -> Void)?
        context.subscribeTouch = { handler = $0 }
        store.stage = stage
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        guard let handler else {
            XCTFail("the stage must subscribe to the touch feed")
            return (model, { _ in })
        }
        return (model, handler)
    }

    func testHandLiftAfterScrubAdvancesWithoutAButton() {
        let (model, touch) = resumeWithTouchFeed(at: .hand)
        // Three fingers land away from the current column (the sample demo starts on column 1)…
        touch(TouchFrame(testFingerCount: 3, centroid: CGPoint(x: 0.9, y: 0.5)))
        XCTAssertTrue(model.liveTouchActive)
        // …and the lift IS the continue: the wizard is already on the Accessibility act.
        touch(TouchFrame(testFingerCount: 0, centroid: .zero))
        XCTAssertEqual(model.stage, .permAX, "scrub + lift advances by itself")
    }

    func testHandLiftWithoutScrubStaysAndOffersAQuietWayForward() {
        let (model, touch) = resumeWithTouchFeed(at: .hand)
        // Fingers land exactly on the current column (1 of 4 → centroid x 0.3) and never move.
        touch(TouchFrame(testFingerCount: 3, centroid: CGPoint(x: 0.3, y: 0.5)))
        touch(TouchFrame(testFingerCount: 0, centroid: .zero))
        XCTAssertEqual(model.stage, .hand, "a lift that never scrubbed must not advance")
        XCTAssertTrue(model.liftedWithoutScrub, "…but the act re-offers a manual continue")
        // The hand returns and scrubs: the fallback stands down, the next lift advances.
        touch(TouchFrame(testFingerCount: 3, centroid: CGPoint(x: 0.9, y: 0.5)))
        XCTAssertFalse(model.liftedWithoutScrub)
        touch(TouchFrame(testFingerCount: 0, centroid: .zero))
        XCTAssertEqual(model.stage, .permAX)
    }

    // MARK: - Auto-continue: a grant is the click

    func testGrantedAccessibilityAtEntryFlowsOnAfterTheBeat() {
        store.stage = .permAX
        context.permissions.accessibility = .granted
        let model = FirstTouchWizardModel(context: context, store: store)
        model.grantBeats = (ax: 0.05, sr: 0.05)
        model.resume()
        XCTAssertEqual(model.stage, .permAX, "the done state shows for its beat first")
        let beat = expectation(description: "grant beat")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { beat.fulfill() }
        wait(for: [beat], timeout: 2)
        // The poll re-reads REAL TCC state in the test process, so the exact landing stage can
        // drift one act further on a host with grants — the pinned behavior is "flowed on".
        XCTAssertNotEqual(model.stage, .permAX, "the grant advances the act by itself")
    }

    func testGrantDetectedWhileWatchingFlowsOn() {
        store.stage = .permSR
        let model = FirstTouchWizardModel(context: context, store: store)
        model.grantBeats = (ax: 0.05, sr: 0.05)
        model.resume()
        XCTAssertEqual(model.stage, .permSR)
        context.permissions.screenRecording = .granted   // the poll detects the grant
        let beat = expectation(description: "grant beat")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { beat.fulfill() }
        wait(for: [beat], timeout: 2)
        XCTAssertEqual(model.stage, .lanes)
    }

    // MARK: - The lanes default on

    func testLaneChoicesDefaultToEverythingOn() {
        let choices = LaneChoices()
        XCTAssertTrue(choices.spaceRows)
        XCTAssertTrue(choices.launcher)
        XCTAssertTrue(choices.fixedSpaces)
    }

    // MARK: - The playground's four-finger drive

    func testFourFingerTouchMorphsAndDrivesTheTour() {
        let (model, touch) = resumeWithTouchFeed(at: .playground)
        XCTAssertFalse(model.tourPlayActive)
        touch(TouchFrame(testFingerCount: 4, centroid: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(model.tourPlayActive, "four fingers down → the demo morphs to full size")
        XCTAssertTrue(model.launcherDemo.arming, "activation begins the dwell on the selected item")
        // Slide, arm (simulated — the dwell timer is real time), lift.
        touch(TouchFrame(testFingerCount: 4, centroid: CGPoint(x: 0.62, y: 0.5)))
        model.launcherDemo.setArmed()
        touch(TouchFrame(testFingerCount: 0, centroid: .zero))
        XCTAssertFalse(model.tourPlayActive, "the lift settles the launcher back into its slot")
        XCTAssertTrue(model.tourCompleted, "an armed lift completes the contract")
        XCTAssertFalse(model.launcherDemo.armed, "and never fires the item")
    }

    func testRawTouchStandsDownWhenTheLanesAreLive() {
        context.launcherLive = { true }   // the recognizer forwards real intents instead
        let (model, touch) = resumeWithTouchFeed(at: .playground)
        touch(TouchFrame(testFingerCount: 4, centroid: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(model.tourPlayActive, "no double-driving: live lanes are the recognizer's")
    }

    // MARK: - The playground's launcher-lane toggle

    func testSetLauncherLaneClaimsViaTheUnifiedApply() {
        var applied: LaneChoices?
        context.applyLanes = { choices in
            applied = choices
            return LanesApplyOutcome(failed: [], appliedAny: true)
        }
        context.relocationsPending = { true }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.setLauncherLane(true)
        XCTAssertEqual(applied, LaneChoices(spaceRows: false, launcher: true, fixedSpaces: false))
        XCTAssertTrue(model.launcherLanePending)
        XCTAssertFalse(model.launcherLaneFailed)
    }

    func testSetLauncherLaneOffRestoresQuietly() {
        var restored = false
        context.restoreLauncherLane = { restored = true }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.setLauncherLane(false)
        XCTAssertTrue(restored)
        XCTAssertFalse(model.launcherLaneFailed)
    }

    func testSetLauncherLaneSurfacesAManagedMacFailure() {
        context.applyLanes = { _ in LanesApplyOutcome(failed: .launcher, appliedAny: false) }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.setLauncherLane(true)
        XCTAssertTrue(model.launcherLaneFailed, "the write failure is state the row can show")
    }

    // MARK: - Attract choreography (the ghost hand)

    func testAttractPoseStaysInBoundsAndKeepsThreeFingertips() {
        // The ghost hand must never leave the pad: sweep several full cycles and check every pose.
        var phase = 0.0
        while phase < 8 * Double.pi {
            let pose = FirstTouchWizardModel.attractPose(phase: phase)
            XCTAssertEqual(pose.dots.count, 3, "the ghost hand is three fingertips")
            for dot in pose.dots {
                XCTAssertTrue((0.0...1.0).contains(dot.x), "dot x out of pad bounds at phase \(phase)")
                XCTAssertTrue((0.0...1.0).contains(dot.y), "dot y out of pad bounds at phase \(phase)")
            }
            XCTAssertTrue((0.05...0.95).contains(pose.centroid.x),
                          "the centroid sweep must stay clear of the pad edges")
            phase += FirstTouchWizardModel.attractPhaseStep
        }
    }

    func testAttractPoseCentroidActuallySweepsTheStrip() {
        // The centroid→column mapping must reach both ends of a 4-card strip across one cycle.
        var columns: Set<Int> = []
        var phase = 0.0
        while phase < 2 * Double.pi {
            let pose = FirstTouchWizardModel.attractPose(phase: phase)
            columns.insert(min(3, max(0, Int(pose.centroid.x * 4))))
            phase += FirstTouchWizardModel.attractPhaseStep
        }
        XCTAssertEqual(columns, [0, 1, 2, 3], "the ghost hand demonstrates the full scrub")
    }

    // MARK: - Live-state snapshots (body safety)

    // The acts must render from published snapshots, never by invoking the context's
    // gesture-state closures in body — those spawn /usr/bin/defaults and pump a nested run loop,
    // which segfaults inside a SwiftUI render (the permSR→lanes blank-screen crash). These tests
    // pin that every snapshot is taken when its act is entered.

    func testEnteringLanesSnapshotsTheGestureState() {
        context.trackpadClaimed = { true }
        context.spacesAutoRearrangeOn = { true }
        store.stage = .permSR
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertFalse(model.lanesTrackpadClaimed, "snapshots are taken on stage entry, not before")
        model.advance()   // permSR → lanes
        XCTAssertTrue(model.lanesTrackpadClaimed)
        XCTAssertTrue(model.lanesSpacesChoiceAvailable)
        XCTAssertTrue(model.lanes.fixedSpaces, "the offerable fixed-Spaces choice defaults on")
    }

    func testEnteringPlaygroundSnapshotsLauncherLiveness() {
        context.launcherLive = { true }
        store.stage = .lanes
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertFalse(model.launcherTourLive)
        model.skipLanes()   // lanes → playground
        XCTAssertTrue(model.launcherTourLive)
    }

    func testEnteringCurtainSnapshotsPendingAndLoginState() {
        context.relocationsPending = { true }
        context.isOpenAtLogin = { true }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.advance()   // playground → curtain
        XCTAssertTrue(model.relocationsStillPending)
        XCTAssertTrue(model.openAtLogin)
    }

    func testToggleOpenAtLoginReReadsTheRegistration() {
        var registered = false
        context.isOpenAtLogin = { registered }
        context.toggleOpenAtLogin = { registered.toggle() }
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.advance()   // → curtain (snapshot: false)
        XCTAssertFalse(model.openAtLogin)
        model.toggleOpenAtLogin()
        XCTAssertTrue(model.openAtLogin, "the switch shows the re-read truth, not the wish")
    }

    // MARK: - Scene transformation pulses

    func testUpgradeToRealWindowsBumpsTheScenePulse() {
        context.realWindowRows = {
            [[WindowInfo(id: 1, pid: 0, appName: "Real", title: "Real", appIcon: nil, frame: .zero,
                         axElement: nil, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)]]
        }
        store.stage = .permAX
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        XCTAssertEqual(model.sceneUpgradePulse, 0)
        model.upgradeDemoToRealWindows()
        XCTAssertTrue(model.demoShowsRealWindows)
        XCTAssertEqual(model.sceneUpgradePulse, 1, "the upgrade announces itself — the view sweeps on the bump")
    }

    func testUpgradeWithoutWindowsNeitherFlipsNorPulses() {
        context.realWindowRows = { [] }
        store.stage = .permAX
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        model.upgradeDemoToRealWindows()
        XCTAssertFalse(model.demoShowsRealWindows, "no real windows → the sample scene stays")
        XCTAssertEqual(model.sceneUpgradePulse, 0)
    }

    func testLauncherTourLiftResetsTheChargeAndNeverArmsWithoutDwell() {
        store.stage = .playground
        let model = FirstTouchWizardModel(context: context, store: store)
        model.resume()
        // A single band lands focus on the grid with an item selected → a step begins the charge.
        model.launcherTourStepItem(1)
        XCTAssertTrue(model.launcherDemo.arming)
        XCTAssertFalse(model.launcherDemo.armed, "arming starts the charge; only the dwell arms it")
        model.launcherTourEnd()
        XCTAssertFalse(model.launcherDemo.arming)
        XCTAssertFalse(model.launcherDemo.armed, "the lift resets — the tour never fires")
    }
}
