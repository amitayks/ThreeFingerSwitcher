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

    // MARK: - 5. Anchor + reveal models (overscroll-park was removed by `notch-native-conversations`:
    // sessions are born at the notch; the launcher canvas is one-shot-only and never parks)

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

    /// The dock is NON-scrollable and sizes to HUG every rendered card — the persistent "+ New chat" card
    /// PLUS one per session (the `sessions.count + 1` the controller passes) — so it EXPANDS as sessions are
    /// added and never scrolls within the parked-session cap.
    func testRailHugsNewChatCardAndExpandsWithoutScrolling() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)     // this Mac's default visible frame

        // 2 sessions render 3 cards (new-chat + 2): the panel must hug all 3, no scroll.
        let two = NotchHomeZoneLayout.solve(count: 2 + 1, visibleFrame: visible)
        XCTAssertEqual(two.contentSize.width, NotchHomeZoneLayout.naturalWidth(count: 3), accuracy: 0.001)
        XCTAssertFalse(two.overflowsHorizontally)

        // The full parked cap (6 sessions → 7 cards) still hugs without overflowing on a 14".
        let full = NotchHomeZoneLayout.solve(count: 6 + 1, visibleFrame: visible)
        XCTAssertFalse(full.overflowsHorizontally)
        XCTAssertGreaterThan(full.contentSize.width, two.contentSize.width)   // expands with more sessions
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

    /// The attached rail panel is sized so that centering the card row yields SYMMETRIC vertical padding of
    /// `notch.height + railNotchClearance` on top and bottom — the cards clear the notch by the small
    /// clearance and sit balanced (not shoved to the bottom).
    func testAttachedRailCentersCardsWithNotchClearance() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)
        let contentH = NotchHomeZoneLayout.attachedRailContentHeight(notchHeight: notch.height)
        let panel = NotchHomeZoneAnchor.attachedPanelRect(
            contentSize: CGSize(width: NotchHomeZoneLayout.oneCardWidth, height: contentH),
            notch: notch, screenFrame: screen)

        // Total panel = card + 2*(notch + clearance).
        let expectedTotal = NotchHomeZoneLayout.cardHeight + 2 * (notch.height + NotchHomeZoneLayout.railNotchClearance)
        XCTAssertEqual(panel.height, expectedTotal, accuracy: 0.001)
        // Centering the card row gives equal top/bottom padding = notch + clearance (symmetric, balanced).
        let vPad = (panel.height - NotchHomeZoneLayout.cardHeight) / 2
        XCTAssertEqual(vPad, notch.height + NotchHomeZoneLayout.railNotchClearance, accuracy: 0.001)
        // …so the visible gap below the notch is exactly the small clearance (cards clear the notch).
        XCTAssertEqual(vPad - notch.height, NotchHomeZoneLayout.railNotchClearance, accuracy: 0.001)
        XCTAssertEqual(panel.maxY, notch.maxY, accuracy: 0.001)     // still welded to the physical top
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

    /// The reveal TRIGGER in attached mode is the physical notch cutout (extended down by the small
    /// cross-tolerance), welded to the physical top — so the rail reveals only when the cursor crosses UP
    /// behind the notch, never on the resting nub below it.
    func testNotchTriggerRectIsTheCutoutBehindTheNotch() {
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)
        let trigger = NotchHomeZoneAnchor.notchTriggerRect(notch: notch)
        XCTAssertEqual(trigger.maxY, notch.maxY, accuracy: 0.001)                    // top welded to the physical top
        XCTAssertEqual(trigger.midX, notch.midX, accuracy: 0.5)                      // centered on the notch
        XCTAssertEqual(trigger.width, notch.width, accuracy: 0.001)                  // spans the cutout width
        XCTAssertEqual(trigger.minY, notch.minY - NotchHomeZoneAnchor.notchCrossTolerance, accuracy: 0.001)
        XCTAssertTrue(trigger.contains(CGPoint(x: notch.midX, y: notch.midY)))       // behind the notch → triggers
        XCTAssertTrue(trigger.contains(CGPoint(x: notch.midX, y: notch.minY)))       // right at the notch edge → triggers
    }

    /// The notchless/external reveal trigger is a thin band hugging the physical top edge at top-center,
    /// spanning from just under the menu bar up to the physical top — the "slam to the top edge" mimic.
    func testTopEdgeTriggerRectHugsPhysicalTop() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 876)               // 24pt menu bar
        let trigger = NotchHomeZoneAnchor.topEdgeTriggerRect(width: 120, visibleFrame: visible, screenFrame: screen)
        XCTAssertEqual(trigger.minY, visible.maxY, accuracy: 0.001)              // bottom just under the menu bar
        XCTAssertEqual(trigger.maxY, screen.maxY, accuracy: 0.001)              // top at the physical top edge
        XCTAssertEqual(trigger.midX, visible.midX, accuracy: 0.5)              // centered
        XCTAssertEqual(trigger.width, 120, accuracy: 0.001)
    }

    /// The behavioral heart of the change: fed the notch cutout as its trigger, the reveal model reveals
    /// ONLY when the cursor is behind the notch — a cursor on the resting nub *below* the notch (while
    /// hidden) does NOT reveal (`.idle`); crossing UP into the notch does (`.reveal`).
    func testRevealFiresOnlyBehindNotchNotOnNub() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let notch = CGRect(x: 620, y: 862, width: 200, height: 38)
        let nub = NotchHomeZoneAnchor.attachedNubRect(size: CGSize(width: 120, height: 10),
                                                      notch: notch, screenFrame: screen)
        let trigger = NotchHomeZoneAnchor.notchTriggerRect(notch: notch)
        let live = NotchHomeZoneAnchor.attachedLiveZone(nub: nub, panel: nil, notch: notch)
        let model = NotchRevealModel(graceInterval: 0.25)

        // Cursor grazing the nub BELOW the notch while hidden → no reveal (the whole point of the change).
        XCTAssertEqual(model.feed(cursor: CGPoint(x: nub.midX, y: nub.midY),
                                  zoneRect: trigger, railFrame: nil, liveZone: live, now: 0), .idle)
        // Cursor crosses UP behind the notch → reveal.
        XCTAssertEqual(model.feed(cursor: CGPoint(x: notch.midX, y: notch.midY),
                                  zoneRect: trigger, railFrame: nil, liveZone: live, now: 0.1), .reveal)
        // Now shown, dropping back down onto the nub keeps it open (the nub is inside the live zone).
        XCTAssertEqual(model.feed(cursor: CGPoint(x: nub.midX, y: nub.midY),
                                  zoneRect: trigger, railFrame: nil, liveZone: live, now: 0.2), .reveal)
    }

    /// The reveal DWELL (Hub-configurable): with a non-zero dwell the cursor must stay in the trigger
    /// CONTINUOUSLY for the dwell before the rail reveals; leaving the trigger cancels an in-progress dwell
    /// (a re-entry restarts it); once shown, keep-open is instant (no dwell).
    func testRevealDwellDelaysRevealAndCancelsOnLeave() {
        let trigger = CGRect(x: 100, y: 800, width: 120, height: 32)
        let inside = CGPoint(x: trigger.midX, y: trigger.midY)
        let outside = CGPoint(x: 5, y: 5)

        let model = NotchRevealModel(graceInterval: 0.25, dwellInterval: 0.3)
        // Enter the trigger → dwelling, nothing shown yet.
        XCTAssertEqual(model.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0), .idle)
        XCTAssertTrue(model.isDwelling)
        XCTAssertEqual(model.state, .hidden)
        // Before the dwell elapses → still idle.
        XCTAssertEqual(model.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0.2), .idle)
        XCTAssertEqual(model.state, .hidden)
        // Past the dwell → reveals, dwell cleared.
        XCTAssertEqual(model.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0.31), .reveal)
        XCTAssertEqual(model.state, .shown)
        XCTAssertFalse(model.isDwelling)

        // Leaving the trigger mid-dwell cancels it; a re-entry restarts the countdown from that moment.
        let m2 = NotchRevealModel(graceInterval: 0.25, dwellInterval: 0.3)
        XCTAssertEqual(m2.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0), .idle)
        XCTAssertTrue(m2.isDwelling)
        XCTAssertEqual(m2.feed(cursor: outside, zoneRect: trigger, railFrame: nil, now: 0.1), .idle)   // left → cancel
        XCTAssertFalse(m2.isDwelling)
        XCTAssertEqual(m2.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0.2), .idle)    // re-enter → restart
        XCTAssertEqual(m2.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0.45), .idle)   // 0.25 since restart < 0.3
        XCTAssertEqual(m2.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0.51), .reveal) // 0.31 since restart

        // A zero dwell reveals immediately (the model default, preserving pre-dwell behavior).
        let instant = NotchRevealModel(graceInterval: 0.25)   // dwellInterval defaults to 0
        XCTAssertEqual(instant.feed(cursor: inside, zoneRect: trigger, railFrame: nil, now: 0), .reveal)
    }

    // MARK: - 5.4 AppSettings keys

    func testAgentParkSettingsDefaultsAndReset() {
        let defaults = UserDefaults(suiteName: "tfs-parked-settings-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.agentMaxParkedSessions, 6)
        XCTAssertEqual(settings.agentParkIdleTimeout, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(settings.agentParkAutoDismissCountdown, 300, accuracy: 0.5)
        XCTAssertEqual(settings.agentOverscrollParkThreshold, 0.22, accuracy: 0.0001)
        XCTAssertEqual(settings.agentNotchRevealDwell, 0.3, accuracy: 0.0001)
        // Flick scroll-vs-flick tuning (D4): defaults + reset round-trip.
        XCTAssertEqual(settings.flickVelocityThreshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.flickLiftWindow, 0.12, accuracy: 0.0001)
        settings.agentMaxParkedSessions = 99
        settings.agentParkIdleTimeout = 5
        settings.agentParkAutoDismissCountdown = 42
        settings.agentOverscrollParkThreshold = 0.5
        settings.agentNotchRevealDwell = 0.75
        settings.flickVelocityThreshold = 1.5
        settings.flickLiftWindow = 0.3
        settings.resetToDefaults()
        XCTAssertEqual(settings.agentMaxParkedSessions, 6)
        XCTAssertEqual(settings.agentParkIdleTimeout, 30 * 60, accuracy: 0.5)
        XCTAssertEqual(settings.agentParkAutoDismissCountdown, 300, accuracy: 0.5)
        XCTAssertEqual(settings.agentOverscrollParkThreshold, 0.22, accuracy: 0.0001)
        XCTAssertEqual(settings.agentNotchRevealDwell, 0.3, accuracy: 0.0001)
        XCTAssertEqual(settings.flickVelocityThreshold, 0.8, accuracy: 0.0001)
        XCTAssertEqual(settings.flickLiftWindow, 0.12, accuracy: 0.0001)
    }

    // MARK: - 7/8. ParkController glue (`notch-native-conversations`: sessions born at the notch,
    // expanded in place, collapsed back to background — no canvas park/restore bridge)

    private final class NullSelection: SelectionProviding {
        func readSelectedText() async -> String? { nil }
        func readClipboardText() -> String? { nil }
        func readClipboardImage() -> Data? { nil }
        @discardableResult func replaceSelection(_ text: String) async -> Bool { true }
        @discardableResult func pasteAtCursor(_ text: String) async -> Bool { true }
    }
    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        let payload: Data; init(payload: Data) { self.payload = payload }
        func download(_ d: ModelDescriptor, to dest: URL, progress: @Sendable (Double) -> Void) async throws -> Data { progress(1); return payload }
    }
    /// A loaded manager whose runtime factory returns `runtime` (for glue tests that RUN turns).
    private func loadedManager(_ runtime: LLMRuntime) async throws -> ModelManager {
        let payload = Data("w".utf8)
        let registry = ModelCatalog(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text, .vision], quantization: .qat4bit)], defaultModelID: "m")
        let m = ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: true,
                             storageRoot: tempDir(), runtimeFactory: { _ in runtime })
        try await m.downloadAndVerify(registry.models[0]); return m
    }
    /// A cold manager for glue tests that never run a turn (session verbs only).
    private func coldManager() -> ModelManager {
        let payload = Data("w".utf8)
        let registry = ModelCatalog(models: [ModelDescriptor(id: "m", displayName: "M", sizeBytes: 1,
            integritySHA: ModelManager.sha256Hex(payload), downloadURL: URL(string: "https://x.invalid/m")!,
            capabilities: [.text], quantization: .qat4bit)], defaultModelID: "m")
        return ModelManager(registry: registry, downloader: FakeDownloader(payload: payload), optedIn: false,
                            storageRoot: tempDir(), runtimeFactory: { _ in StubLLMRuntime(interTokenDelayNanos: 0) })
    }
    private func makeCtrl(store: ParkedSessionStore, manager: ModelManager? = nil,
                          audit: AuditLog? = nil) -> ParkController {
        let m = manager ?? coldManager()
        return ParkController(store: store, maxParked: 6, autoDismissCountdown: 60,
                              engineFactory: { NotchSessionEngine(modelManager: m, selection: NullSelection()) },
                              auditLog: audit)
    }
    private func waitUntil(_ p: @MainActor () -> Bool, _ timeout: TimeInterval = 3,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !p() && Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(p(), "condition not met", file: file, line: line)
    }
    /// Seed a stored session directly (the pre-existing-sessions path a relaunch would produce).
    private func seedStored(_ store: ParkedSessionStore, _ id: AgentSessionID, _ title: String = "T",
                            state: ParkState = .idle, badge: Int = 0) {
        try? store.upsert(ParkedSession(id: id, title: title, state: state, badgeCount: badge,
                                        nextRunAt: nil, updatedAt: Date()),
                          conversation: conversation(id, title))
    }

    func testNewSessionIsDurableAtBirthAndExpanded() {
        let store = InMemoryParkedSessionStore()
        let ctrl = makeCtrl(store: store)
        let id = ctrl.newSession()
        // Durable at birth: the conversation + row exist BEFORE any turn ran.
        XCTAssertNotNil(store.conversation(id))
        XCTAssertEqual(store.all().first?.id, id)
        XCTAssertEqual(store.all().first?.state, .active, "the expanded (foreground) row is .active")
        XCTAssertEqual(store.all().first?.badgeCount, 0)
        XCTAssertEqual(ctrl.expandedID, id)
        XCTAssertNotNil(ctrl.engineForTest(id), "an engine is bound to the newborn session")
        XCTAssertEqual(ctrl.engineForTest(id)?.conversation?.id, id)
    }

    func testExpandBindsStoredConversationAndClearsBadge() {
        let store = InMemoryParkedSessionStore()
        let id = sid()
        seedStored(store, id, "Draft", state: .idle, badge: 3)
        let ctrl = makeCtrl(store: store)

        ctrl.expand(id)
        XCTAssertEqual(ctrl.expandedID, id)
        XCTAssertEqual(store.all().first?.state, .active, "an expanded session's row is foreground-active")
        XCTAssertEqual(store.all().first?.badgeCount, 0, "expanding clears the unseen-result badge")
        XCTAssertEqual(ctrl.engineForTest(id)?.conversation?.id, id, "the engine bound the stored conversation")
        XCTAssertNotNil(store.conversation(id), "expand NEVER removes the durable row (sessions never leave the notch)")
    }

    func testExpandNeedsYouClearsGlowViaRepublish() {
        let store = InMemoryParkedSessionStore()
        let id = sid()
        seedStored(store, id, "Esc", state: .needsYou, badge: 1)
        let ctrl = makeCtrl(store: store)
        XCTAssertTrue(ctrl.notch.hasNeedsYouForTest, "seeded needs-you lights the glow")

        ctrl.expand(id)
        XCTAssertFalse(ctrl.notch.hasNeedsYouForTest,
                       "expanding the last needs-you session clears the ambient glow (the addressing begins)")
    }

    func testCollapseIdlePersistsAndDropsEngine() {
        let store = InMemoryParkedSessionStore()
        let ctrl = makeCtrl(store: store)
        let id = ctrl.newSession()

        ctrl.collapse()
        XCTAssertNil(ctrl.expandedID)
        XCTAssertEqual(store.all().first?.state, .idle, "a collapsed idle session returns to the background set")
        XCTAssertNotNil(store.conversation(id), "collapse persists the conversation")
        XCTAssertNil(ctrl.engineForTest(id), "an idle collapsed session holds no engine (recreated on expand)")
    }

    func testCollapseMidTurnKeepsTurnRunningThenBadges() async throws {
        let stub = StubLLMRuntime(scriptedTokens: Array(repeating: "x", count: 40),
                                  interTokenDelayNanos: 5_000_000)
        let manager = try await loadedManager(stub)
        let store = InMemoryParkedSessionStore()
        let ctrl = makeCtrl(store: store, manager: manager)
        let id = ctrl.newSession()
        let engine = try XCTUnwrap(ctrl.engineForTest(id))

        engine.send("U1")
        await waitUntil { if case .conversing = engine.state { return true }; return false }

        ctrl.collapse()   // the load-bearing contract: does NOT cancel the in-flight turn
        XCTAssertNil(ctrl.expandedID)
        XCTAssertEqual(store.all().first?.state, .active,
                       "a collapsed-mid-turn session stays .active (never handed to the background scheduler)")
        XCTAssertNotNil(ctrl.engineForTest(id), "the engine stays alive detached until the turn settles")

        // The detached turn settles: conversation persisted with the assistant turn, row idles + badges.
        await waitUntil({ store.conversation(id)?.messages.count == 2 }, 5)
        XCTAssertEqual(store.all().first?.state, .idle)
        XCTAssertEqual(store.all().first?.badgeCount, 1, "the settled background turn is an unseen result")
        XCTAssertNil(ctrl.engineForTest(id), "the detached engine is dropped once its turn settled")
        XCTAssertFalse(stub.observedCancellation, "collapse never cancelled the turn")
    }

    func testExpandAnotherCollapsesCurrentFirst() {
        let store = InMemoryParkedSessionStore()
        let a = sid(); let b = sid()
        seedStored(store, a, "A"); seedStored(store, b, "B")
        let ctrl = makeCtrl(store: store)

        ctrl.expand(a)
        XCTAssertEqual(ctrl.expandedID, a)
        ctrl.expand(b)
        XCTAssertEqual(ctrl.expandedID, b, "exactly one session is expanded at a time")
        XCTAssertEqual(store.all().first { $0.id == a }?.state, .idle, "the previous session collapsed to idle")
        XCTAssertEqual(store.all().first { $0.id == b }?.state, .active)
        XCTAssertNil(ctrl.engineForTest(a), "the previous session's idle engine was dropped")
    }

    func testDiscardRemovesEverywhereIncludingExpanded() {
        let store = InMemoryParkedSessionStore()
        let ctrl = makeCtrl(store: store)
        let id = ctrl.newSession()

        ctrl.discard(id)
        XCTAssertNil(store.conversation(id))
        XCTAssertTrue(store.all().isEmpty)
        XCTAssertNil(ctrl.expandedID, "discarding the expanded session collapses the panel")
        XCTAssertNil(ctrl.engineForTest(id))
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)   // rail view-model cleared
    }

    /// The relaunch half of durable-at-birth: a session created moments before quit — no completed turn —
    /// rebuilds from disk; a discarded one does not.
    func testJustBornSessionSurvivesRelaunchAndDiscardedDoesNot() {
        let dir = tempDir()
        let born: AgentSessionID
        let discarded: AgentSessionID
        do {
            let store = DiskParkedSessionStore(directory: dir)
            let ctrl = makeCtrl(store: store)
            born = ctrl.newSession()
            ctrl.collapse()
            discarded = ctrl.newSession()
            ctrl.discard(discarded)
        }
        let reopened = DiskParkedSessionStore(directory: dir)
        XCTAssertNotNil(reopened.conversation(born), "a just-born session survives relaunch")
        XCTAssertEqual(reopened.all().map(\.id), [born])
        XCTAssertNil(reopened.conversation(discarded), "a deleted session leaves nothing behind")
    }

    /// The quick-action firewall (`ai-command-band` delta): a one-shot fire has NO session machinery at
    /// all — nothing it does can reach the notch store/scheduler (they are not even connected; the
    /// executor lost its conversation/park seams in the revert). The store stays empty across a full fire.
    func testQuickActionsNeverTouchTheNotchStore() async throws {
        let store = InMemoryParkedSessionStore()
        let ctrl = makeCtrl(store: store)
        _ = ctrl   // the live rail exists; a quick action must never populate it

        let stub = StubLLMRuntime(scriptedTokens: ["fixed"], interTokenDelayNanos: 0)
        let manager = try await loadedManager(stub)
        final class Sel: SelectionProviding {
            func readSelectedText() async -> String? { "teh txt" }
            func readClipboardText() -> String? { nil }
            func readClipboardImage() -> Data? { nil }
            @discardableResult func replaceSelection(_ text: String) async -> Bool { true }
            @discardableResult func pasteAtCursor(_ text: String) async -> Bool { true }
        }
        final class Disp: TaskDispatching {
            func prepare(_ kind: TaskKind, resolvedPrompt: String, source: TaskSource, reasoning: Bool) async -> TaskReview { .unavailable(reason: "unused") }
            func execute(_ review: TaskReview) async throws {}
        }
        let executor = AICommandExecutor(modelManager: manager, selection: Sel(), dispatcher: Disp())
        let command = AICommand(name: "Fix", icon: .emoji("✍️"), input: .selection,
                                promptTemplate: "Fix: {input}", output: .previewOnly)
        executor.fire(command)
        await waitUntil { if case .ready = executor.state { return true }; return false }
        try await executor.commit()

        XCTAssertTrue(store.all().isEmpty, "a full quick-action fire+commit left no notch dock row")
        XCTAssertTrue(ctrl.notch.overlayModelSessionsForTest.isEmpty)
    }

    /// Bug 3 / D1 (unchanged by the pivot): a TERMINAL background `.done` (`taskComplete: true`)
    /// auto-dismisses the row FOREVER on the spot — a finished task never lingers on the rail.
    func testTerminalDoneAutoDismisses() {
        let store = InMemoryParkedSessionStore()
        let id = sid()
        seedStored(store, id, "Finish", state: .parked)
        let ctrl = makeCtrl(store: store)
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
        let id = sid()
        seedStored(store, id, "Step", state: .parked)
        let ctrl = makeCtrl(store: store)
        ctrl.didAdvance(id, result: ToolStepResult(tool: "t", status: .done, summary: "ok"),
                        taskComplete: false)
        XCTAssertNotNil(store.conversation(id))
        XCTAssertEqual(store.all().first?.state, .idle)
        XCTAssertGreaterThan(store.all().first?.badgeCount ?? 0, 0)
    }

    func testParkControllerEscalateSetsNeedsYouForGlow() {
        let store = InMemoryParkedSessionStore()
        let id = sid()
        seedStored(store, id, state: .parked)
        let ctrl = makeCtrl(store: store)
        ctrl.escalate(id, reason: "dangerous write")
        XCTAssertEqual(store.all().first?.state, .needsYou)
        // The rail view-model reflects needs-you → the controller lights the ambient glow.
        XCTAssertTrue(ctrl.notch.hasNeedsYouForTest)
    }

    func testParkControllerSchedulerSeamIsKReady() {
        let store = InMemoryParkedSessionStore()
        seedStored(store, sid(), state: .parked)
        seedStored(store, sid(), state: .parked)
        let ctrl = makeCtrl(store: store)
        // The exposed seam is the SerialParkScheduler: one active now regardless of slots, but the protocol
        // shape serves K (the batched runtime fills more) with no change.
        XCTAssertLessThanOrEqual(ctrl.parkScheduler.runnableSessions(now: Date(), maxSlots: 1).count, 1)
        XCTAssertLessThanOrEqual(ctrl.parkScheduler.runnableSessions(now: Date(), maxSlots: 8).count, 1)
    }

    // MARK: - 9. Purge-delete + the expanded-state choke point (`notch-conversation-gestures`)

    private func auditRecord(_ s: AgentSessionID, tool: String) -> AuditRecord {
        AuditRecord(sessionID: s, tool: tool, policy: .auto, argumentsSummary: "a",
                    outcome: .done, wasBackground: true, timestamp: Date(timeIntervalSince1970: 1))
    }

    func testPurgeRemovesStoreEngineAndAuditWhilePlainDiscardKeepsLedger() {
        let store = InMemoryParkedSessionStore()
        let audit = InMemoryAuditLog(cap: 100)
        let ctrl = makeCtrl(store: store, audit: audit)

        let purged = ctrl.newSession()
        ctrl.collapse()
        let kept = ctrl.newSession()
        ctrl.collapse()
        audit.record(auditRecord(purged, tool: "p1"))
        audit.record(auditRecord(kept, tool: "k1"))
        audit.record(auditRecord(purged, tool: "p2"))

        ctrl.expand(purged)
        ctrl.purge(purged)
        // Everything about the purged session is gone: row, conversation, engine, audit records.
        XCTAssertNil(store.conversation(purged))
        XCTAssertNil(ctrl.engineForTest(purged))
        XCTAssertNil(ctrl.expandedID, "purging the expanded session collapses the panel")
        XCTAssertEqual(audit.recent(limit: 10).map(\.tool), ["k1"],
                       "only the purged session's ledger entries vanish")

        // A PLAIN discard on the sibling keeps its ledger entries (the purge is the single carve-out).
        ctrl.discard(kept)
        XCTAssertNil(store.conversation(kept))
        XCTAssertEqual(audit.recent(limit: 10).map(\.tool), ["k1"],
                       "a plain delete leaves the audit ledger intact")
    }

    func testOnExpandedChangedFiresOnTransitionsWithoutBlips() {
        let store = InMemoryParkedSessionStore()
        let a = sid(); let b = sid()
        seedStored(store, a, "A"); seedStored(store, b, "B")
        let ctrl = makeCtrl(store: store)
        var published: [Bool] = []
        ctrl.onExpandedChanged = { published.append($0) }

        ctrl.expand(a)
        XCTAssertEqual(published, [true])
        ctrl.expand(b)
        XCTAssertEqual(published, [true], "expand-another stays expanded — no false blip")
        ctrl.collapse()
        XCTAssertEqual(published, [true, false])
        _ = ctrl.newSession()
        XCTAssertEqual(published, [true, false, true], "a new session expands")
        ctrl.discard(ctrl.expandedID!)
        XCTAssertEqual(published, [true, false, true, false], "discarding the expanded session publishes false")
        ctrl.expand(a)
        XCTAssertEqual(published, [true, false, true, false, true])
        ctrl.setEnabled(false)
        XCTAssertEqual(published, [true, false, true, false, true, false], "feature-off collapses and publishes")
    }
}
