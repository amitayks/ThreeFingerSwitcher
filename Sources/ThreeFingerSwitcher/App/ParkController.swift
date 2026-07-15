import Foundation
import AppKit

/// App-side coordinator for the NOTCH-NATIVE sessions (`ai-parked-sessions` + `notch-native-conversations`):
/// wires the pure machinery (`SerialParkScheduler` + `ParkedSessionStore` + `ParkLifecycleCoordinator`) to
/// the `NotchHomeZoneController` rail/expanded panel and owns the per-session `NotchSessionEngine`s. This is
/// the lifecycle/scheduler GLUE: it owns the one place the slot count is interpreted (the scheduler) and the
/// durable store, and it republishes the rail rows whenever the parked set changes.
///
/// Sessions are BORN here (durable at birth — `newSession()` upserts before the first turn), expanded in
/// place (`expand(id:)` binds an engine to the stored conversation), collapsed back to background
/// (`collapse()` persists WITHOUT cancelling an in-flight turn), and removed only by expiry (the
/// auto-dismiss pass) or deletion (`discard(_:)`, the single authoritative removal path). The launcher's
/// quick actions never reach this controller — they have no sessions at all.
///
/// Verification: the pure pieces are `swift test`-ed (scheduler one-active-now + K-ready, store round-trip,
/// lifecycle evict/expire/discard, and the session verbs via an injected engine factory); this controller is
/// `xcodebuild` compile-verified and user-run-verified for the live rail/expand/glow behavior.
@MainActor
final class ParkController {
    private let store: ParkedSessionStore
    private let scheduler: SerialParkScheduler
    private let lifecycle: ParkLifecycleCoordinator
    /// Builds a fresh conversation engine per session (injected so tests drive a stub runtime).
    private let engineFactory: () -> NotchSessionEngine
    /// The shared audit ledger, used ONLY by `purge(_:)` (`notch-conversation-gestures`): the
    /// purge-delete gesture erases the session's audit records everywhere; the plain `discard(_:)`
    /// never touches the ledger. Optional so existing call sites/tests stay source-compatible.
    private let auditLog: AuditLog?
    let notch: NotchHomeZoneController

    /// Fires whenever whether-a-conversation-is-expanded CHANGES (nil↔value on `expandedID`), from every
    /// path (new session, expand, expand-another, collapse, discard-of-expanded, feature-off). The
    /// coordinator drives `GestureRecognizer.notchConversationActive` off it — the single choke point, so
    /// the recognizer can never be left stuck in notch mode. An expand-another (a→b) publishes NO blip
    /// (the state stays "expanded"); the publish compares against the last published value.
    var onExpandedChanged: ((Bool) -> Void)?
    private var lastPublishedExpanded = false

    /// The per-session engines that currently exist: the expanded (foreground) session's engine, plus any
    /// collapsed session whose foreground turn is still streaming (collapse does NOT cancel — the engine
    /// stays alive detached until the turn settles, then is dropped). Exactly ONE session is expanded at a
    /// time; an idle collapsed session has no engine (recreated on the next expand).
    private var engines: [AgentSessionID: NotchSessionEngine] = [:]
    /// The session currently expanded in the notch panel, if any.
    private(set) var expandedID: AgentSessionID?

    init(store: ParkedSessionStore = DiskParkedSessionStore(),
         maxParked: Int,
         autoDismissCountdown: TimeInterval,
         revealDwell: TimeInterval = 0,
         engineFactory: @escaping () -> NotchSessionEngine,
         auditLog: AuditLog? = nil) {
        self.store = store
        self.auditLog = auditLog
        self.scheduler = SerialParkScheduler(sessions: store.all())
        self.lifecycle = ParkLifecycleCoordinator(
            store: store,
            lifecycle: ParkLifecycle(maxParked: maxParked, autoDismissCountdown: autoDismissCountdown))
        self.engineFactory = engineFactory
        self.notch = NotchHomeZoneController()
        self.notch.setRevealDwell(revealDwell)
        self.notch.sessionsProvider = { [weak self] in self?.scheduler.snapshot() ?? [] }
        self.notch.onExpand = { [weak self] id in self?.expand(id) }
        self.notch.onNewSession = { [weak self] in self?.newSession() }
        self.notch.onCollapse = { [weak self] in self?.collapse() }
        self.notch.onDiscard = { [weak self] id in self?.discard(id) }
        self.notch.engineProvider = { [weak self] id in self?.engines[id] }
        self.notch.refresh()
    }

    /// Install/remove the cursor-reveal rail (gated by the agent-feature opt-in). Turning the feature off
    /// collapses any expanded session first (persisting it) — the synchronous-teardown path.
    func setEnabled(_ on: Bool) {
        if !on, expandedID != nil { collapse() }
        notch.setEnabled(on)
    }

    /// Live-update the notch reveal dwell (Hub slider). Forwards to the cursor-reveal controller.
    func setRevealDwell(_ interval: TimeInterval) {
        notch.setRevealDwell(interval)
    }

    /// The current park state for `id`, delegating to the scheduler's thread-safe (lock-guarded) read — the
    /// same any-thread seam the background-autonomy runner's `parkStateOf` uses. The expanded session's row
    /// is kept `.active` so the runner takes the foreground path — its engine's approval gate owns it.
    func parkState(of id: AgentSessionID) -> ParkState {
        scheduler.parkState(of: id)
    }

    // MARK: - Birth (the "+ New chat" card — durable at birth)

    /// Create a NEW session at the notch: a fresh engine + conversation, written to the durable store
    /// IMMEDIATELY (durable at birth — it survives relaunch from its first moment), registered with the
    /// scheduler as the `.active` foreground row, and expanded in place for typing.
    @discardableResult
    func newSession() -> AgentSessionID {
        collapseCurrentIfNeeded()
        let engine = obtainEngine(for: nil)
        let conversation = engine.startNew()
        let id = conversation.id
        engines[id] = engine
        expandedID = id
        wireEngine(engine, id: id)
        persist(conversation, rowState: .active, badge: 0)
        runEvictionAndRepublish()
        notch.expandSession(id)
        publishExpandedState()
        return id
    }

    // MARK: - Expand (a card opens in place)

    /// Expand a session's card into the in-place conversation panel: bind an engine to the stored
    /// conversation, mark its row `.active` (foreground — excluded from the background runnable set),
    /// clear its unseen badge, and republish (which clears the glow if this was the last needs-you).
    func expand(_ id: AgentSessionID) {
        guard let conversation = store.conversation(id) else { return }
        collapseCurrentIfNeeded()
        let engine = obtainEngine(for: id)
        if engine.conversation?.id != id || !engine.isTurnInFlight {
            engine.bind(conversation)
        }
        engines[id] = engine
        expandedID = id
        wireEngine(engine, id: id)
        updateRow(id) { row in
            row.state = .active
            row.badgeCount = 0
            row.updatedAt = Date()
        }
        republish()
        notch.expandSession(id)
        publishExpandedState()
    }

    /// Collapse the expanded session back to the rail: persist its snapshot, return its row to the
    /// background set, and — the load-bearing contract — do NOT cancel an in-flight turn: the engine stays
    /// alive detached; its `onTurnSettled` persists the completed turn and bumps the badge, and only then
    /// is the engine dropped. An idle engine is dropped immediately.
    func collapse() {
        guard expandedID != nil else { return }
        collapseCurrentIfNeeded()
        republish()
        notch.collapseToRail()
        publishExpandedState()
    }

    /// The shared collapse core (used by `collapse()`, and by `newSession`/`expand` when another session
    /// is already expanded — one foreground at a time).
    private func collapseCurrentIfNeeded() {
        guard let id = expandedID else { return }
        guard let engine = engines[id] else { expandedID = nil; return }
        let snapshot = engine.unbind()
        if let snapshot { try? store.upsert(row(for: id, default: snapshot), conversation: snapshot) }
        if engine.isTurnInFlight {
            // Detached but still streaming: keep the engine + the `.active` row (structurally excluded
            // from the background runnable set, so nothing double-advances it). `onTurnSettled` finishes
            // the story: persist, badge, drop.
        } else {
            engines[id] = nil
            updateRow(id) { row in
                row.state = .idle
                row.updatedAt = Date()
            }
        }
        expandedID = nil
    }

    // MARK: - Discard (deletion — cancel pending, remove; completed side effects are NOT rolled back)

    /// The SINGLE authoritative removal path for ALL dismissals (manual deletion AND the expiry pass):
    /// cancel any pending generation (via the engine when one exists, and the lifecycle's task
    /// cancellation), remove the durable conversation + rail row, re-seed the scheduler, republish.
    /// Idempotent — discarding an already-removed id is a harmless no-op.
    func discard(_ id: AgentSessionID) {
        engines[id]?.cancelAll()
        engines[id] = nil
        if expandedID == id {
            expandedID = nil
            notch.collapseToRail()
        }
        try? lifecycle.discard(id)
        scheduler.setSessions(store.all())
        notch.refresh()
        publishExpandedState()
    }

    /// The PURGE-DELETE (`notch-conversation-gestures`, the fast right-flick on the expanded
    /// conversation): the authoritative discard PLUS erasing every audit record attributed to the
    /// session — from the in-memory ring and the durable audit file. User-initiated only; this path
    /// deliberately writes no log line referencing the session. The plain delete affordances stay
    /// `discard(_:)`, which leaves the ledger intact.
    func purge(_ id: AgentSessionID) {
        discard(id)
        auditLog?.purge(sessionID: id)
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

    /// Run the auto-dismiss pass (expiry): every TERMINAL (`.completed`) session and every non-protected
    /// idle-past-countdown session is DISMISSED FOREVER through the authoritative `discard(_:)` path.
    /// The expanded session's row is `.active` (protected), so a session is never expired out from under
    /// the reader. Called on a coarse repeating timer by the owner (`AppCoordinator`). `now:` injected so
    /// the pass is deterministic in tests.
    @discardableResult
    func runAutoDismissPass(now: Date = Date()) -> [AgentSessionID] {
        let dismissed = lifecycle.runAutoDismissPass(now: now)
        for id in dismissed {
            engines[id]?.cancelAll()
            engines[id] = nil
        }
        scheduler.setSessions(store.all())
        notch.refresh()
        publishExpandedState()   // defensive — expanded rows are protected, but the choke point stays single
        return dismissed
    }

    /// Publish the expanded-or-not state IFF it changed since the last publish (the no-blip guarantee:
    /// an expand-another transition keeps it `true` throughout, so the recognizer's notch mode never
    /// flickers off mid-gesture).
    private func publishExpandedState() {
        let expanded = (expandedID != nil)
        guard expanded != lastPublishedExpanded else { return }
        lastPublishedExpanded = expanded
        onExpandedChanged?(expanded)
    }

    // MARK: - Test seams

    /// The engine currently bound for `id`, if one exists (expanded, or detached finishing a turn).
    func engineForTest(_ id: AgentSessionID) -> NotchSessionEngine? { engines[id] }

    // MARK: - Helpers

    /// Reuse the live engine for `id` (a detached one still finishing a turn) or build a fresh one.
    private func obtainEngine(for id: AgentSessionID?) -> NotchSessionEngine {
        if let id, let existing = engines[id] { return existing }
        return engineFactory()
    }

    /// Wire the engine's settle callback: persist the snapshot, then update the row — the expanded
    /// session stays `.active` with no badge (the user is watching); a detached (collapsed) session goes
    /// `.idle` with an unseen-result badge and its engine is dropped. A terminal completion on a DETACHED
    /// session takes the existing terminal flow (`.completed` → auto-dismissed forever); on the EXPANDED
    /// session it just goes idle-in-place (the user is reading it; expiry collects it later).
    private func wireEngine(_ engine: NotchSessionEngine, id: AgentSessionID) {
        engine.onTurnSettled = { [weak self] conversation, taskComplete in
            guard let self else { return }
            let isExpanded = (self.expandedID == id)
            let rowState: ParkState = isExpanded ? .active : (taskComplete ? .completed : .idle)
            let badge: Int? = isExpanded ? 0 : nil   // nil ⇒ increment
            self.persist(conversation, rowState: rowState, badge: badge)
            if !isExpanded {
                self.engines[id] = nil
                if taskComplete { self.lifecycle.runAutoDismissPass(now: Date()) }
            }
            self.republish()
        }
    }

    /// Upsert `conversation` + its row. `badge`: an explicit count, or nil to increment the stored one.
    private func persist(_ conversation: AgentConversation, rowState: ParkState, badge: Int?) {
        var row = row(for: conversation.id, default: conversation)
        row.title = conversation.title
        row.state = rowState
        row.badgeCount = badge ?? (row.badgeCount + 1)
        row.updatedAt = Date()
        do {
            try store.upsert(row, conversation: conversation)
        } catch {
            // The store already mapped + logged the failure; record it as a bounded failed row so the
            // user sees it on the rail (never an NSAlert, never raw text in the headline).
            recordFailedRow(row, error: error)
        }
        scheduler.setSessions(store.all())
    }

    /// The stored row for `id`, or a fresh one derived from `conversation` when none exists yet.
    private func row(for id: AgentSessionID, default conversation: AgentConversation) -> ParkedSession {
        scheduler.snapshot().first(where: { $0.id == id })
            ?? ParkedSession(id: id, title: conversation.title, state: .idle,
                             badgeCount: 0, nextRunAt: nil, updatedAt: Date())
    }

    /// Mutate the stored row for `id` in place (no-op when the row doesn't exist) and re-seed the scheduler.
    private func updateRow(_ id: AgentSessionID, _ mutate: (inout ParkedSession) -> Void) {
        guard var row = scheduler.snapshot().first(where: { $0.id == id }) else { return }
        mutate(&row)
        try? store.upsertRow(row)
        scheduler.setSessions(store.all())
    }

    private func runEvictionAndRepublish() {
        lifecycle.runEvictionPass(now: Date())
        scheduler.setSessions(store.all())
        notch.refresh()
    }

    private func republish() {
        scheduler.setSessions(store.all())
        notch.refresh()
    }

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
