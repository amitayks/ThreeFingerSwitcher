import Foundation

/// Resolves a descriptor's effective write-policy tier (design D5). `ai-background-autonomy` (Wave 4)
/// supplies the production conformer that intersects the descriptor's tier with the user whitelist
/// (descriptor default ∩ whitelist → effective tier). This slice ships a stand-alone default so it
/// compiles + tests without that slice.
protocol WritePolicyResolving: Sendable {
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier
}

/// The stand-alone default: the descriptor's own tier, unmodified. Replaced by the whitelist-aware
/// resolver in `ai-background-autonomy`.
struct DescriptorWritePolicy: WritePolicyResolving {
    init() {}
    func effectiveTier(for descriptor: ToolDescriptor) -> WritePolicyTier { descriptor.writePolicy }
}
