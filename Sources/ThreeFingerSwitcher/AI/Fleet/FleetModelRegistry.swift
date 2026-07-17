import Foundation

/// The fleet registry protocol (addendum §C1 — OWNED by `ai-model-fleet`). It evolves the model layer
/// from "one resident runtime" to "a registry with residency/eviction": every member is a
/// `ModelDescriptor`, the resident subset is queryable, and admitting a member may EVICT others under the
/// 48 GB unified-memory budget (the math lives in `ResidencyPlanner`).
///
/// Two kinds of conformer:
///  - `FleetRoster` / `StubModelRegistry` — pure, in-memory roster views: `descriptors()` is the catalog,
///    `resident()` is the on-device-loaded subset, and `ensureResident` runs the planner + records the
///    bookkeeping WITHOUT touching real weights (so the residency math is `swift test`-verified).
///  - `ModelManager` — the live conformer: its `ensureResident` runs the SAME plan, then evicts each
///    planned id and loads the target through the EXISTING `ModelProvisioner` / `runtimeFactory` (D4).
///
/// `ensureResident` is `async` here (the live load is async); the pure roster conformers satisfy it
/// synchronously. Cloud members (`provider: .cloud`) are in `descriptors()` (selectable/visible) but
/// NEVER in `resident()` and never loaded — `ensureResident` of a cloud id is a residency no-op.
public protocol ModelRegistry: Sendable {
    /// Every known member, including cloud members (so selection + the Hub roster see them all).
    func descriptors() -> [ModelDescriptor]
    /// The on-device members currently resident in memory. Never includes a `.cloud` member.
    func resident() -> [ModelDescriptor]
    /// Admit `id`, evicting whatever the residency plan names to make room. Throws
    /// `FleetError.cannotAdmit` when the target cannot fit even after evicting every evictable on-device
    /// model. A cloud id is a residency no-op (cost 0, never resident). May EVICT under the 48 GB budget.
    func ensureResident(_ id: String) async throws
}
