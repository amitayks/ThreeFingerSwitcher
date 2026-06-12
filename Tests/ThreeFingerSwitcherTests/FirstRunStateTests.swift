import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the First Touch wizard's state machine (Onboarding/FirstRunState.swift):
/// the pure transitions (including the two restart edges the flow choreographs), the resume
/// mapping, existing-install migration, completion/legacy-flag semantics, and the one-time
/// lanes-are-live acknowledgment.
final class FirstRunStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: FirstRunStore!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.FirstRunState.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
        store = FirstRunStore(defaults: defaults)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Linear act order

    func testLinearAdvance() {
        XCTAssertEqual(FirstRunMachine.next(after: .fresh), .overture)
        XCTAssertEqual(FirstRunMachine.next(after: .overture), .hand)
        XCTAssertEqual(FirstRunMachine.next(after: .hand), .permAX)
        XCTAssertEqual(FirstRunMachine.next(after: .permAX), .permSR)
        XCTAssertEqual(FirstRunMachine.next(after: .permSR), .lanes)
        XCTAssertEqual(FirstRunMachine.next(after: .lanes), .playground,
                       "no relocation applied → the re-login moment is skipped")
        XCTAssertEqual(FirstRunMachine.next(after: .playground), .curtain)
        XCTAssertEqual(FirstRunMachine.next(after: .curtain), .completed)
        XCTAssertEqual(FirstRunMachine.next(after: .completed), .completed)
    }

    func testRestartStagesContinueToLanesAndPlayground() {
        XCTAssertEqual(FirstRunMachine.next(after: .awaitingRelaunch), .lanes)
        XCTAssertEqual(FirstRunMachine.next(after: .awaitingRelogin), .playground)
    }

    // MARK: - Resume mapping (the precision Raycast gets right)

    func testFreshResumesAtOverture() {
        XCTAssertEqual(FirstRunMachine.resumeStage(persisted: .fresh, relocationsStillPending: false), .overture)
    }

    func testMidFlowQuitResumesAtTheSameAct() {
        for stage in [FirstRunStage.overture, .hand, .permAX, .permSR, .lanes, .playground, .curtain] {
            XCTAssertEqual(FirstRunMachine.resumeStage(persisted: stage, relocationsStillPending: false), stage,
                           "closing mid-flow is 'later': \(stage) resumes in place")
        }
    }

    func testRelaunchResumesOnTheScreenRecordingActForTheReveal() {
        XCTAssertEqual(FirstRunMachine.resumeStage(persisted: .awaitingRelaunch, relocationsStillPending: false),
                       .permSR)
    }

    func testAwaitingReloginHoldsWhileStillPending() {
        // The user chose "Log out now" but only relaunched the app — the markers still read
        // pending (same login session), so the wizard resumes on the re-login step, honestly.
        XCTAssertEqual(FirstRunMachine.resumeStage(persisted: .awaitingRelogin, relocationsStillPending: true),
                       .awaitingRelogin)
    }

    func testRealReloginRollsForwardToThePlayground() {
        XCTAssertEqual(FirstRunMachine.resumeStage(persisted: .awaitingRelogin, relocationsStillPending: false),
                       .playground)
    }

    // MARK: - Show-at-launch + migration

    func testShownForEveryIncompleteStage() {
        for stage in FirstRunStage.allCases where stage != .completed {
            XCTAssertTrue(FirstRunMachine.shouldShowAtLaunch(stage: stage))
        }
        XCTAssertFalse(FirstRunMachine.shouldShowAtLaunch(stage: .completed))
    }

    func testExistingInstallWithLegacyFlagMigratesSilently() {
        XCTAssertEqual(FirstRunMachine.migratedStage(current: .fresh,
                                                     anyLegacyPromptFlag: true,
                                                     allRequiredPermissionsGranted: false), .completed)
    }

    func testExistingInstallWithPermissionsMigratesSilently() {
        XCTAssertEqual(FirstRunMachine.migratedStage(current: .fresh,
                                                     anyLegacyPromptFlag: false,
                                                     allRequiredPermissionsGranted: true), .completed)
    }

    func testTrulyFreshInstallIsNotMigrated() {
        XCTAssertEqual(FirstRunMachine.migratedStage(current: .fresh,
                                                     anyLegacyPromptFlag: false,
                                                     allRequiredPermissionsGranted: false), .fresh)
    }

    func testMidFlowProgressIsNeverMigratedAway() {
        // Granting permissions IS wizard progress — it must not skip the remaining acts.
        XCTAssertEqual(FirstRunMachine.migratedStage(current: .lanes,
                                                     anyLegacyPromptFlag: false,
                                                     allRequiredPermissionsGranted: true), .lanes)
    }

    // MARK: - AX first-contact gate

    func testMidGesturePromptSuppressedUntilCompleted() {
        XCTAssertFalse(FirstRunMachine.shouldPromptAccessibilityOnCommit(firstRunCompleted: false))
        XCTAssertTrue(FirstRunMachine.shouldPromptAccessibilityOnCommit(firstRunCompleted: true))
    }

    // MARK: - Store persistence

    func testStageDefaultsToFreshAndPersists() {
        XCTAssertEqual(store.stage, .fresh)
        store.stage = .permSR
        XCTAssertEqual(FirstRunStore(defaults: defaults).stage, .permSR, "a relaunch reads the same stage")
    }

    func testCompleteSetsAllLegacyFlags() {
        store.complete(relocationsStillPending: false)
        XCTAssertTrue(store.isCompleted)
        for key in FirstRunStore.legacyPromptKeys {
            XCTAssertTrue(defaults.bool(forKey: key), "\(key) must be set so the retired alerts can never fire")
        }
    }

    func testMigrationSetsStageAndLegacyFlags() {
        defaults.set(true, forKey: "didPromptLauncher")   // an existing install
        store.migrateExistingInstallIfNeeded(allRequiredPermissionsGranted: false)
        XCTAssertTrue(store.isCompleted)
        XCTAssertTrue(defaults.bool(forKey: "didPromptNativeGesture"))
    }

    func testMigrationLeavesFreshInstallAlone() {
        store.migrateExistingInstallIfNeeded(allRequiredPermissionsGranted: false)
        XCTAssertEqual(store.stage, .fresh)
        XCTAssertFalse(defaults.bool(forKey: "didPromptNativeGesture"))
    }

    func testReplayRunsFromTheTop() {
        store.complete(relocationsStillPending: false)
        store.beginReplay()
        XCTAssertEqual(store.stage, .overture)
        XCTAssertFalse(store.isCompleted)
    }

    // MARK: - Lanes-are-live acknowledgment (completed with "Later")

    func testAcknowledgmentFiresOnceAfterTheRealRelogin() {
        store.complete(relocationsStillPending: true)
        // Same session (markers still pending): not yet.
        XCTAssertFalse(store.consumeLanesAcknowledgment(relocationsStillPending: true))
        // New session (markers cleared): exactly once.
        XCTAssertTrue(store.consumeLanesAcknowledgment(relocationsStillPending: false))
        XCTAssertFalse(store.consumeLanesAcknowledgment(relocationsStillPending: false))
    }

    func testNoAcknowledgmentWhenNothingWasPending() {
        store.complete(relocationsStillPending: false)
        XCTAssertFalse(store.consumeLanesAcknowledgment(relocationsStillPending: false))
    }
}
