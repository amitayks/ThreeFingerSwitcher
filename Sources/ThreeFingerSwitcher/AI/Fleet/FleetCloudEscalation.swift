import Foundation

/// The cloud-escalation routing seam for fleet cloud members (design D5, task 6.2). A `.cloud` member
/// (Claude, GLM-5.2) is NEVER loaded; selecting one routes the turn through the EXISTING Claude-handoff
/// escalation surface (`ai-claude-handoff` §3.8 — confirm-by-default, budget-capped, audited). This slice
/// ROUTES, it does not reimplement the handoff: a production conformer bridges to the handoff launcher;
/// a recording spy keeps the routing `swift test`-verified.
///
/// MLX-free Core.
public protocol FleetCloudEscalating: Sendable {
    /// Route a turn to the cloud member `descriptor` through the handoff escalation surface. The
    /// descriptor is always a `.cloud` / `.cloudEscalation` member; the conformer does the actual
    /// confirm/budget/audit (this seam only carries the routing decision).
    func escalate(to descriptor: ModelDescriptor) async throws
}

/// The no-op default (a context with no handoff surface wired). Routes nowhere — a safe fallback.
public struct NoopFleetCloudEscalation: FleetCloudEscalating {
    public init() {}
    public func escalate(to descriptor: ModelDescriptor) async throws {}
}

/// Gates + routes selection of a cloud member behind `fleetCloudEscalationEnabled` (design D5, task 6).
///
/// The flag itself is OWNED by `ai-full-potential-toggle` (§D1) — this slice only CONSUMES it via an
/// injected closure (default treated as `false`, task 6.1). When off, a cloud member is not offered for
/// selection (`selectableDescriptors` filters it out) and selecting one yields `FleetError.cloudDisabled`;
/// when on, a cloud-member selection routes through the `FleetCloudEscalating` seam.
public struct FleetCloudGate: Sendable {
    /// Reads the persisted `fleetCloudEscalationEnabled` (owned by `ai-full-potential-toggle`). Injected
    /// so this slice never defines the flag; default treated as `false` (task 6.1).
    public let isEnabled: @Sendable () -> Bool
    private let escalator: FleetCloudEscalating

    public init(isEnabled: @escaping @Sendable () -> Bool = { false },
                escalator: FleetCloudEscalating = NoopFleetCloudEscalation()) {
        self.isEnabled = isEnabled
        self.escalator = escalator
    }

    /// The members offered for selection in the Hub / executor: ALL on-device members, plus cloud members
    /// ONLY when escalation is enabled. (The Hub still RENDERS cloud rows when off — see task 7.3 — but as
    /// disabled/captioned; this is the set that is actually SELECTABLE.)
    public func selectableDescriptors(from descriptors: [ModelDescriptor]) -> [ModelDescriptor] {
        let cloudOK = isEnabled()
        return descriptors.filter { $0.provider == .onDevice || cloudOK }
    }

    /// Select `descriptor` as a command's model. On-device members are a no-op here (the manager handles
    /// residency). A cloud member:
    ///  - while OFF → throws `FleetError.cloudDisabled` (an observable refusal, never silent),
    ///  - while ON  → routes the turn through the handoff escalation seam (D5).
    public func select(_ descriptor: ModelDescriptor) async throws {
        guard descriptor.provider == .cloud else { return }
        guard isEnabled() else {
            throw FleetError.cloudDisabled(modelName: descriptor.displayName)
        }
        try await escalator.escalate(to: descriptor)
    }
}
