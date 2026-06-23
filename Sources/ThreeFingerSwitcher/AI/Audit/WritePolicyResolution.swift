import Foundation

/// The argument target a routed call exposes for whitelist matching (design Decision 4). The per-tool
/// arg → target extraction lives next to each `ToolContributor` (it owns the args shape); this slice
/// supplies the resolver + the matching, not the per-tool parsing.
public enum PolicyTarget: Equatable, Sendable {
    /// A write destination path.
    case path(String)
    /// A tool / Shortcut / shell command name (or `argv[0]`).
    case command(String)
    /// A shell command writing to a path (the both-rule applies).
    case both(command: String, path: String)
    /// No path/command (calendar / contacts) → never whitelist-lowerable.
    case none
}

/// The production `WritePolicyResolving` conformer (`ai-background-autonomy`, design Decision 4) that
/// REPLACES the routing slice's stand-alone `DescriptorWritePolicy` default. It intersects the
/// descriptor's tier with the user `Whitelist`: effective tier = `descriptor.writePolicy` lowered to
/// `.auto` ONLY when the tool is CONTAINED or its target matches the whitelist; NEVER lowered when the
/// descriptor is `.dangerous`.
///
/// `WritePolicyResolving` (CONSUMED verbatim from `ai-tool-routing`) carries only the descriptor, so the
/// protocol method is the descriptor-only fast path. The richer `effectiveTier(for:target:)` overload —
/// which the contributor/loop calls when it has the routed call's target — adds the whitelist lowering
/// WITHOUT a routing protocol change (design rejected-alternative 2). MLX-free Core.
struct BackgroundPolicyResolver: WritePolicyResolving, Sendable {
    let whitelist: Whitelist

    init(whitelist: Whitelist = .empty) {
        self.whitelist = whitelist
    }

    /// Protocol requirement (descriptor-only): used when no target is available.
    /// CONTAINED → `.auto`; `.dangerous` → `.dangerous`; otherwise the descriptor's own tier (no
    /// whitelist lowering possible without a target).
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier {
        switch BlastRadius.of(descriptor) {
        case .contained: return .auto
        case .dangerous: return .dangerous
        case .external:  return descriptor.writePolicy
        }
    }

    /// The richer overload: lower `.confirm` → `.auto` ONLY when the blast radius is `.external` AND the
    /// `target` matches the whitelist. NEVER lowers `.dangerous`; a `.none` target is never lowerable;
    /// CONTAINED stays `.auto`.
    func effectiveTier(for descriptor: ToolDescriptor, target: PolicyTarget?) -> WritePolicyTier {
        let radius = BlastRadius.of(descriptor)
        switch radius {
        case .contained:
            return .auto
        case .dangerous:
            return .dangerous          // never lowered, regardless of target / whitelist
        case .external:
            guard descriptor.writePolicy == .confirm else { return descriptor.writePolicy }
            if let target, matches(target) { return .auto }
            return .confirm
        }
    }

    /// Whether a `PolicyTarget` matches the whitelist (the both-rule for a `.both`).
    private func matches(_ target: PolicyTarget) -> Bool {
        switch target {
        case let .path(p):                return whitelist.matchesPath(p)
        case let .command(c):             return whitelist.matchesCommand(c)
        case let .both(command, path):    return whitelist.matchesBoth(command: command, path: path)
        case .none:                       return false
        }
    }
}
