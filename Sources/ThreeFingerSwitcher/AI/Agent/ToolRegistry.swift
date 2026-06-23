import Foundation

/// The user's resolution of an approval pause, fed by the canvas's canonical compass (DOWN=approve /
/// RIGHT=skip), or `.cancel` when the whole canvas is discarded.
enum ApprovalDecision: Equatable, Sendable {
    case approve
    case skip
    case cancel
}

/// The async seam the canvas drives to resolve a `.confirm`/`.dangerous` tool step (design D5). A
/// contributor that needs approval surfaces the backing `TaskReview` and awaits a decision here. Tests
/// inject a scripted gate.
protocol ApprovalGate: Sendable {
    func awaitDecision(for review: TaskReview) async -> ApprovalDecision
}

/// One source of tools: advertises its descriptors and runs a routed call (design D3). v1 ships a single
/// `TaskKindToolContributor`; later waves add `MemoryToolContributor`, `SkillToolContributor`,
/// `ClaudeHandoffContributor` — each just adds descriptors + a `run`, with NO loop change.
protocol ToolContributor: Sendable {
    func descriptors() -> [ToolDescriptor]
    func canHandle(_ tool: String) -> Bool
    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult
}

/// Aggregates contributors (design D3): the union of their descriptors (deduped by `name`, first wins)
/// and dispatch of a routed call to the owning contributor. Pure aggregation — no loop coupling.
struct ToolRegistry: Sendable {
    private let contributors: [ToolContributor]

    init(_ contributors: [ToolContributor]) {
        self.contributors = contributors
    }

    func allDescriptors() -> [ToolDescriptor] {
        var seen = Set<String>()
        var out: [ToolDescriptor] = []
        for contributor in contributors {
            for descriptor in contributor.descriptors() where !seen.contains(descriptor.name) {
                seen.insert(descriptor.name)
                out.append(descriptor)
            }
        }
        return out
    }

    func descriptor(named name: String) -> ToolDescriptor? {
        allDescriptors().first { $0.name == name }
    }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        guard let contributor = contributors.first(where: { $0.canHandle(call.descriptor.name) }) else {
            // Defensive: a routed tool no contributor owns never dispatches — a clean failed step the
            // model sees and can re-route around.
            return ToolStepResult(tool: call.descriptor.name,
                                  status: .failed(headline: "That tool isn't available."),
                                  summary: "Unknown tool: \(call.descriptor.name).")
        }
        return await contributor.run(call, gate: gate)
    }
}
