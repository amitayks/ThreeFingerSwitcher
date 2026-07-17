import Foundation

/// Parked-while-generating (design D8, §7) — FEEDS the existing `ParkScheduler` the media job's
/// observable state; it does NOT re-implement the scheduler/rail/glow. A generating parked session shows
/// the **thinking** badge (an intermediate `.step` advance); a `.finished` shows the **done** badge + the
/// unseen-result count (an idle-with-unseen advance); a `.dangerous` cloud-video step on a parked session
/// ESCALATES to needs-you (via `escalate`). A CANCELLATION leaves NO failed badge (it reports nothing —
/// the row just stops advancing).
///
/// The scheduler decides scheduling; this seam only reports `didAdvance` / `escalate`. MLX-free Core.
public struct MediaParkFeed: Sendable {
    private let scheduler: ParkScheduler

    public init(scheduler: ParkScheduler) {
        self.scheduler = scheduler
    }

    /// Report a painting step → the **thinking** badge (an intermediate advance). The `ToolStepResult`
    /// is a `.done` beat (the scheduler's idle+badge bump shows progress).
    public func reportPainting(_ id: AgentSessionID, tool: String) {
        let step = ToolStepResult(tool: tool, status: .done, summary: "Painting…")
        scheduler.didAdvance(id, result: step)
    }

    /// Report a finished gen → the **done** badge + unseen count. The row idles with its unseen result;
    /// it is NEVER auto-dismissed for finishing (`refactor-park-and-background-agents` retired the
    /// terminal classification — removal is the user's, the opt-in expiry's, or eviction's alone).
    public func reportFinished(_ id: AgentSessionID, tool: String, asset: MediaAsset) {
        let step = ToolStepResult(tool: tool, status: .done,
                                  summary: "Ready: \(asset.url.lastPathComponent)")
        scheduler.didAdvance(id, result: step)
    }

    /// Report a `.dangerous` cloud-video step on a parked session → ESCALATE to needs-you (ambient glow)
    /// with a clean one-line reason, rather than spending in the background.
    public func reportNeedsYou(_ id: AgentSessionID, reason: String) {
        scheduler.escalate(id, reason: reason)
    }

    /// Report a clean, bounded FAILURE → the row surfaces failed (the headline is already clean). NOT
    /// called for a cancellation (cancellation reports nothing — no failed badge, design D10).
    public func reportFailed(_ id: AgentSessionID, tool: String, headline: String) {
        let step = ToolStepResult(tool: tool, status: .failed(headline: headline), summary: headline)
        scheduler.didAdvance(id, result: step)
    }
}
