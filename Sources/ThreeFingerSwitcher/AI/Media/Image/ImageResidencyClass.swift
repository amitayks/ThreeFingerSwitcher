import Foundation

/// The pure residency CLASSIFICATION this slice OWNS (design D4, tasks 2.1–2.3). Given a chosen image
/// `ModelDescriptor` (its `residencyBytes`), the fleet's CURRENT resident set, and the unified-memory
/// ceiling (CONSUMED from `ai-model-fleet`, never re-derived here), it classifies the outcome of making
/// that image model resident as either:
///   - `.coResident`  — it fits alongside the resident chat + ternary + KV under the ceiling (Q4 ~7 GB);
///   - `.evictsChat`  — admitting it would force the GPU-lane chat model out (FP16 ~24 GB).
///
/// IMPORTANT division of labor (design D4): the fleet OWNS the eviction *decision* (`ensureResident`);
/// this slice only CLASSIFIES + CONSUMES. The classification — not a fresh eviction decision — is the
/// SINGLE input to BOTH the pre-fire cost disclosure (§5.1, `ImageCostDisclosure`) AND the runtime's
/// honest "busy painting" pre-flight state (§5.2). So both surfaces read the same truth and can never
/// disagree.
///
/// PURE: the resident set + ceiling + KV reserve are INJECTED — there is NO real free-RAM probe here
/// (mirrors `ConcurrencyBudget`/`ResidencyPlanner`'s injected-probe pattern), so the math is
/// `swift test`-verified with fixed inputs, no Metal, no real weights (task 2.2).
public enum ImageResidencyClass: Equatable, Sendable {
    /// The image model co-resides with chat — chat stays available while it paints.
    case coResident
    /// The image model evicts the chat model — the companion goes quiet ("busy painting").
    case evictsChat
}

/// The pure classifier (design D4). It mirrors the fleet `ResidencyPlanner`'s co-residency arithmetic, but
/// only to CLASSIFY (co-reside vs evict-chat) — it does NOT compute an eviction plan or touch weights.
public struct ImageResidencyClassifier: Sendable {

    /// The KV-cache headroom reserved alongside the resident weight set (the live decode caches). Held
    /// out of the ceiling so a co-residency classification never packs weights edge-to-edge — the SAME
    /// reserve concept the fleet's `ResidencyPlanner` uses (consumed convention, default kept aligned).
    public var kvReserveBytes: UInt64

    /// The resident-footprint threshold above which an `.image` model is the HEAVY (FP16) variant that
    /// evicts chat by GPU-lane EXCLUSIVITY — not just by byte-fit. This MIRRORS the fleet
    /// `ResidencyPlanner.fp16ImageThresholdBytes` (consumed convention, default kept aligned): the GPU lane
    /// cannot run a heavy diffusion AND stream chat concurrently (~153 GB/s bus contention; the companion
    /// goes quiet while it paints), so an FP16 image evicts chat even when ~45 GB technically fits under 48.
    /// A Q4 image (below the threshold) is bandwidth-light enough to co-reside.
    public var fp16ImageThresholdBytes: UInt64

    public init(kvReserveBytes: UInt64 = 4 * 1024 * 1024 * 1024,         // ~4 GB KV headroom (aligned w/ planner)
                fp16ImageThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024) { // > 16 GB resident ⇒ heavy (aligned)
        self.kvReserveBytes = kvReserveBytes
        self.fp16ImageThresholdBytes = fp16ImageThresholdBytes
    }

    /// Classify making `image` resident against the injected `resident` set under the injected `ceilingBytes`.
    ///
    /// Rules (D4), encoded once + tested:
    ///  - The chat model is the GPU-lane `.chat` member; if it is NOT currently resident there is nothing
    ///    to evict → the outcome cannot be `.evictsChat` for it (classify against what's actually there).
    ///  - **Co-resident:** the image model's bytes + ALL currently-resident on-device members + the KV
    ///    reserve fit within the ceiling → `.coResident`.
    ///  - **Evicts chat:** otherwise admitting the image model would require shedding the GPU-lane chat
    ///    model to fit → `.evictsChat`. (The CPU-lane ternary is bandwidth-frugal and is never the victim;
    ///    only the GPU-lane chat is, matching the planner's lane exclusivity.)
    ///
    /// - Parameters:
    ///   - image: the chosen image descriptor (its `residencyBytes` is the load to admit).
    ///   - resident: the fleet's CURRENT resident descriptors (injected — `registry.resident()`).
    ///   - ceilingBytes: the unified-memory ceiling (injected from the fleet — the 48 GB budget, or the
    ///     live free bytes, whichever the caller passes; this slice does NOT re-derive 48 GB).
    public func classify(image: ModelDescriptor,
                         resident: [ModelDescriptor],
                         ceilingBytes: UInt64) -> ImageResidencyClass {
        // Only on-device members occupy bytes (cloud members never do — filter defensively).
        let onDeviceResident = resident.filter { $0.provider == .onDevice }
        // If the image model is ALREADY resident, it is trivially co-resident (warm — nothing to admit).
        if onDeviceResident.contains(where: { $0.id == image.id }) { return .coResident }

        let chatResident = onDeviceResident.contains { $0.role == .chat && $0.lane == .gpu }

        // HEAVY GPU gen (an FP16 image above the threshold) → GPU-lane EXCLUSIVITY: it evicts chat even
        // when the bytes would technically fit, mirroring the fleet planner's `isHeavyGPUGen` rule. A Q4
        // image (below the threshold) falls through to the byte-fit test and co-resides.
        let isHeavyImage = image.lane == .gpu
            && image.role == .image
            && image.residencyBytes > fp16ImageThresholdBytes
        if isHeavyImage {
            return chatResident ? .evictsChat : .coResident
        }

        let residentBytes = onDeviceResident.reduce(UInt64(0)) { $0 &+ $1.residencyBytes }
        let total = residentBytes &+ image.residencyBytes &+ kvReserveBytes

        // Co-resident iff everything currently loaded PLUS the image model PLUS the KV reserve fit.
        if total <= ceilingBytes { return .coResident }

        // Over the ceiling → admitting the image model requires evicting a GPU-lane occupant. The expected
        // (and only) GPU-lane weight victim is the chat model; if it is resident, this is an evict-chat.
        return chatResident ? .evictsChat : .coResident
    }
}
