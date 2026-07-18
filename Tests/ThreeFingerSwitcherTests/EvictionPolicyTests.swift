import XCTest
@testable import ThreeFingerSwitcherCore

/// `model-idle-ttl-and-memory-pressure`: the pure `EvictionPolicy` (every spec scenario is a case
/// here — no OS pressure source, no resident model, faked time throughout) plus the `ModelManager`
/// integration (TTL/pressure evict transitions `loaded → ready` and the next request transparently
/// re-loads through the single-flight path).
@MainActor
final class EvictionPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func verdict(sinceActivity: TimeInterval = 0,
                         pressure: MemoryPressureLevel = .nominal,
                         quiescence: QuiescenceSnapshot = QuiescenceSnapshot(),
                         ttl: TimeInterval = 3600,
                         loadInFlight: Bool = false) -> EvictionVerdict {
        EvictionPolicy.verdict(now: t0,
                               lastActivity: t0.addingTimeInterval(-sinceActivity),
                               pressure: pressure,
                               quiescence: quiescence,
                               ttl: ttl,
                               loadInFlight: loadInFlight)
    }

    // MARK: - Pure policy

    func testIdleTTLEvictsAQuiescentSystem() {
        XCTAssertEqual(verdict(sinceActivity: 3600, ttl: 3600), .evict(.idleTTL))
    }

    func testBelowTTLKeeps() {
        XCTAssertEqual(verdict(sinceActivity: 3599, ttl: 3600), .keep)
    }

    func testTTLZeroRestoresKeepForeverButPressureStaysArmed() {
        // Quiescent forever with ttl 0 → never a TTL evict…
        XCTAssertEqual(verdict(sinceActivity: 1_000_000, ttl: 0), .keep)
        // …while a pressure trigger on the same inputs still fires.
        XCTAssertEqual(verdict(sinceActivity: 1_000_000, pressure: .warning, ttl: 0),
                       .evict(.warningPressure))
        XCTAssertEqual(verdict(sinceActivity: 0, pressure: .critical, ttl: 0),
                       .evict(.criticalPressure))
    }

    func testWarningPressureRespectsAnOpenConversation() {
        let open = QuiescenceSnapshot(foregroundSessionActive: true)
        XCTAssertEqual(verdict(pressure: .warning, quiescence: open), .keep)
        // And an open conversation also protects against the TTL trigger.
        XCTAssertEqual(verdict(sinceActivity: 10_000, quiescence: open, ttl: 3600), .keep)
    }

    func testWarningPressureEvictsOnlyWhenQuiescentANDIdlePastTheFloor() {
        // Fully quiescent but RECENTLY active: chronic warning between turns must NOT thrash
        // (`fix-evict-thrash-and-hot-path` — the reload-storm regression).
        XCTAssertEqual(verdict(sinceActivity: 0, pressure: .warning), .keep)
        XCTAssertEqual(verdict(sinceActivity: EvictionPolicy.warningIdleFloor - 1, pressure: .warning),
                       .keep)
        // Quiescent AND genuinely idle: warning still reclaims.
        XCTAssertEqual(verdict(sinceActivity: EvictionPolicy.warningIdleFloor, pressure: .warning),
                       .evict(.warningPressure))
    }

    func testReloadBuysAGraceWindowUnderChronicWarning() {
        // The storm scenario end-to-end at the policy level: activity just stamped (a reload), the
        // system back at warning — the next ticks keep the model until the floor passes.
        XCTAssertEqual(verdict(sinceActivity: 60, pressure: .warning), .keep)
        XCTAssertEqual(verdict(sinceActivity: 299, pressure: .warning), .keep)
        // …and critical remains the immediate emergency valve.
        XCTAssertEqual(verdict(sinceActivity: 0, pressure: .critical), .evict(.criticalPressure))
    }

    func testCriticalPressureEvictsBetweenTurnsEvenWithForegroundSession() {
        let open = QuiescenceSnapshot(foregroundSessionActive: true)
        XCTAssertEqual(verdict(pressure: .critical, quiescence: open), .evict(.criticalPressure))
    }

    func testNeverEvictMidTurnOrMidLoad() {
        let midTurn = QuiescenceSnapshot(turnInFlight: true)
        XCTAssertEqual(verdict(pressure: .critical, quiescence: midTurn), .keep)
        XCTAssertEqual(verdict(pressure: .warning, quiescence: midTurn), .keep)
        XCTAssertEqual(verdict(sinceActivity: 10_000, quiescence: midTurn), .keep)
        XCTAssertEqual(verdict(pressure: .critical, loadInFlight: true), .keep)
        XCTAssertEqual(verdict(sinceActivity: 10_000, ttl: 3600, loadInFlight: true), .keep)
    }

    func testImminentScheduledWorkBlocksTTLAndWarning() {
        let imminent = QuiescenceSnapshot(nextScheduledWork: t0.addingTimeInterval(60))
        XCTAssertEqual(verdict(sinceActivity: 10_000, quiescence: imminent), .keep)
        XCTAssertEqual(verdict(pressure: .warning, quiescence: imminent), .keep)
        // Past-due counts as imminent (the driver just hasn't served it yet).
        let overdue = QuiescenceSnapshot(nextScheduledWork: t0.addingTimeInterval(-5))
        XCTAssertEqual(verdict(sinceActivity: 10_000, quiescence: overdue), .keep)
        // Work far beyond the horizon does NOT hold the weights resident (it lazy-reloads later).
        let far = QuiescenceSnapshot(
            nextScheduledWork: t0.addingTimeInterval(EvictionPolicy.scheduledWorkHorizon + 60))
        XCTAssertEqual(verdict(sinceActivity: 10_000, quiescence: far), .evict(.idleTTL))
        // …but critical pressure ignores the schedule (only turn/load block it).
        XCTAssertEqual(verdict(pressure: .critical, quiescence: imminent), .evict(.criticalPressure))
    }

    // MARK: - Manager integration fixtures

    private final class InstantDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            progress(1.0)
            return payload
        }
    }

    private func tempRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-evict-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func catalog(matching payload: Data, lane: ComputeLane? = .gpu) -> ModelCatalog {
        ModelCatalog(
            models: [ModelDescriptor(
                id: "evict-test-model",
                displayName: "Evict Test Model",
                sizeBytes: Int64(payload.count),
                integritySHA: ModelManager.sha256Hex(payload),
                downloadURL: URL(string: "https://models.invalid/evict-test")!,
                capabilities: [.text],
                quantization: .qat4bit,
                lane: lane
            )],
            defaultModelID: "evict-test-model"
        )
    }

    /// A loaded manager with automatic eviction installed against the given fakes. Time starts at
    /// `t0`; tests advance it by mutating `clock.now`.
    private final class Clock { var now: Date; init(_ d: Date) { now = d } }

    private func loadedManager(payload: Data = Data("weights".utf8),
                               lane: ComputeLane? = .gpu,
                               pressure: FakeMemoryPressureSource,
                               clock: Clock,
                               quiescence: @escaping () -> QuiescenceSnapshot = { QuiescenceSnapshot() },
                               ttlMinutes: Int = 60) async throws -> ModelManager {
        let manager = ModelManager(registry: catalog(matching: payload, lane: lane),
                                   downloader: InstantDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        // Install BEFORE loading so the activity stamps taken during the load use the fake clock —
        // otherwise `lastActivity` is real wall-clock time and every TTL comparison goes negative.
        manager.installAutomaticEviction(pressure: pressure,
                                         quiescence: quiescence,
                                         idleTTL: { TimeInterval(ttlMinutes * 60) },
                                         now: { clock.now },
                                         tickInterval: nil)   // tests drive evaluation directly
        try await manager.downloadAndVerify(manager.registry.models[0])
        _ = try await manager.loadIfNeeded()
        return manager
    }

    // MARK: - Manager integration

    func testTTLEvictTransitionsLoadedToReadyAndReloadsTransparently() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let manager = try await loadedManager(pressure: pressure, clock: clock)
        XCTAssertTrue(manager.isResident)

        // Below the TTL: the tick keeps the model resident.
        clock.now = t0.addingTimeInterval(30 * 60)
        manager.evaluateAutomaticEviction()
        XCTAssertTrue(manager.isResident, "half the TTL is not idle enough")

        // Past the TTL while fully quiescent: evicted, weights still on disk → `.ready`.
        clock.now = t0.addingTimeInterval(61 * 60)
        manager.evaluateAutomaticEviction()
        XCTAssertFalse(manager.isResident, "TTL must evict a quiescent system")
        XCTAssertEqual(manager.state, .ready, "weights stay on disk — ready, never a failure")

        // Invisible-correct: the next request transparently re-loads (single-flight path).
        let runtime = try await manager.loadIfNeeded()
        XCTAssertNotNil(runtime)
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertTrue(manager.isResident)
    }

    func testPressureEventEvictsImmediatelyWithoutWaitingForTick() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let manager = try await loadedManager(pressure: pressure, clock: clock)
        XCTAssertTrue(manager.isResident)
        // A critical event fires the policy through `onChange` — no tick needed.
        pressure.report(.critical)
        XCTAssertFalse(manager.isResident)
        XCTAssertEqual(manager.state, .ready)
    }

    func testWarningPressureKeepsWhileForegroundSessionOpen() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let open = QuiescenceSnapshot(foregroundSessionActive: true)
        let manager = try await loadedManager(pressure: pressure, clock: clock,
                                              quiescence: { open })
        pressure.report(.warning)
        XCTAssertTrue(manager.isResident, "warning must respect an open conversation")
        pressure.report(.critical)
        XCTAssertFalse(manager.isResident, "critical overrides the open session between turns")
    }

    func testTurnInFlightBlocksEvenCriticalPressure() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let busy = QuiescenceSnapshot(turnInFlight: true)
        let manager = try await loadedManager(pressure: pressure, clock: clock,
                                              quiescence: { busy })
        pressure.report(.critical)
        XCTAssertTrue(manager.isResident, "never evict mid-turn")
    }

    func testCPUTernaryLaneIsExempt() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let manager = try await loadedManager(lane: .cpuTernary, pressure: pressure, clock: clock)
        clock.now = t0.addingTimeInterval(10 * 3600)
        manager.evaluateAutomaticEviction()
        pressure.report(.critical)
        XCTAssertTrue(manager.isResident, "the ternary lane's small footprint is never auto-evicted")
    }

    func testActivityStampDefersTTL() async throws {
        let clock = Clock(t0)
        let pressure = FakeMemoryPressureSource()
        let manager = try await loadedManager(pressure: pressure, clock: clock)
        // A request 50 minutes in re-stamps activity…
        clock.now = t0.addingTimeInterval(50 * 60)
        _ = try await manager.loadIfNeeded()
        // …so 61 minutes after t0 (only 11 after the stamp) the system is not idle yet.
        clock.now = t0.addingTimeInterval(61 * 60)
        manager.evaluateAutomaticEviction()
        XCTAssertTrue(manager.isResident)
        // 50 + 61 minutes: now genuinely idle past the TTL.
        clock.now = t0.addingTimeInterval((50 + 61) * 60)
        manager.evaluateAutomaticEviction()
        XCTAssertFalse(manager.isResident)
    }
}
