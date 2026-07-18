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
        normalizeRowsAtLaunch()
        self.notch.setRevealDwell(revealDwell)
        // The rail lists sessions most-recently-used FIRST (right after the "+ New chat" card).
        self.notch.sessionsProvider = { [weak self] in self?.scheduler.railSnapshot() ?? [] }
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

    // MARK: - Birth (the "+ New chat" card — durable at FIRST MESSAGE)

    /// Create a NEW session at the notch: a fresh engine + conversation, expanded in place for typing. It is
    /// **NOT** written to the store yet — an empty new chat is never docked. The session becomes durable +
    /// joins the rail on its **first message** (the engine's `onTurnStarted` → `persistNewlySent`); if it is
    /// closed still empty, `collapseCurrentIfNeeded` discards it (no store row, no rail card).
    @discardableResult
    func newSession() -> AgentSessionID {
        collapseCurrentIfNeeded()
        let engine = obtainEngine(for: nil)
        let conversation = engine.startNew()
        let id = conversation.id
        engines[id] = engine
        expandedID = id
        wireEngine(engine, id: id)
        notch.expandSession(id)
        publishExpandedState()
        return id
    }

    /// The first-message durability hook (`engine.onTurnStarted`): the user just sent a turn, so the
    /// (until-now unsaved) session becomes durable + joins the dock. The very first save runs the eviction
    /// pass (the chat is now real and counts toward the cap); later sends just keep the store fresh.
    private func persistNewlySent(_ id: AgentSessionID, _ conversation: AgentConversation) {
        guard expandedID == id else { return }
        let firstSave = store.conversation(id) == nil
        persist(conversation, rowState: .active, badge: .clear)
        if firstSave { runEvictionAndRepublish() } else { republish() }
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
    /// `closingPanel` (the swipe-up "minimize" gesture) straight-CLOSES the panel — it shrinks the expanded
    /// conversation directly into the notch rather than returning to the visible rail and then grace-
    /// dismissing (the two-stage "dwell on the dock"). The session state work is identical either way; only
    /// the panel animation differs. The chevron / Esc collapse (default) returns to the visible rail.
    func collapse(closingPanel: Bool = false) {
        guard expandedID != nil else { return }
        if closingPanel {
            // Straight-close: shrink the panel with the conversation STILL BOUND (so it shrinks the REAL
            // conversation, never flashing the empty/new-chat state or the rail), and do the session
            // state-collapse (unbind + persist + republish) only AFTER the panel is hidden.
            notch.collapseAndClose { [weak self] in
                guard let self else { return }
                self.collapseCurrentIfNeeded()
                self.republish()
                self.publishExpandedState()
            }
            return
        }
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
        // An unsaved EMPTY new chat (opened but never sent a message) is DISCARDED, not docked: drop the
        // engine, remove any stray store trace, and create no rail row. Nothing is saved to the dock until
        // the first message (which persists the session before it can ever reach here empty).
        if snapshot?.messages.isEmpty ?? true {
            engines[id] = nil
            if store.conversation(id) != nil { try? lifecycle.discard(id) }
            expandedID = nil
            return
        }
        if let snapshot { try? store.upsert(row(for: id, default: snapshot), conversation: snapshot) }
        if engine.isPausedAtApproval {
            // Docked while the route loop is SUSPENDED on this engine's approval gate: keep the engine
            // (dropping it would orphan the suspended continuation — the response stops forever) and
            // surface `.needsYou` (the step is blocked on the user regardless of tier). Re-expanding
            // re-presents the same card; Approve/Skip resumes the original paused step.
            updateRow(id) { row in
                row.state = .needsYou
                row.badgeCount = max(row.badgeCount, 1)
                row.updatedAt = Date()
            }
        } else if engine.isTurnInFlight {
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
    /// cancel any pending generation (the engine is the single cancellation owner — `cancelAll()`
    /// cancels the turn task and resolves a suspended approval gate), remove the durable conversation +
    /// rail row, re-seed the scheduler, republish. Idempotent — discarding an already-removed id is a
    /// harmless no-op.
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

    /// Report a background-advance result back to the scheduler (the driver's failure path, the media
    /// feed) and republish the rail. There is NO terminal flow (`refactor-park-and-background-agents`):
    /// a settled `.done` is an unseen result (idle + badge), a `.failed` re-parks with a scheduled
    /// retry — nothing here ever removes a session.
    func didAdvance(_ id: AgentSessionID, result: ToolStepResult) {
        scheduler.didAdvance(id, result: result)
        persistRowSnapshot()
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

    /// The AI system's business RIGHT NOW, for automatic model eviction
    /// (`model-idle-ttl-and-memory-pressure` D2): pulled by `ModelManager` at decision time on the
    /// main actor, so evict-vs-just-scheduled ordering is deterministic. `foregroundSessionActive` is
    /// an OR over conversational surfaces — the expanded notch session, any `.active` row, and (when
    /// the voice change lands) an open voice conversation joins through the same flag.
    func quiescenceSnapshot() -> QuiescenceSnapshot {
        let rows = scheduler.snapshot()
        return QuiescenceSnapshot(
            turnInFlight: engines.values.contains { $0.isTurnInFlight },
            foregroundSessionActive: expandedID != nil || rows.contains { $0.state == .active },
            nextScheduledWork: rows.compactMap(\.nextRunAt).min())
    }

    /// The engine bound to the expanded session, if any (`add-voice-computer-use-agent`: the
    /// `set_auto_mode` tools land the grant on the conversation the user is looking at).
    func expandedEngine() -> NotchSessionEngine? {
        expandedID.flatMap { engines[$0] }
    }

    /// The any-human-touch kill switch's fan-out (`add-voice-computer-use-agent`): discard every
    /// in-flight turn — a DISCARD (no partial message appended, not a failure), exactly the verb the
    /// canvas's own discard uses.
    func discardInFlightTurns() {
        for engine in engines.values where engine.isTurnInFlight {
            engine.discardTurn()
        }
    }

    // MARK: - Maintenance

    /// Relaunch normalization (`refactor-park-and-background-agents`): no engine can exist at launch, so
    /// a row persisted `.active` (the app quit while the session was expanded or its turn was detached
    /// in flight) is stale. When its conversation's last message still awaits an assistant reply, the
    /// row becomes `.parked` + scheduled NOW — the background driver re-runs the interrupted turn (a
    /// quit mid-response resumes instead of stranding a forever-protected zombie row); otherwise it
    /// simply idles. `.needsYou` rows stay (blocked on the user, not runnable); rows persisted under the
    /// retired terminal state decode as `.idle` at the store boundary.
    private func normalizeRowsAtLaunch() {
        for var row in scheduler.snapshot() where row.state == .active {
            let awaitsReply = store.conversation(row.id)
                .flatMap(\.messages.last)
                .map { $0.role != .assistant } ?? false
            row.state = awaitsReply ? .parked : .idle
            row.nextRunAt = awaitsReply ? Date() : nil
            row.updatedAt = Date()
            try? store.upsertRow(row)
        }
        scheduler.setSessions(store.all())
    }

    /// The background driver (`refactor-park-and-background-agents`): serve the scheduler's runnable set
    /// (ONE slot in this capability — the K-ready seam is unchanged) by rebuilding a detached engine
    /// from the durable conversation and running its pending turn through the same machinery, settle
    /// path, and badge classification as a collapsed foreground turn. Skips entirely while ANY turn is
    /// in flight (the foreground or a detached turn owns the single slot) — which is also the
    /// double-serve guard: an advancing session keeps its engine in flight, so the next tick serves
    /// nothing until the turn settles and rewrites the row. Called on the coarse maintenance timer and
    /// once after launch normalization. Returns the served ids (for tests).
    @discardableResult
    func runAdvancePass(now: Date = Date()) -> [AgentSessionID] {
        // Only a PRODUCING turn owns the slot; an engine suspended at its approval gate consumes no
        // generation and must never block other sessions from advancing.
        guard !engines.values.contains(where: { $0.isGenerating }) else { return [] }
        let runnable = scheduler.runnableSessions(now: now, maxSlots: 1)
        var served: [AgentSessionID] = []
        for id in runnable {
            guard let conversation = store.conversation(id) else { continue }
            let engine = obtainEngine(for: id)
            engine.bind(conversation)
            engines[id] = engine
            wireEngine(engine, id: id)
            engine.advance()
            if !engine.isTurnInFlight {
                // Nothing pending after all, or the model is unavailable: go DORMANT (clear the
                // schedule) until the user returns — never a busy retry loop against a missing model.
                engines[id] = nil
                updateRow(id) { row in
                    row.nextRunAt = nil
                    row.updatedAt = now
                }
            }
            served.append(id)
        }
        if !served.isEmpty { notch.refresh() }
        return served
    }

    /// Run the auto-dismiss pass (the OPT-IN expiry): an `.idle`, fully-seen (zero-badge) session past
    /// the configured countdown is DISMISSED FOREVER through the authoritative `discard(_:)` path — a
    /// countdown of 0 (the default) dismisses nothing. Unseen results, active/needs-you sessions, and
    /// parked pending work are never touched. Called on a coarse repeating timer by the owner
    /// (`AppCoordinator`). `now:` injected so the pass is deterministic in tests.
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
    /// session stays `.active` with no badge (the user is watching); a detached (collapsed) session
    /// classifies by HOW the turn ended. A settled answer is NEVER terminal
    /// (`refactor-park-and-background-agents` — the old `taskComplete → .completed → instant
    /// auto-dismiss` classification deleted every chat docked mid-response the moment its answer
    /// landed): detached-answered goes `.idle` + unseen badge. A detached PAUSE keeps the session
    /// waiting on the user (`.needsYou` when the step escalated — never downgraded — else dormant
    /// `.parked`); a detached FAILURE re-parks with a scheduled retry via the advance-feedback seam.
    private func wireEngine(_ engine: NotchSessionEngine, id: AgentSessionID) {
        // A confirm/dangerous step that pauses at the gate AFTER the user docked (the turn kept
        // streaming detached) surfaces `.needsYou` — never an invisible suspension behind "Working…".
        engine.onApprovalPending = { [weak self] in
            guard let self, self.expandedID != id else { return }
            self.updateRow(id) { row in
                row.state = .needsYou
                row.badgeCount = max(row.badgeCount, 1)
                row.updatedAt = Date()
            }
            self.republish()
        }
        engine.onTurnStarted = { [weak self] conversation in
            self?.persistNewlySent(id, conversation)
        }
        engine.onTurnSettled = { [weak self] conversation, settlement in
            guard let self else { return }
            let isExpanded = (self.expandedID == id)
            if isExpanded {
                self.persist(conversation, rowState: .active, badge: .clear)
                self.republish()
                return
            }
            switch settlement {
            case .answered:
                self.persist(conversation, rowState: .idle, badge: .increment)
                self.engines[id] = nil
            case .pausedAwaitingUser:
                // The escalation callback (dangerous) already set + persisted `.needsYou`; a
                // confirm-tier pause waits DORMANT (`.parked` with the schedule cleared, so the driver
                // can never re-serve — and re-run — the paused turn until the user returns).
                let rowState: ParkState = self.scheduler.parkState(of: id) == .needsYou ? .needsYou : .parked
                self.persist(conversation, rowState: rowState, badge: .keep)
                self.updateRow(id) { row in row.nextRunAt = nil }
                self.engines[id] = nil
            case let .failed(headline):
                self.persist(conversation, rowState: .parked, badge: .keep)
                self.engines[id] = nil
                // Re-park with a scheduled retry so the failure is observable and never a dead end.
                self.didAdvance(id, result: ToolStepResult(tool: "turn",
                                                           status: .failed(headline: headline),
                                                           summary: headline))
            }
            self.republish()
        }
    }

    /// How a persist touches the row's unseen-result badge.
    private enum BadgeUpdate {
        /// Seen: the user is watching (expanded) — reset to zero.
        case clear
        /// A new unseen result landed detached — bump the stored count.
        case increment
        /// No new result (a pause / failure) — leave the stored count alone.
        case keep
    }

    /// Upsert `conversation` + its row.
    private func persist(_ conversation: AgentConversation, rowState: ParkState, badge: BadgeUpdate) {
        var row = row(for: conversation.id, default: conversation)
        row.title = conversation.title
        row.state = rowState
        switch badge {
        case .clear:     row.badgeCount = 0
        case .increment: row.badgeCount += 1
        case .keep:      break
        }
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
