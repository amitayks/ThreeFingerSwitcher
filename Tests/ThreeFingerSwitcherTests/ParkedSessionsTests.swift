import XCTest
import SwiftUI
@testable import ThreeFingerSwitcherCore

/// Tests for the `ai-parked-sessions` slice (tasks §1–§5): the park types (§1), the `ParkScheduler`
/// one-active-now + K-ready seam (§2), the durable store round-trip + `ParkError` mapping (§3), the
/// lifecycle eviction/auto-dismiss/discard (§4 / D1), and the pure overscroll-park + anchor + reveal models (§5).
/// Everything is MLX-free Core, driven against temp dirs + stubs — no model. `@MainActor` because the
/// reveal/anchor models and `AppSettings` keys exercised here are main-actor-friendly.
@MainActor
final class ParkedSessionsTests: XCTestCase {

    private func sid() -> AgentSessionID { AgentSessionID() }
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-parked-test-\(UUID().uuidString)", isDirectory: true)
    }
    private func conversation(_ id: AgentSessionID, _ title: String = "T") -> AgentConversation {
        AgentConversation(id: id, title: title, messages: [AgentMessage(role: .user, text: "hi")])
    }

    // MARK: - 1. Park types

    func testParkedSessionCodableRoundTripPreservesIdentity() throws {
        let id = sid()
        let session = ParkedSession(id: id, title: "Draft", state: .parked, badgeCount: 3,
                                    nextRunAt: Date(timeIntervalSince1970: 1000),
                                    updatedAt: Date(timeIntervalSince1970: 2000))
        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(ParkedSession.self, from: data)
        XCTAssertEqual(session, back)
        XCTAssertEqual(back.id, id)                 // identity stable across encode/decode
    }

    func testParkStateProtectionFlags() {
        XCTAssertTrue(ParkState.active.isProtectedFromAging)
        XCTAssertTrue(ParkState.needsYou.isProtectedFromAging)
        XCTAssertFalse(ParkState.parked.isProtectedFromAging)
        XCTAssertFalse(ParkState.idle.isProtectedFromAging)
        XCTAssertFalse(ParkState.completed.isProtectedFromAging)   // terminal → eligible for auto-dismiss
        XCTAssertTrue(ParkState.completed.isTerminal)
        XCTAssertFalse(ParkState.idle.isTerminal)
    }

    func testParkErrorYieldsCleanHeadlineNeverRawText() {
        for err in [ParkError.storeUnavailable(detail: "ENOSPC raw os text"),
                    .persistFailed(detail: "raw coding dump"),
                    .resumeMissing] {
            let presented = AIError.message(for: err)
            XCTAssertFalse(presented.headline.isEmpty)
            XCTAssertFalse(presented.headline.contains("raw"))
            XCTAssertFalse(presented.headline.contains("ENOSPC"))
        }
        // The raw detail is carried in details, not the headline.
        let p = AIError.message(for: ParkError.persistFailed(detail: "raw coding dump"))
        XCTAssertEqual(p.details, "raw coding dump")
    }

    // MARK: - 2. Scheduler (one-active-now + K-ready)

    func testSerialSchedulerReturnsAtMostOneRegardlessOfSlots() {
        let now = Date(timeIntervalSince1970: 10_000)
        let a = ParkedSession(id: sid(), title: "a", state: .parked, updatedAt: now.addingTimeInterval(-30))
        let b = ParkedSession(id: sid(), title: "b", state: .parked, updatedAt: now.addingTimeInterval(-10))
        let sched = SerialParkScheduler(sessions: [b, a])
        // Oldest-waiting first → a, regardless of maxSlots.
        XCTAssertEqual(sched.runnableSessions(now: now, maxSlots: 1), [a.id])
        XCTAssertEqual(sched.runnableSessions(now: now, maxSlots: 8), [a.id])
        XCTAssertEqual(sched.runnableSessions(now: now, maxSlots: 0), [])
    }

    func testSchedulerExcludesNeedsYouAndFutureNextRunAt() {
        let now = Date(timeIntervalSince1970: 10_000)
        let needs = ParkedSession(id: sid(), title: "n", state: .needsYou, updatedAt: now)
        let future = ParkedSession(id: sid(), title: "f", state: .parked,
                                   nextRunAt: now.addingTimeInterval(60), updatedAt: now)
        let active = ParkedSession(id: sid(), title: "act", state: .active, updatedAt: now)
        let runnable = ParkedSession(id: sid(), title: "r", state: .parked,
                                     nextRunAt: now.addingTimeInterval(-1), updatedAt: now)
        let sched = SerialParkScheduler(sessions: [needs, future, active, runnable])
        XCTAssertEqual(sched.runnableSessions(now: now, maxSlots: 4), [runnable.id])
    }

    func testDidAdvanceTransitions() {
        let id = sid()
        let sched = SerialParkScheduler(sessions: [ParkedSession(id: id, title: "x", state: .parked)])
        sched.didAdvance(id, result: ToolStepResult(tool: "t", status: .done, summary: "ok"))
        let afterDone = sched.snapshot().first { $0.id == id }!
        XCTAssertEqual(afterDone.state, .idle)
        XCTAssertEqual(afterDone.badgeCount, 1)

        sched.didAdvance(id, result: ToolStepResult(tool: "t", status: .failed(headline: "Clean headline"),
                                                    summary: "x"))
        XCTAssertEqual(sched.snapshot().first { $0.id == id }!.state, .parked)

        sched.didAdvance(id, result: ToolStepResult(tool: "t", status: .awaitingApproval, summary: "x"))
        XCTAssertEqual(sched.snapshot().first { $0.id == id }!.state, .needsYou)
    }

    func testEscalateSetsNeedsYouAndBadge() {
        let id = sid()
        let sched = SerialParkScheduler(sessions: [ParkedSession(id: id, title: "x", state: .parked)])
        sched.escalate(id, reason: "dangerous write")
        let row = sched.snapshot().first { $0.id == id }!
        XCTAssertEqual(row.state, .needsYou)
        XCTAssertGreaterThanOrEqual(row.badgeCount, 1)
        // An escalated (needs-you) session is no longer runnable.
        XCTAssertEqual(sched.runnableSessions(now: Date(), maxSlots: 4), [])
    }

    func testKReadyContractWithConcurrentStub() {
        // A drop-in K scheduler reusing the SAME `ParkRunnable.ordered` filter returns up to K with NO
        // protocol change — the batching seam contract.
        final class ConcurrentParkScheduler: ParkScheduler, @unchecked Sendable {
            let rows: [ParkedSession]
            init(_ rows: [ParkedSession]) { self.rows = rows }
            func runnableSessions(now: Date, maxSlots: Int) -> [AgentSessionID] {
                Array(ParkRunnable.ordered(rows, now: now).prefix(max(maxSlots, 0)))
            }
            func didAdvance(_ id: AgentSessionID, result: ToolStepResult, taskComplete: Bool) {}
            func escalate(_ id: AgentSessionID, reason: String) {}
        }
        let now = Date(timeIntervalSince1970: 1)
        let rows = (0..<5).map { i in
            ParkedSession(id: sid(), title: "\(i)", state: .parked, updatedAt: now.addingTimeInterval(Double(i)))
        }
        let k: ParkScheduler = ConcurrentParkScheduler(rows)
        XCTAssertEqual(k.runnableSessions(now: now, maxSlots: 3).count, 3)
        XCTAssertEqual(k.runnableSessions(now: now, maxSlots: 1).count, 1)
        XCTAssertEqual(k.runnableSessions(now: now, maxSlots: 99).count, 5)
    }

    // MARK: - 3. Durable store

    func testDiskStoreRoundTrip() throws {
        let store = DiskParkedSessionStore(directory: tempDir())
        let id = sid()
        let session = ParkedSession(id: id, title: "Round", state: .parked, badgeCount: 2)
        try store.upsert(session, conversation: conversation(id, "Round"))
        XCTAssertEqual(store.all().map(\.id), [id])
        XCTAssertEqual(store.conversation(id)?.title, "Round")
        try store.remove(id)
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(store.conversation(id))
    }

    func testDiskStoreRebuildsFromDiskOnRelaunch() throws {
        let dir = tempDir()
        let id = sid()
        do {
            let store = DiskParkedSessionStore(directory: dir)
            try store.upsert(ParkedSession(id: id, title: "Persist", state: .idle),
                             conversation: conversation(id, "Persist"))
        }
        // A fresh store over the SAME dir rebuilds the index (the relaunch path).
        let reopened = DiskParkedSessionStore(directory: dir)
        XCTAssertEqual(reopened.all().map(\.id), [id])
        XCTAssertEqual(reopened.conversation(id)?.title, "Persist")
    }

    func testStoreResumeReadAndPersist() throws {
        let store = DiskParkedSessionStore(directory: tempDir())
        let id = sid()
        try store.upsert(ParkedSession(id: id, title: "R", state: .idle), conversation: conversation(id))
        XCTAssertNil(store.oneLineResume(id))
        try store.persistResume(id, resume: "Was drafting the email.")
        XCTAssertEqual(store.oneLineResume(id), "Was drafting the email.")
    }

    func testStoreFailureIsObservableNotSilent() {
        let store = InMemoryParkedSessionStore()
        store.failWrites = true
        let id = sid()
        XCTAssertThrowsError(try store.upsert(ParkedSession(id: id, title: "x", state: .parked),
                                              conversation: conversation(id))) { error in
            guard let park = error as? ParkError else { return XCTFail("not a ParkError") }
            // It maps to the taxonomy and yields a clean headline (never raw / never silent).
            XCTAssertEqual(AIError.message(for: park).headline, "That parked session couldn't be saved.")
        }
    }

    func testResumeMissingThrows() {
        let store = InMemoryParkedSessionStore()
        XCTAssertThrowsError(try store.persistResume(sid(), resume: "x")) { error in
            XCTAssertEqual(error as? ParkError, .resumeMissing)
        }
    }

    // MARK: - 4. Lifecycle

    func testEvictionPicksLeastRecentlyUpdatedIdleNeverProtected() {
        let now = Date(timeIntervalSince1970: 100_000)
        let oldIdle = ParkedSession(id: sid(), title: "oldIdle", state: .idle,
                                    updatedAt: now.addingTimeInterval(-100))
        let newIdle = ParkedSession(id: sid(), title: "newIdle", state: .idle,
                                    updatedAt: now.addingTimeInterval(-10))
        let active = ParkedSession(id: sid(), title: "active", state: .active,
                                   updatedAt: now.addingTimeInterval(-1000))
        let needs = ParkedSession(id: sid(), title: "needs", state: .needsYou,
                                  updatedAt: now.addingTimeInterval(-2000))
        let life = ParkLifecycle(maxParked: 3, autoDismissCountdown: 60)
        // 4 > 3 → evict the oldest IDLE one (never the older active/needsYou).
        XCTAssertEqual(life.evictable([oldIdle, newIdle, active, needs], now: now), oldIdle.id)
    }

    func testEvictionReturnsNilWhenUnderCapOrAllProtected() {
        let now = Date()
        let life = ParkLifecycle(maxParked: 2, autoDismissCountdown: 60)
        let two = [ParkedSession(id: sid(), title: "a", state: .idle),
                   ParkedSession(id: sid(), title: "b", state: .idle)]
        XCTAssertNil(life.evictable(two, now: now))     // under cap
        // Over cap but ALL non-idle → nothing evicted (a conversation is never force-lost).
        let allProtected = [ParkedSession(id: sid(), title: "a", state: .active),
                            ParkedSession(id: sid(), title: "b", state: .needsYou),
                            ParkedSession(id: sid(), title: "c", state: .parked)]
        XCTAssertNil(life.evictable(allProtected, now: now))
    }

    func testDismissableTerminalAndStaleNeverProtected() {
        let now = Date(timeIntervalSince1970: 100_000)
        // Terminal (completed) → dismissed regardless of age.
        let completed = ParkedSession(id: sid(), title: "done", state: .completed,
                                      updatedAt: now)                       // brand new but terminal
        // Idle past the countdown → dismissed.
        let staleIdle = ParkedSession(id: sid(), title: "stale", state: .idle,
                                      updatedAt: now.addingTimeInterval(-301))
        // Idle under the countdown → kept.
        let freshIdle = ParkedSession(id: sid(), title: "fresh", state: .idle,
                                      updatedAt: now.addingTimeInterval(-10))
        // Parked past the countdown → dismissed (parked is non-protected too).
        let staleParked = ParkedSession(id: sid(), title: "parked", state: .parked,
                                        updatedAt: now.addingTimeInterval(-9999))
        // Protected: never dismissed even when ancient.
        let active = ParkedSession(id: sid(), title: "act", state: .active,
                                   updatedAt: now.addingTimeInterval(-9999))
        let needs = ParkedSession(id: sid(), title: "needs", state: .needsYou,
                                  updatedAt: now.addingTimeInterval(-9999))
        let life = ParkLifecycle(maxParked: 10, autoDismissCountdown: 300)
        let dismissable = Set(life.dismissable([completed, staleIdle, freshIdle, staleParked, active, needs],
                                               now: now))
        XCTAssertEqual(dismissable, Set([completed.id, staleIdle.id, staleParked.id]))
    }

    func testAutoDismissCountdownRemovesStaleParked() throws {
        // 301s old removed, 299s kept (the 300s default boundary).
        let now = Date(timeIntervalSince1970: 100_000)
        let stale = ParkedSession(id: sid(), title: "stale", state: .idle,
                                  updatedAt: now.addingTimeInterval(-301))
        let fresh = ParkedSession(id: sid(), title: "fresh", state: .idle,
                                  updatedAt: now.addingTimeInterval(-299))
        let life = ParkLifecycle(maxParked: 10, autoDismissCountdown: 300)
        XCTAssertEqual(life.dismissable([stale, fresh], now: now), [stale.id])
    }

    func testAutoDismissNeverTouchesProtected() {
        let now = Date(timeIntervalSince1970: 100_000)
        let active = ParkedSession(id: sid(), title: "act", state: .active,
                                   updatedAt: now.addingTimeInterval(-9999))
        let needs = ParkedSession(id: sid(), title: "needs", state: .needsYou,
                                  updatedAt: now.addingTimeInterval(-9999))
        let life = ParkLifecycle(maxParked: 10, autoDismissCountdown: 300)
        XCTAssertTrue(life.dismissable([active, needs], now: now).isEmpty)
    }

    func testRunAutoDismissPassUsesDiscardPath() async throws {
        // The pass routes each dismissable id through the authoritative discard (cancel pending + remove).
        let store = InMemoryParkedSessionStore()
        let now = Date(timeIntervalSince1970: 100_000)
        let id = sid()
        try store.upsert(ParkedSession(id: id, title: "Stale", state: .idle,
                                       updatedAt: now.addingTimeInterval(-301)),
                         conversation: conversation(id))
        let coord = ParkLifecycleCoordinator(store: store,
                                             lifecycle: ParkLifecycle(maxParked: 10, autoDismissCountdown: 300))
        let cancelled = expectation(description: "pending task observed cancellation")
        let task = Task<Void, Never> {
            while !Task.isCancelled { await Task.yield() }
            cancelled.fulfill()
        }
        coord.registerPending(id, task: task)
        let dismissed = coord.runAutoDismissPass(now: now)
        XCTAssertEqual(dismissed, [id])
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(store.conversation(id))     // removed via discard path
        XCTAssertTrue(store.all().isEmpty)
    }

    func testDiscardCancelsPendingRemovesAndIsNotAFailure() async throws {
        let store = InMemoryParkedSessionStore()
        let id = sid()
        try store.upsert(ParkedSession(id: id, title: "D", state: .parked), conversation: conversation(id))
        let coord = ParkLifecycleCoordinator(store: store,
                                             lifecycle: ParkLifecycle(maxParked: 10, autoDismissCountdown: 300))
        let cancelled = expectation(description: "task observed cancellation")
        let task = Task<Void, Never> {
            // A long-lived pending generation; discard cancels it (NOT a failure).
            while !Task.isCancelled { await Task.yield() }
            cancelled.fulfill()
        }
        coord.registerPending(id, task: task)
        try coord.discard(id)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(store.conversation(id))            // removed
        XCTAssertTrue(store.all().isEmpty)
        // No `failed` row was created — discard removed it cleanly (cancellation is not a failure).
    }

    // MARK: - 5. Overscroll-park + anchor + reveal models

    func testOverscrollParkOnlyAtBottomAboveThreshold() {
        let threshold: CGFloat = 0.22
        // At bottom + over threshold → park.
        XCTAssertTrue(OverscrollPark.shouldPark(dy: 0.3, canvasAtBottom: true, overscrollThreshold: threshold))
        // At bottom but below threshold → scroll, not park.
        XCTAssertFalse(OverscrollPark.shouldPark(dy: 0.1, canvasAtBottom: true, overscrollThreshold: threshold))
        // Not at bottom → never park, even with a big excursion.
        XCTAssertFalse(OverscrollPark.shouldPark(dy: 0.9, canvasAtBottom: false, overscrollThreshold: threshold))
        // Downward excursion (negative dy) → never park (that's the at-top commit direction).
        XCTAssertFalse(OverscrollPark.shouldPark(dy: -0.5, canvasAtBottom: true, overscrollThreshold: threshold))
    }

    func testAnchorNotchVsTab() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 120, height: 10)
        // Notch (safeAreaTop > 0): tucked further below the top than a tab.
        let notch = NotchHomeZoneAnchor.zoneRect(size: size, visibleFrame: visible, safeAreaTop: 38)
        let tab = NotchHomeZoneAnchor.zoneRect(size: size, visibleFrame: visible, safeAreaTop: 0)
        XCTAssertEqual(notch.midX, visible.midX, accuracy: 0.5)   // top-center both
        XCTAssertEqual(tab.midX, visible.midX, accuracy: 0.5)
        XCTAssertLessThan(notch.maxY, tab.maxY)                   // notch sits lower (more top gap)
        XCTAssertLessThanOrEqual(tab.maxY, visible.maxY)          // never off the top
    }

    func testRailClampsWithinScreenAndNeverResizes() {
        let visible = CGRect(x: 0, y: 0, width: 400, height: 900)
        let zone = NotchHomeZoneAnchor.zoneRect(size: CGSize(width: 120, height: 10),
                                                visibleFrame: visible, safeAreaTop: 0)
        let railSize = CGSize(width: 1200, height: 120)          // wider than the screen
        let rail = NotchHomeZoneAnchor.railRect(zone: zone, size: railSize, visibleFrame: visible)
        // Clamp shifts the origin only — size is preserved (the DockHoverModel.clamp idiom).
        XCTAssertEqual(rail.size, railSize)
        XCTAssertGreaterThanOrEqual(rail.minX, visible.minX - 0.001)
        XCTAssertLessThan(rail.minY, zone.minY)                  // grows below the zone
    }

    /// D5: the rail EMERGES FROM the notch — its TOP edge is FLUSH at the resting zone's TOP edge
    /// (`zone.maxY`, the notch / menu-bar lower edge), ZERO gap, growing downward. Regression guard for
    /// the old free-floating rect that left a full `notchMargin` (8pt) gap below the zone.
    func testRailEmergesFlushFromNotchEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let zone = NotchHomeZoneAnchor.zoneRect(size: CGSize(width: 120, height: 10),
                                                visibleFrame: visible, safeAreaTop: 38)
        let size = CGSize(width: 600, height: NotchHomeZoneLayout.railHeight)
        let rail = NotchHomeZoneAnchor.railRect(zone: zone, size: size, visibleFrame: visible)
        // Flush: the rail TOP meets the zone TOP exactly — no 8pt gap.
        XCTAssertEqual(rail.maxY, zone.maxY, accuracy: 0.001)
        XCTAssertEqual(rail.size, size)                          // never resized
        XCTAssertEqual(rail.midX, zone.midX, accuracy: 0.5)      // top-centered on the zone
        XCTAssertLessThan(rail.minY, zone.minY)                  // grows downward
        XCTAssertGreaterThanOrEqual(rail.minY, visible.minY - 0.001)   // on-screen
    }

    /// D5 content-fit: the rail HUGS N session cards + chrome in width (mirroring SwitcherLayout's
    /// contentSize), clamps to the screen fraction (overflow → horizontal scroll), and a single/empty
    /// rail hugs to the one-card floor. Height fits one band, flagging overflow → vertical scroll only
    /// when clamped below the band.
    func testRailContentFitHugsSessionsAndClamps() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Single card → exactly the one-card floor, no overflow.
        let one = NotchHomeZoneLayout.solve(count: 1, visibleFrame: visible)
        XCTAssertEqual(one.contentSize.width, NotchHomeZoneLayout.oneCardWidth, accuracy: 0.001)
        XCTAssertFalse(one.overflowsHorizontally)

        // Three cards → chrome + 3 cards + 2 gaps (hugs, well under the clamp).
        let three = NotchHomeZoneLayout.solve(count: 3, visibleFrame: visible)
        XCTAssertEqual(three.contentSize.width, NotchHomeZoneLayout.naturalWidth(count: 3), accuracy: 0.001)
        XCTAssertGreaterThan(three.contentSize.width, one.contentSize.width)  // wider with more cards
        XCTAssertFalse(three.overflowsHorizontally)

        // Empty → still the one-card floor (never a zero-width panel).
        let empty = NotchHomeZoneLayout.solve(count: 0, visibleFrame: visible)
        XCTAssertEqual(empty.contentSize.width, NotchHomeZoneLayout.oneCardWidth, accuracy: 0.001)

        // Many cards exceeding the width fraction → clamped to the fraction + flagged to scroll.
        let many = NotchHomeZoneLayout.solve(count: 40, visibleFrame: visible)
        let maxW = visible.width * NotchHomeZoneLayout.maxWidthFraction
        XCTAssertEqual(many.contentSize.width, maxW, accuracy: 0.001)
        XCTAssertTrue(many.overflowsHorizontally)

        // Height hugs one band within a tall screen (no vertical overflow).
        XCTAssertEqual(three.contentSize.height, NotchHomeZoneLayout.railHeight, accuracy: 0.001)
        XCTAssertFalse(three.overflowsVertically)

        // A very short screen clamps the height below the band → vertical scroll.
        let shortScreen = CGRect(x: 0, y: 0, width: 1440, height: 100)
        let clampedH = NotchHomeZoneLayout.solve(count: 1, visibleFrame: shortScreen)
        XCTAssertLessThan(clampedH.contentSize.height, NotchHomeZoneLayout.railHeight)
        XCTAssertTrue(clampedH.overflowsVertically)
    }

    func testRevealModelLifecycle() {
        let model = NotchRevealModel(graceInterval: 0.25)
        let zone = CGRect(x: 100, y: 800, width: 120, height: 10)
        let rail = CGRect(x: 60, y: 660, width: 200, height: 120)
        // In the zone → reveal.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: 160, y: 805), zoneRect: zone, railFrame: nil, now: 0), .reveal)
        // Traveling onto the rail → keep.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: 160, y: 700), zoneRect: zone, railFrame: rail, now: 0.1), .reveal)
        // Leave both, within grace → still revealed.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: 5, y: 5), zoneRect: zone, railFrame: rail, now: 0.2), .reveal)
        // Past grace → dismiss.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: 5, y: 5), zoneRect: zone, railFrame: rail, now: 1.0), .dismiss)
        // Then idle.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: 5, y: 5), zoneRect: zone, railFrame: nil, now: 1.1), .idle)
    }

    /// D5 regression guard for "move into the notch dismisses": a cursor in the FORMER GAP between the
    /// zone and the container, AND a cursor in the NOTCH BAND ABOVE the zone, both KEEP the rail (`.reveal`,
    /// never `.dismiss`) because they fall inside the ONE contiguous live region. The reveal model uses the
    /// supplied `liveZone`, not just the zone+rail union with its dead gap.
    func testRevealModelContiguousLiveZoneDocksIntoNotch() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let zone = NotchHomeZoneAnchor.zoneRect(size: CGSize(width: 120, height: 10),
                                                visibleFrame: visible, safeAreaTop: 38)
        let rail = NotchHomeZoneAnchor.railRect(
            zone: zone,
            size: CGSize(width: 600, height: NotchHomeZoneLayout.railHeight),
            visibleFrame: visible)
        let live = NotchHomeZoneAnchor.liveZoneRect(zone: zone, rail: rail, visibleFrame: visible)

        // The live region spans contiguously from below the container up past the zone into the notch.
        XCTAssertLessThanOrEqual(live.minY, rail.minY + 0.001)        // reaches the container bottom
        XCTAssertGreaterThan(live.maxY, zone.maxY)                   // extends UP into the notch pixels
        XCTAssertLessThanOrEqual(live.maxY, visible.maxY + 0.001)    // but not off the top

        let model = NotchRevealModel(graceInterval: 0.25)
        // Reveal by entering the zone.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: zone.midX, y: zone.midY),
                                  zoneRect: zone, railFrame: rail, liveZone: live, now: 0), .reveal)

        // A point in the FORMER GAP between zone and container (just below the zone, above old rail top) —
        // formerly fell in NEITHER rect and grace-armed → dismiss. Now it's inside the live zone → keep.
        let gapPoint = CGPoint(x: zone.midX, y: zone.minY - 4)
        XCTAssertFalse(zone.contains(gapPoint))
        XCTAssertTrue(live.contains(gapPoint))
        XCTAssertEqual(model.feed(cursor: gapPoint, zoneRect: zone, railFrame: rail,
                                  liveZone: live, now: 0.1), .reveal)

        // A point in the NOTCH BAND ABOVE the zone — moving UP into the notch must dock, not dismiss.
        let notchPoint = CGPoint(x: zone.midX, y: zone.maxY + 4)
        XCTAssertFalse(zone.contains(notchPoint))
        XCTAssertTrue(live.contains(notchPoint))
        XCTAssertEqual(model.feed(cursor: notchPoint, zoneRect: zone, railFrame: rail,
                                  liveZone: live, now: 5.0), .reveal)   // even well past the grace interval

        // Truly outside the live region, past grace → dismiss (the lifecycle still ends).
        let outside = CGPoint(x: 5, y: 5)
        XCTAssertFalse(live.contains(outside))
        _ = model.feed(cursor: outside, zoneRect: zone, railFrame: rail, liveZone: live, now: 5.1)
        XCTAssertEqual(model.feed(cursor: outside, zoneRect: zone, railFrame: rail,
                                  liveZone: live, now: 6.0), .dismiss)
    }

    // MARK: - Attached (notch-merged) mode — change `notch-attached-park-dock`

    /// The notch box is the gap BETWEEN the two aux menu-bar strips, its height `safeAreaTop`, its top edge
    /// the physical top (`screenFrame.maxY`). Nil on a notchless/external display (no aux areas / no safe
    /// area) so the controller degrades to the honest top-center tab.
    func testNotchRectDerivationAndTabDegradation() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let auxL = CGRect(x: 0, y: 862, width: 620, height: 38)
        let auxR = CGRect(x: 820, y: 862, width: 620, height: 38)
        let notch = try XCTUnwrap(NotchHomeZoneAnchor.notchRect(
            screenFrame: screen, safeAreaTop: 38, auxLeft: auxL, auxRight: auxR))
        XCTAssertEqual(notch, CGRect(x: 620, y: 862, width: 200, height: 38))
        XCTAssertEqual(notch.maxY, screen.maxY)                      // top edge is the physical top
        XCTAssertEqual(notch.midX, screen.midX, accuracy: 0.5)      // notch is screen-centered

        // Degradation: no safe area, or missing aux areas, or degenerate overlap → nil (tab mode).
        XCTAssertNil(NotchHomeZoneAnchor.notchRect(screenFrame: screen, safeAreaTop: 0, auxLeft: auxL, auxRight: auxR))
        XCTAssertNil(NotchHomeZoneAnchor.notchRect(screenFrame: screen, safeAreaTop: 38, auxLeft: nil, auxRight: auxR))
        XCTAssertNil(NotchHomeZoneAnchor.notchRect(screenFrame: screen, safeAreaTop: 38,
                                                   auxLeft: CGRect(x: 0, y: 862, width: 900, height: 38),
                                                   auxRight: CGRect(x: 800, y: 862, width: 640, height: 38)))
    }

    /// The resting nub hugs the notch: centered on the cutout, its TOP edge FLUSH at the notch's bottom
    /// (zero gap), growing downward — the "attached" fix for the old free-floating rect.
    func testAttachedNubHugsNotchFlush() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)
        let nub = NotchHomeZoneAnchor.attachedNubRect(size: CGSize(width: 120, height: 10),
                                                      notch: notch, screenFrame: screen)
        XCTAssertEqual(nub.maxY, notch.minY, accuracy: 0.001)        // top flush at the notch bottom
        XCTAssertEqual(nub.midX, notch.midX, accuracy: 0.5)          // centered on the notch
        XCTAssertLessThan(nub.minY, notch.minY)                      // grows downward
    }

    /// The merged panel reaches the PHYSICAL top (its black spans the notch band), is centered on the notch,
    /// floors its width at the notch + flanks, and stacks the notch band ON TOP of the content height.
    func testAttachedPanelMergesIntoNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)

        // Narrow content (one-card floor) → width floored at notch + 2 flanks; panel top at the physical top.
        let narrow = NotchHomeZoneAnchor.attachedPanelRect(
            contentSize: CGSize(width: NotchHomeZoneLayout.oneCardWidth, height: NotchHomeZoneLayout.railHeight),
            notch: notch, screenFrame: screen)
        XCTAssertEqual(narrow.maxY, notch.maxY, accuracy: 0.001)                     // reaches the physical top
        XCTAssertEqual(narrow.midX, notch.midX, accuracy: 0.5)                       // centered on the notch
        XCTAssertEqual(narrow.width, notch.width + 2 * NotchHomeZoneAnchor.minNotchFlank, accuracy: 0.001)
        XCTAssertEqual(narrow.height, NotchHomeZoneLayout.railHeight + notch.height, accuracy: 0.001)

        // Wide content → the panel hugs the content width (above the notch floor).
        let wide = NotchHomeZoneAnchor.attachedPanelRect(
            contentSize: CGSize(width: 900, height: NotchHomeZoneLayout.railHeight),
            notch: notch, screenFrame: screen)
        XCTAssertEqual(wide.width, 900, accuracy: 0.001)
        XCTAssertEqual(wide.maxY, notch.maxY, accuracy: 0.001)
    }

    /// The attached live zone is one contiguous region spanning the panel, the nub, AND the notch band, so a
    /// cursor moving UP into the notch docks (never grace-dismisses) — the attached analogue of `liveZoneRect`.
    func testAttachedLiveZoneUnionsNotchAndDocks() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)
        let nub = NotchHomeZoneAnchor.attachedNubRect(size: CGSize(width: 120, height: 10),
                                                      notch: notch, screenFrame: screen)
        let panel = NotchHomeZoneAnchor.attachedPanelRect(
            contentSize: CGSize(width: 600, height: NotchHomeZoneLayout.railHeight),
            notch: notch, screenFrame: screen)
        let live = NotchHomeZoneAnchor.attachedLiveZone(nub: nub, panel: panel, notch: notch)

        XCTAssertGreaterThanOrEqual(live.maxY, notch.maxY - 0.001)          // extends up to the physical top
        XCTAssertTrue(live.contains(CGPoint(x: notch.midX, y: notch.midY))) // the notch band is inside
        XCTAssertTrue(live.contains(CGPoint(x: panel.midX, y: panel.midY))) // the panel is inside

        // The reveal model keeps the panel open for a cursor anywhere in the notch band, past grace.
        let model = NotchRevealModel(graceInterval: 0.25)
        XCTAssertEqual(model.feed(cursor: CGPoint(x: nub.midX, y: nub.midY),
                                  zoneRect: nub, railFrame: panel, liveZone: live, now: 0), .reveal)
        XCTAssertEqual(model.feed(cursor: CGPoint(x: notch.midX, y: notch.midY),
                                  zoneRect: nub, railFrame: panel, liveZone: live, now: 5.0), .reveal)
    }

    // MARK: - 5.4 AppSettings keys

    func testAgentParkSettingsDefaultsAndReset() {
        let defaults = UserDefaults(suiteName: "tfs-parked-settings-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.agentMaxParkedSessions, 6)
        XCTAssertEqual(settings.agentParkIdleTimeout, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(settings.agentParkAutoDismissCountdown, 300, accuracy: 0.5)
        XCTAssertEqual(settings.agentOverscrollParkThreshold, 0.22, accuracy: 0.0001)
        // Flick scroll-vs-flick tuning (D4): defaults + reset round-trip.
        XCTAssertEqual(settings.flickVelocityThreshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.flickLiftWindow, 0.12, accuracy: 0.0001)
        settings.agentMaxParkedSessions = 99
        settings.agentParkIdleTimeout = 5
        settings.agentParkAutoDismissCountdown = 42
        settings.agentOverscrollParkThreshold = 0.5
        settings.flickVelocityThreshold = 1.5
        settings.flickLiftWindow = 0.3
        settings.resetToDefaults()
        XCTAssertEqual(settings.agentMaxParkedSessions, 6)
        XCTAssertEqual(settings.agentParkIdleTimeout, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(settings.agentParkAutoDismissCountdown, 300, accuracy: 0.5)
        XCTAssertEqual(settings.agentOverscrollParkThreshold, 0.22, accuracy: 0.0001)
        XCTAssertEqual(settings.flickVelocityThreshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.flickLiftWindow, 0.12, accuracy: 0.0001)
    }

    // MARK: - 7/8. ParkController glue (the app-side scheduler/store/rail coordinator)

    func testParkControllerParkUpsertsAndRepublishes() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id, "Draft"))
        // Stored under the same identity and visible to the scheduler/rail.
        XCTAssertNotNil(store.conversation(id))
        XCTAssertEqual(store.all().first?.title, "Draft")
        XCTAssertEqual(store.all().first?.state, .parked)
        XCTAssertEqual(ctrl.notch.overlayModelSessionsForTest.count, 1)
    }

    func testParkControllerRestoreHandsConversationAndRemovesAtSource() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        // Park, then simulate a (non-terminal) background result (badge bumped, state idle).
        ctrl.park(conversation(id, "Draft"))
        ctrl.didAdvance(id, result: ToolStepResult(tool: "t", status: .done, summary: "ok"))
        XCTAssertGreaterThan(store.all().first?.badgeCount ?? 0, 0)

        var handed: AgentConversation?
        ctrl.onRestoreConversation = { handed = $0 }
        ctrl.restore(id)
        // The stored conversation was handed back (same identity); the durable row is REMOVED AT SOURCE
        // (Bug 1 / D3) — the canvas now owns it, so no orphaned `.active` row survives.
        XCTAssertEqual(handed?.id, id)
        XCTAssertNil(store.conversation(id))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)
    }

    func testParkControllerDiscardRemoves() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id))
        ctrl.discard(id)
        XCTAssertNil(store.conversation(id))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)   // rail view-model cleared (Bug 1)
    }

    /// Bug 1 / D3: park → restore (durable row removed at source) → dismiss the restored canvas through the
    /// authoritative `discard(_:)` path → EVERY layer is purged (store, scheduler, rail view-model).
    func testRestoreThenDismissPurgesAllLayers() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id, "Draft"))
        XCTAssertEqual(store.all().first?.state, .parked)

        // Restore: the row is removed at source; capture the conversation the canvas re-binds to.
        var handed: AgentConversation?
        ctrl.onRestoreConversation = { handed = $0 }
        ctrl.restore(id)
        XCTAssertEqual(handed?.id, id)

        // Simulate the restored-canvas dismissal through the authoritative path (the AppCoordinator seam).
        ctrl.discard(id)

        XCTAssertNil(store.conversation(id))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(ctrl.parkScheduler.runnableSessions(now: Date(), maxSlots: 8).isEmpty)
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)
    }

    /// Bug 1 / D3 relaunch invariant: a discarded restored session must NOT be rebuilt from disk on a
    /// fresh store over the same directory.
    func testDiscardedSessionDoesNotSurviveRelaunch() {
        let dir = tempDir()
        let id = sid()
        do {
            let store = DiskParkedSessionStore(directory: dir)
            let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
            ctrl.park(conversation(id, "Persist"))
            ctrl.onRestoreConversation = { _ in }
            ctrl.restore(id)     // removes at source
            ctrl.discard(id)     // authoritative dismissal (idempotent here)
        }
        // A fresh store over the SAME dir must rebuild EMPTY (the discarded row left no file behind).
        let reopened = DiskParkedSessionStore(directory: dir)
        XCTAssertTrue(reopened.all().isEmpty)
        XCTAssertNil(reopened.conversation(id))
    }

    /// Bug 3 / D1: a TERMINAL background `.done` (`taskComplete: true`) auto-dismisses the row FOREVER on
    /// the spot — a finished task never lingers on the rail.
    func testTerminalDoneAutoDismisses() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id, "Finish"))
        ctrl.didAdvance(id, result: ToolStepResult(tool: "t", status: .done, summary: "ok"),
                        taskComplete: true)
        XCTAssertNil(store.conversation(id))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)
    }

    /// Bug 3 / D1: an INTERMEDIATE `.done` (`taskComplete: false`) keeps the row (idle + badge) so the
    /// session stays available — only a finished task auto-dismisses.
    func testIntermediateDoneDoesNotDismiss() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id, "Step"))
        ctrl.didAdvance(id, result: ToolStepResult(tool: "t", status: .done, summary: "ok"),
                        taskComplete: false)
        XCTAssertNotNil(store.conversation(id))
        XCTAssertEqual(store.all().first?.state, .idle)
        XCTAssertGreaterThan(store.all().first?.badgeCount ?? 0, 0)
    }

    func testParkControllerEscalateSetsNeedsYouForGlow() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        let id = sid()
        ctrl.park(conversation(id))
        ctrl.escalate(id, reason: "dangerous write")
        XCTAssertEqual(store.all().first?.state, .needsYou)
        // The rail view-model reflects needs-you → the controller lights the ambient glow.
        XCTAssertTrue(ctrl.notch.hasNeedsYouForTest)
    }

    func testParkControllerSchedulerSeamIsKReady() {
        let store = InMemoryParkedSessionStore()
        let ctrl = ParkController(store: store, maxParked: 6, autoDismissCountdown: 60)
        ctrl.park(conversation(sid()))
        ctrl.park(conversation(sid()))
        // The exposed seam is the SerialParkScheduler: one active now regardless of slots, but the protocol
        // shape serves K (the batched runtime fills more) with no change.
        XCTAssertLessThanOrEqual(ctrl.parkScheduler.runnableSessions(now: Date(), maxSlots: 1).count, 1)
        XCTAssertLessThanOrEqual(ctrl.parkScheduler.runnableSessions(now: Date(), maxSlots: 8).count, 1)
    }
}
