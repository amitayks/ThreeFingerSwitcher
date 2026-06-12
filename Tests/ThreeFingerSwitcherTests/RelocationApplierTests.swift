import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `RelocationApplier` (NativeGesture/RelocationApplier.swift): the one write path
/// for trackpad relocations. Uses an in-memory trackpad-defaults fake and an isolated UserDefaults
/// suite, so no system state is touched.
@MainActor
final class RelocationApplierTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var trackpad: FakeTrackpadDefaults!
    private var session: MutableLoginSession!
    private var markers: ReloginMarkers!
    private var applier: RelocationApplier!

    private let h3 = TrackpadKey.threeFingerHoriz
    private let v3 = TrackpadKey.threeFingerVert
    private let h4 = TrackpadKey.fourFingerHoriz
    private let v4 = TrackpadKey.fourFingerVert

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.RelocationApplier.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        precondition(defaults != nil, "Failed to create isolated UserDefaults suite")
        trackpad = FakeTrackpadDefaults()
        session = MutableLoginSession(id: 100)
        markers = ReloginMarkers(defaults: defaults, session: session)
        applier = RelocationApplier(trackpad: trackpad, backups: defaults, markers: markers)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// A stock Mac: 3F horizontal claimed (1), 3F vertical claimed (2), 4F keys absent.
    private func seedStockMac() {
        for domain in TrackpadKey.domains {
            trackpad.seed(1, domain: domain, key: h3)
            trackpad.seed(2, domain: domain, key: v3)
        }
    }

    private func decodeBackup(_ slot: String) -> [String: [String: String]]? {
        guard let data = defaults.data(forKey: slot) else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    // MARK: - Combined apply

    func testCombinedApplyWritesFinalValuesOnce() {
        seedStockMac()
        let result = applier.apply(requested: .all, context: [])
        XCTAssertEqual(result.applied, .all)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
        // Final values in both domains — the all-on end state, no intermediates.
        for domain in TrackpadKey.domains {
            XCTAssertEqual(trackpad.value(domain: domain, key: h3), 2)
            XCTAssertEqual(trackpad.value(domain: domain, key: v3), 0)
            XCTAssertEqual(trackpad.value(domain: domain, key: h4), 2, "launcher wins the shared 4F-horiz key")
            XCTAssertEqual(trackpad.value(domain: domain, key: v4), 0, "launcher wins the shared 4F-vert key")
        }
        // Each key written exactly once per domain (shared keys deduped): 4 keys × 2 domains.
        XCTAssertEqual(trackpad.writeLog.count, 8)
    }

    func testCombinedApplyBackupsArePristine() {
        seedStockMac()
        _ = applier.apply(requested: .all, context: [])
        // Every slot must hold the PRE-plan values — the shared 4F keys recorded as absent in both
        // the horizontal and launcher slots, never another feature's intermediate write.
        let horizontal = decodeBackup("trackpadGestureBackup")
        let vertical = decodeBackup("verticalGestureBackup")
        let launcher = decodeBackup("fourFingerGestureBackup")
        for domain in TrackpadKey.domains {
            XCTAssertEqual(horizontal?[domain]?[h3], "1")
            XCTAssertEqual(horizontal?[domain]?[h4], "absent")
            XCTAssertEqual(vertical?[domain]?[v3], "2")
            XCTAssertEqual(vertical?[domain]?[v4], "absent")
            XCTAssertEqual(launcher?[domain]?[h4], "absent")
            XCTAssertEqual(launcher?[domain]?[v4], "absent")
        }
    }

    func testCombinedApplyMarksEveryFeaturePending() {
        seedStockMac()
        _ = applier.apply(requested: .all, context: [])
        XCTAssertTrue(markers.isPending(.horizontal))
        XCTAssertTrue(markers.isPending(.spaceRows))
        XCTAssertTrue(markers.isPending(.launcher))
    }

    // MARK: - Context resolution (the historic collisions)

    func testHorizontalWithLauncherContextFreesFourFingerHorizontal() {
        seedStockMac()
        _ = applier.apply(requested: .horizontal, context: .launcher)
        for domain in TrackpadKey.domains {
            XCTAssertEqual(trackpad.value(domain: domain, key: h4), 2,
                           "with the launcher active, 4F-horiz must be freed (2), never parked (1)")
        }
        // Only the horizontal feature's keys were written; the launcher's exclusive key was not.
        XCTAssertNil(trackpad.value(domain: TrackpadKey.domains[0], key: v4))
        XCTAssertNil(defaults.data(forKey: "fourFingerGestureBackup"),
                     "a context feature's backup slot is never touched")
    }

    func testSpaceRowsWithLauncherContextFreesFourFingerVertical() {
        seedStockMac()
        _ = applier.apply(requested: .spaceRows, context: .launcher)
        for domain in TrackpadKey.domains {
            XCTAssertEqual(trackpad.value(domain: domain, key: v4), 0,
                           "with the launcher active, 4F-vert must be freed (0), never parked (2)")
        }
    }

    func testSpaceRowsAloneParksMissionControlOnFourFingers() {
        seedStockMac()
        _ = applier.apply(requested: .spaceRows, context: [])
        for domain in TrackpadKey.domains {
            XCTAssertEqual(trackpad.value(domain: domain, key: v4), 2)
        }
    }

    // MARK: - No-op guards (reapply-on-relaunch must not re-arm pending)

    func testAlreadyFreeFeatureIsSkippedEntirely() {
        for domain in TrackpadKey.domains {
            trackpad.seed(0, domain: domain, key: v3)   // 3F vertical already freed
        }
        let result = applier.apply(requested: .spaceRows, context: [])
        XCTAssertEqual(result.skipped, .spaceRows)
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertTrue(trackpad.writeLog.isEmpty, "no write")
        XCTAssertNil(defaults.data(forKey: "verticalGestureBackup"), "no backup")
        XCTAssertFalse(markers.isPending(.spaceRows), "no pending re-mark")
    }

    func testExistingBackupIsNeverOverwritten() {
        seedStockMac()
        _ = applier.apply(requested: .spaceRows, context: [])
        let first = defaults.data(forKey: "verticalGestureBackup")
        // Simulate the keys being claimed again (e.g. an OS update reset them) and re-apply.
        for domain in TrackpadKey.domains { trackpad.seed(2, domain: domain, key: v3) }
        _ = applier.apply(requested: .spaceRows, context: [])
        XCTAssertEqual(defaults.data(forKey: "verticalGestureBackup"), first,
                       "first-write-wins: the older backup is the pristine one")
    }

    // MARK: - Failure (managed Mac)

    func testFailedWriteReportsFailureAndStaysPending() {
        seedStockMac()
        trackpad.failWrites = true
        let result = applier.apply(requested: [.horizontal, .spaceRows], context: [])
        XCTAssertEqual(result.failed, [.horizontal, .spaceRows])
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertTrue(markers.isPending(.horizontal), "a partial/failed write still leaves the system altered")
        XCTAssertTrue(markers.isPending(.spaceRows))
    }
}

// MARK: - Fakes

/// In-memory stand-in for the `/usr/bin/defaults` trackpad domains.
final class FakeTrackpadDefaults: TrackpadDefaultsAccess {
    private var storage: [String: Int] = [:]
    var failWrites = false
    private(set) var writeLog: [(domain: String, key: String, value: Int)] = []

    func seed(_ value: Int, domain: String, key: String) { storage["\(domain)|\(key)"] = value }
    func value(domain: String, key: String) -> Int? { storage["\(domain)|\(key)"] }

    func readRaw(domain: String, key: String) -> String? {
        storage["\(domain)|\(key)"].map(String.init)
    }

    @discardableResult
    func writeInt(_ value: Int, domain: String, key: String) -> Bool {
        writeLog.append((domain, key, value))
        guard !failWrites else { return false }
        storage["\(domain)|\(key)"] = value
        return true
    }

    @discardableResult
    func deleteKey(domain: String, key: String) -> Bool {
        storage.removeValue(forKey: "\(domain)|\(key)")
        return true
    }
}

/// Login-session fake whose ID can be changed mid-test (simulating a re-login).
final class MutableLoginSession: LoginSessionProviding {
    var id: Int32?
    init(id: Int32?) { self.id = id }
    func currentSessionID() -> Int32? { id }
}
