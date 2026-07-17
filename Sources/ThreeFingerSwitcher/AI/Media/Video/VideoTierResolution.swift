import Foundation

/// The effective-tier + over-budget DEGRADE resolution for `generate_video`
/// (`ai-video-animation-generation`, design D3 / tasks 3.1, 3.2 — the §3.8 `HandoffGate` pattern). Pure
/// policy: given the selected `VideoProvider`, the master gates, the user whitelist (via the shared
/// `WritePolicyResolving`), the budget, and whether the session is parked, it resolves WHICH gate the
/// routed call runs at. MLX-free Core, `swift test`-verified.
///
/// The contract this enforces, layered onto the existing `MediaGenSink`:
///  - CLOUD → `.dangerous` tier, intersected with the user whitelist (a `.dangerous` descriptor is NEVER
///    lowered to `.auto` by the resolver — spec). Confirm-by-default per call; over-budget DEGRADES, never
///    silently drops, never auto-runs (spec "Over-budget cloud video degrades, never runs unprompted").
///  - LOCAL → gated by the MASTER toggle (`fullPotentialEnabled && mediaGenEnabled`), NOT on the spend
///    axis: `.confirm` (frontier, expensive compute) but it consumes no budget ledger (design D6).

/// The resolved gate for ONE `generate_video` call (parallel to `HandoffGate`).
public enum VideoGate: Equatable, Sendable {
    /// The provider isn't available (local selected with the master OFF, or no provider configured) →
    /// declined, no compute, no spend.
    case providerDisabled
    /// Local frontier, master-gated → confirm-by-default per call, NO budget, NO upload.
    case localConfirm
    /// Cloud, under budget → confirm-by-default per call (`.dangerous`); on approval it spends one budget
    /// unit and uploads.
    case cloudConfirm
    /// Cloud, OVER budget → DEGRADE: active session → a foreground confirm STATING the cap was reached;
    /// parked session → a needs-you badge. Never auto-run, never silently dropped.
    case cloudOverBudget

    /// True when this gate spends from the cloud budget on approval (cloud only).
    public var spendsCloudBudget: Bool {
        switch self {
        case .cloudConfirm, .cloudOverBudget: return true
        case .providerDisabled, .localConfirm: return false
        }
    }

    /// The effective `WritePolicyTier` the audit record carries for this gate. Cloud → `.dangerous`
    /// (spend + leaves device); local → `.confirm`. A disabled provider audits at `.dangerous` for cloud
    /// (the descriptor default) but never runs.
    public var auditTier: WritePolicyTier {
        switch self {
        case .cloudConfirm, .cloudOverBudget: return .dangerous
        case .localConfirm: return .confirm
        case .providerDisabled: return .confirm
        }
    }
}

/// The pure resolver. Inputs are values / injected closures — no clock, no network, no MLX.
/// Internal because it composes the internal `WritePolicyResolving` seam (`DescriptorWritePolicy` /
/// `BackgroundPolicyResolver`); the test target reaches it via `@testable import`.
struct VideoTierResolver: Sendable {
    private let provider: VideoProvider
    private let resolver: WritePolicyResolving
    private let isFullPotentialEnabled: @Sendable () -> Bool
    private let isMediaGenEnabled: @Sendable () -> Bool

    init(provider: VideoProvider,
         resolver: WritePolicyResolving = DescriptorWritePolicy(),
         isFullPotentialEnabled: @escaping @Sendable () -> Bool = { false },
         isMediaGenEnabled: @escaping @Sendable () -> Bool = { false }) {
        self.provider = provider
        self.resolver = resolver
        self.isFullPotentialEnabled = isFullPotentialEnabled
        self.isMediaGenEnabled = isMediaGenEnabled
    }

    /// The EFFECTIVE write-policy tier for the `generate_video` descriptor under this provider (task 3.1):
    ///  - cloud → `.dangerous` ∩ whitelist (the resolver NEVER lowers `.dangerous`);
    ///  - local → `.confirm` (master-gated, off the spend axis).
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier {
        if provider.isCloud {
            // The descriptor is authored `.dangerous` for cloud; intersect with the whitelist (which can
            // never lower `.dangerous` to `.auto`). The resulting tier stays `.dangerous`.
            return resolver.effectiveTier(for: descriptor)
        }
        // Local frontier: confirm-by-default, never on the spend axis.
        return .confirm
    }

    /// Resolve the gate for THIS call (task 3.1 / 3.2). `budgetHasRoom` is the cloud budget predicate the
    /// caller evaluates against the injected clock (kept out of this pure resolver so `now` stays an input
    /// at the boundary that owns it).
    func gate(budgetHasRoom: Bool) -> VideoGate {
        if provider.isCloud {
            return budgetHasRoom ? .cloudConfirm : .cloudOverBudget
        }
        // Local: only selectable with the master gates ON (a settings desync where local persisted under a
        // since-disabled master degrades to provider-disabled rather than running a forbidden frontier).
        guard isFullPotentialEnabled() && isMediaGenEnabled() else { return .providerDisabled }
        return .localConfirm
    }

    /// The over-budget DEGRADE message stated on the approval surface (task 3.2) — names that the cap was
    /// reached (active → confirm card; parked → needs-you reason). Bounded, non-blocking; never raw text.
    static func overBudgetReason(parked: Bool) -> String {
        parked
            ? "Today's video budget is used up — approve when you're back to spend over the cap."
            : "Today's video budget is used up. Approve to generate one more (it spends over the cap)?"
    }
}
