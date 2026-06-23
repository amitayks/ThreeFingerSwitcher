import Foundation
import AppKit

/// App-side coordinator that wires the pure `ai-parked-sessions` machinery (`SerialParkScheduler` +
/// `ParkedSessionStore` + `ParkLifecycleCoordinator`) to the `NotchHomeZoneController` rail and the
/// `AICommandExecutor`'s park/restore seam. This is the lifecycle/scheduler GLUE (design §7/§8): it owns
/// the one place the slot count is interpreted (the scheduler) and the durable store, and it republishes
/// the rail rows whenever the parked set changes.
///
/// Verification: the pure pieces are `swift test`-ed (scheduler one-active-now + K-ready, store round-trip,
/// lifecycle evict/sleep/discard); this controller is `xcodebuild` compile-verified and user-run-verified
/// for the live rail/glow/restore behavior in a stable-signed build.
@MainActor
final class ParkController {
    private let store: ParkedSessionStore
    private let scheduler: SerialParkScheduler
    private let lifecycle: ParkLifecycleCoordinator
    let notch: NotchHomeZoneController

    /// Hand a restored conversation to the canvas owner (`ai-conversational-canvas`) so it re-seeds the
    /// active canvas from the durable `AgentConversation` (keeping the same `AgentSessionID`). Injected by
    /// the coordinator; the controller does the rail-side mutations (state → active, badge → 0, glow clear).
    var onRestoreConversation: ((AgentConversation) -> Void)?

    init(store: ParkedSessionStore = DiskParkedSessionStore(),
         maxParked: Int,
         autoDismissCountdown: TimeInterval) {
        self.store = store
        self.scheduler = SerialParkScheduler(sessions: store.all())
        self.lifecycle = ParkLifecycleCoordinator(
            store: store,
            lifecycle: ParkLifecycle(maxParked: maxParked, autoDismissCountdown: autoDismissCountdown))
        self.notch = NotchHomeZoneController()
        self.notch.sessionsProvider = { [weak self] in self?.scheduler.snapshot() ?? [] }
        self.notch.onRestore = { [weak self] id in self?.restore(id) }
        self.notch.onDiscard = { [weak self] id in self?.discard(id) }
        self.notch.refresh()
    }

    /// Install/remove the cursor-reveal rail (gated by the agent-feature opt-in).
    func setEnabled(_ on: Bool) { notch.setEnabled(on) }

    // MARK: - Park (the overscroll-park handoff)

    /// Park a live conversation handed off from the canvas (`AICommandExecutor.onPark`): upsert it into the
    /// durable store under its own identity, seed/refresh the scheduler rows, run an eviction pass (the soft
    /// max-parked cap), and republish the rail. The in-flight turn is NOT cancelled here — the scheduler
    /// keeps advancing it. A store failure is mapped to `ParkError` at the boundary (the store's job) and
    /// surfaces as a bounded `.failed` rail badge, never a thrown crash and never silence.
    func park(_ conversation: AgentConversation) {
        let row = ParkedSession(
            id: conversation.id,
            title: conversation.title,
            state: .parked,
            badgeCount: 0,
            nextRunAt: nil,
            updatedAt: Date())
        do {
            try store.upsert(row, conversation: conversation)
        } catch {
            // The store already mapped + logged the failure; record it as a bounded failed row so the
            // user sees it on the rail (never an NSAlert, never raw text in the headline).
            recordFailedRow(row, error: error)
        }
        scheduler.setSessions(store.all())
        lifecycle.runEvictionPass(now: Date())
        scheduler.setSessions(store.all())
        notch.refresh()
    }

    // MARK: - Restore (pull a card back to the active canvas)

    /// Restore a parked session as the active canvas (Bug 1 / D3): the conversation moves back into the
    /// live canvas/executor, so the durable row is REMOVED AT SOURCE — restore never leaves an orphaned
    /// `.active` row in the store/scheduler (the leak that survived a relaunch). The canvas now OWNS the
    /// conversation; if the user parks it again, `park(_:)` re-upserts it under the SAME identity. The
    /// republish clears the ambient glow if this was the last `.needsYou` session.
    func restore(_ id: AgentSessionID) {
        guard let conversation = store.conversation(id) else { return }
        // Remove at source: a restored conversation is no longer parked. Cancels any pending background
        // turn (the canvas re-binds and the user drives it) and deletes the durable row so a later
        // dismiss/commit has nothing to orphan, and a relaunch never rebuilds it.
        try? lifecycle.discard(id)
        scheduler.setSessions(store.all())
        onRestoreConversation?(conversation)
        notch.refresh()
    }

    // MARK: - Discard (cancel pending, remove; completed side effects are NOT rolled back)

    /// The SINGLE authoritative removal path for ALL dismissals (Bug 1): cancel any pending generation,
    /// remove the durable conversation + rail row, re-seed the scheduler, and republish the rail.
    /// Idempotent — discarding an already-removed id (e.g. a restored conversation dismissed from the
    /// canvas) is a harmless no-op. Completed side effects are NOT rolled back.
    func discard(_ id: AgentSessionID) {
        try? lifecycle.discard(id)
        scheduler.setSessions(store.all())
        notch.refresh()
    }

    // MARK: - Scheduler feedback (background advance / escalation)

    /// Report a background-advance result back to the scheduler (called by the batched runtime via
    /// `runnableSessions`/`didAdvance`) and republish the rail. `taskComplete` (the bounded loop's
    /// `AgentLoopOutcome.isTaskComplete`) marks the row TERMINAL (`.completed`) on a `.done` step; the
    /// row is then auto-dismissed FOREVER on the spot via the authoritative discard path (design D1).
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult, taskComplete: Bool = false) {
        scheduler.didAdvance(id, result: result, taskComplete: taskComplete)
        persistRowSnapshot()
        // A terminal completion auto-dismisses immediately (the auto-dismiss pass removes every
        // `.completed` row regardless of age) so a finished task never lingers on the rail.
        if taskComplete { lifecycle.runAutoDismissPass(now: Date()) }
        scheduler.setSessions(store.all())
        notch.refresh()
    }

    /// Accept an escalation (`ai-background-autonomy`): set `.needsYou` + badge, persist, and light the
    /// ambient glow via the republish — never a modal.
    func escalate(_ id: AgentSessionID, reason: String) {
        scheduler.escalate(id, reason: reason)
        persistRowSnapshot()
        notch.refresh()
    }

    /// The scheduler seam the batched runtime fills (`runnableSessions(now:maxSlots:)`) — exposed so the
    /// batched-runtime slice can drive K slots with NO protocol change (one active now, K-ready).
    var parkScheduler: ParkScheduler { scheduler }

    // MARK: - Maintenance

    /// Run the auto-dismiss pass (design D1): every TERMINAL (`.completed`) session and every
    /// non-protected idle-past-countdown session is DISMISSED FOREVER through the authoritative
    /// `discard(_:)` path (cancel pending + remove + republish). Called on a coarse repeating timer by the
    /// owner (`AppCoordinator`). Republishes after. `now:` injected so the pass is deterministic in tests.
    @discardableResult
    func runAutoDismissPass(now: Date = Date()) -> [AgentSessionID] {
        let dismissed = lifecycle.runAutoDismissPass(now: now)
        scheduler.setSessions(store.all())
        notch.refresh()
        return dismissed
    }

    // MARK: - Helpers

    /// Persist the scheduler's current rows back to the store (after a `didAdvance`/`escalate` mutation) so
    /// the rail rebuilds correctly on relaunch.
    private func persistRowSnapshot() {
        for row in scheduler.snapshot() { try? store.upsertRow(row) }
    }

    private func recordFailedRow(_ row: ParkedSession, error: Error) {
        var failed = row
        failed.state = .idle
        failed.updatedAt = Date()
        try? store.upsertRow(failed)
    }
}
