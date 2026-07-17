import Foundation
import os

// MARK: - Thread-safe live gating snapshot (MLX-free Core)
//
// The route loop (`AgentLoop.run`) is a NON-isolated `Sendable` struct: its `descriptors()` /
// `registry.run` / contributor calls execute on the cooperative thread pool, NOT the main actor. The
// Full Potential gating flags + the cloud-video budget cap, however, live on the `@MainActor`
// `AppSettings`. Reading them from the loop's `@Sendable` closures via `MainActor.assumeIsolated`
// TRAPS (EXC_BREAKPOINT) off the main actor — that crashes the first AI command that routes through
// the tool loop (the media contributor's availability gate is read while ranking/dispatching tools).
//
// `AIGatingSnapshot` is the safe-from-any-thread mirror that fixes it WITHOUT losing live semantics:
// the main actor writes the few gating values into it whenever the relevant `AppSettings` flags change
// (`refresh(from:)`, driven by Combine observation), and the loop's `@Sendable` closures read them
// thread-safely through an `OSAllocatedUnfairLock`. So media / cloud gates still appear/disappear LIVE
// as the user toggles Full Potential or its sub-flags — never a stale snapshot frozen at registry-build
// time (when everything is off), and never an off-main trap.

/// A thread-safe live mirror of the AI route loop's `AppSettings`-derived gating inputs. The main actor
/// refreshes it on every relevant settings change; the route loop's `@Sendable` closures read it off-main
/// without trapping. `internal` (it consumes the internal `AppSettings`); the gating values it exposes are
/// the same the (public) `FullPotentialGate` resolves.
final class AIGatingSnapshot: Sendable {
    /// The plain value the lock guards — every gating read the off-main route loop needs.
    private struct Values: Sendable {
        var fullPotentialEnabled = false
        var mediaGenUnlocked = false
        var fleetCloudUnlocked = false
        var mediaVideoBudgetPerDay = 0
    }

    private let storage = OSAllocatedUnfairLock(initialState: Values())

    init() {}

    // MARK: Refresh (main-actor writer)

    /// Mirror the live Full Potential gates + cloud-video budget into the snapshot. Called on the main
    /// actor on every relevant settings change (and once at start) so the off-main reads see the current
    /// values. Each gate routes through the SINGLE resolver (`FullPotentialGate.isUnlocked`), so a master /
    /// ai-commands OFF closes media + cloud at once (the calm panic-off), never just their own sub-flag.
    @MainActor
    func refresh(from settings: AppSettings) {
        let gate = settings.fullPotentialGate
        let full = settings.fullPotentialEnabled
        let media = gate.isUnlocked(.mediaGen)
        let cloud = gate.isUnlocked(.fleetCloud)
        let budget = settings.mediaVideoBudgetPerDay
        storage.withLock {
            $0.fullPotentialEnabled = full
            $0.mediaGenUnlocked = media
            $0.fleetCloudUnlocked = cloud
            $0.mediaVideoBudgetPerDay = budget
        }
    }

    // MARK: Reads (safe from any thread — no `assumeIsolated`)

    /// The master Full Potential gate (raw — the media contributor ANDs it with `isMediaGenUnlocked`).
    var isFullPotentialEnabled: Bool { storage.withLock { $0.fullPotentialEnabled } }
    /// Whether the `mediaGen` capability is unlocked through the single resolver (master ∧ ai-commands ∧ sub).
    var isMediaGenUnlocked: Bool { storage.withLock { $0.mediaGenUnlocked } }
    /// Whether the `fleetCloud` capability is unlocked through the single resolver.
    var isFleetCloudUnlocked: Bool { storage.withLock { $0.fleetCloudUnlocked } }
    /// The live cloud-video per-day budget cap.
    var mediaVideoBudgetPerDay: Int { storage.withLock { $0.mediaVideoBudgetPerDay } }
}
