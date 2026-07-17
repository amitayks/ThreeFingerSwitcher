import Foundation

/// The plan for admitting one target model under the 48 GB unified-memory budget (design D3). PURE DATA,
/// not a side effect: `ModelManager` is the only place that APPLIES it (evict → load). Returning the plan
/// as data lets the Hub PREVIEW the cost ("selecting Video pauses chat") before the user commits.
public struct ResidencyPlan: Equatable, Sendable {
    /// Ids to LOAD to satisfy the request (the target — and, on a fleet-of-one / co-resident plan, the
    /// target alone; never re-admits already-resident members).
    public var admit: [String]
    /// Ids to EVICT to make room for the target (smallest-GPU-victim-first; empty when the target
    /// co-resides). The CPU-lane ternary is never here for a GPU gen (different lane, negligible bytes).
    public var evict: [String]
    /// The resident set AFTER applying the plan (the post-admission, post-eviction occupants). The Hub
    /// reads this to render who survives; a member in `evict` is absent here.
    public var coResident: [String]
    /// True when the target cannot fit even after evicting every evictable on-device model. The caller
    /// (`ModelManager.ensureResident`) maps this to `FleetError.cannotAdmit` — an observable `.failed`,
    /// never a false `.loaded`.
    public var infeasible: Bool

    public init(admit: [String] = [], evict: [String] = [], coResident: [String] = [],
                infeasible: Bool = false) {
        self.admit = admit
        self.evict = evict
        self.coResident = coResident
        self.infeasible = infeasible
    }
}

/// The pure residency / eviction MATH (design D3). Given the fleet descriptors, the unified-memory budget,
/// the live free bytes (INJECTED — no Metal here), the currently-resident set, and a target, it computes
/// what to admit + evict. It NEVER calls Metal or the provisioner; `ModelManager` applies the plan.
///
/// The hard physical fact it encodes: 48 GB is a shared budget. Chat (~17 GB GPU) + ternary (~0.5 GB CPU)
/// + a Q4 image model (~7 GB) + the live KV reserve CO-RESIDE; a video gen or an FP16 image model (~24 GB)
/// CANNOT, and evicts chat. Cloud members never fit and never try.
public struct ResidencyPlanner: Sendable {

    /// The KV-cache headroom reserved alongside the resident weight set (the live decode caches that grow
    /// with concurrency). Held out of the budget so a co-residency plan leaves room for generation, never
    /// packs weights edge-to-edge. Injectable for tests; a sane default for the 48 GB target.
    public var kvReserveBytes: UInt64

    /// The resident-footprint threshold above which an `.image` member is treated as the heavy (FP16)
    /// variant that EVICTS chat rather than co-residing. A Q4 image model sits below it (co-resides); an
    /// FP16 image model sits above it (evicts). `.video` always evicts regardless of size.
    public var fp16ImageThresholdBytes: UInt64

    public init(kvReserveBytes: UInt64 = 4 * 1024 * 1024 * 1024,        // ~4 GB KV headroom
                fp16ImageThresholdBytes: UInt64 = 16 * 1024 * 1024 * 1024) { // > 16 GB resident ⇒ heavy
        self.kvReserveBytes = kvReserveBytes
        self.fp16ImageThresholdBytes = fp16ImageThresholdBytes
    }

    /// Compute the plan to admit `target` under `budgetBytes`, given the live `freeBytes`, the catalog of
    /// `descriptors`, and the ids `currentlyResident`.
    ///
    /// Rules (D3), encoded once and tested:
    ///  1. **Cloud target** (`provider: .cloud`) → empty admit/evict (cost 0, never resident).
    ///  2. **Already resident** → empty admit/evict (warm; nothing to do).
    ///  3. **Co-residency:** the target + the already-resident on-device members + the KV reserve fit
    ///     within the budget AND the live free bytes → admit the target, evict nothing.
    ///  4. **Eviction:** otherwise free room by evicting GPU-lane occupants smallest-victim-first (chat is
    ///     the expected victim) until the target + survivors + KV reserve fit. The CPU-lane ternary is
    ///     never evicted for a GPU gen (different lane, negligible bytes).
    ///  5. **Infeasible:** if the target cannot fit even after evicting every evictable GPU-lane occupant
    ///     → `infeasible: true` (the caller throws `FleetError.cannotAdmit`).
    public func plan(target targetID: String,
                     descriptors: [ModelDescriptor],
                     budgetBytes: UInt64,
                     freeBytes: UInt64,
                     currentlyResident: [String]) -> ResidencyPlan {

        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        guard let target = byID[targetID] else {
            // Unknown target → nothing to admit; not infeasible (the caller surfaces "unknown" upstream).
            return ResidencyPlan(coResident: currentlyResident)
        }

        // (1) Cloud target: never resident, cost 0 — a residency no-op (it routes to escalation, D5).
        if target.provider == .cloud {
            return ResidencyPlan(admit: [], evict: [], coResident: currentlyResident, infeasible: false)
        }

        // The on-device resident set (cloud ids can never be resident, but filter defensively).
        let residentDescriptors = currentlyResident.compactMap { byID[$0] }.filter { $0.provider == .onDevice }

        // (2) Already resident → warm, nothing to do.
        if residentDescriptors.contains(where: { $0.id == target.id }) {
            return ResidencyPlan(admit: [], evict: [],
                                 coResident: residentDescriptors.map(\.id), infeasible: false)
        }

        // The effective ceiling is the smaller of the declared budget and the live free bytes — never
        // plan beyond what the machine actually has free RIGHT NOW.
        let ceiling = min(budgetBytes, freeBytes)

        func footprint(_ ids: [String]) -> UInt64 {
            ids.reduce(UInt64(0)) { $0 &+ (byID[$1]?.residencyBytes ?? 0) }
        }

        // Is the target a HEAVY GPU generation (`.video`, or an `.image` above the FP16 threshold)? Such
        // a target EVICTS the GPU-lane chat even when the bytes would technically fit — the GPU lane
        // cannot run a heavy diffusion AND stream chat concurrently (~153 GB/s bus contention; the
        // companion goes quiet while it paints, documented). So a heavy target SKIPS the co-residency
        // fast-path and goes straight to eviction. Q4 image (below the threshold) co-resides.
        let isHeavyGPUGen: Bool = {
            guard target.lane == .gpu else { return false }
            switch target.role {
            case .video: return true
            case .image: return target.residencyBytes > fp16ImageThresholdBytes
            case .chat, .ternaryChat, .cloudEscalation: return false
            }
        }()

        // (3) Co-residency: a NON-heavy target that fits alongside ALL current residents + the KV reserve
        //     co-resides (no eviction). Heavy GPU gens never take this path.
        let coResidentIDs = residentDescriptors.map(\.id)
        let withTarget = footprint(coResidentIDs) &+ target.residencyBytes &+ kvReserveBytes
        if !isHeavyGPUGen && withTarget <= ceiling {
            return ResidencyPlan(admit: [target.id], evict: [],
                                 coResident: coResidentIDs + [target.id], infeasible: false)
        }

        // (4) Eviction. Only GPU-lane occupants are candidates; the CPU-lane ternary ALWAYS survives a GPU
        //     gen (different lane, negligible bytes). Two sub-cases:
        //       • HEAVY GPU gen → the GPU lane is exclusive to the heavy gen: evict EVERY other GPU
        //         occupant (chat is the expected victim), regardless of byte-fit. Then the target must
        //         still fit byte-wise against the survivors (ternary only) + KV.
        //       • Non-heavy over-budget target → free bytes by evicting GPU occupants smallest-victim-first
        //         until the target fits.
        let gpuOccupants = residentDescriptors.filter { $0.lane == .gpu }
        let survivorsBase = residentDescriptors.filter { $0.lane != .gpu }.map(\.id)

        var evicted: [String] = []
        var remainingVictims = gpuOccupants.sorted { $0.residencyBytes < $1.residencyBytes } // smallest-first

        func fits() -> Bool {
            let survivors = survivorsBase + remainingVictims.map(\.id)
            return footprint(survivors) &+ target.residencyBytes &+ kvReserveBytes <= ceiling
        }

        if isHeavyGPUGen {
            // Lane exclusivity: every other GPU occupant goes, regardless of byte-fit.
            evicted = remainingVictims.map(\.id)
            remainingVictims = []
        } else {
            // Byte pressure: shed smallest GPU victims until the target fits.
            while !fits() && !remainingVictims.isEmpty {
                evicted.append(remainingVictims.removeFirst().id)
            }
        }

        if fits() {
            let survivors = survivorsBase + remainingVictims.map(\.id)
            return ResidencyPlan(admit: [target.id], evict: evicted,
                                 coResident: survivors + [target.id], infeasible: false)
        }

        // (5) Infeasible: even after evicting every evictable GPU occupant the target does not fit.
        return ResidencyPlan(admit: [], evict: evicted,
                             coResident: survivorsBase, infeasible: true)
    }

    // MARK: - Honest cost preview (Hub)

    /// Whether admitting `targetID` would EVICT the GPU-lane chat — the Hub reads this (computed from the
    /// plan, NOT hard-coded) to render the inline "selecting ‹Role› pauses the chat model" disclosure
    /// (design D6, task 7.2). True iff the plan evicts a `.chat` member.
    public func admissionEvictsChat(targetID: String,
                                    descriptors: [ModelDescriptor],
                                    budgetBytes: UInt64,
                                    freeBytes: UInt64,
                                    currentlyResident: [String]) -> Bool {
        let p = plan(target: targetID, descriptors: descriptors, budgetBytes: budgetBytes,
                     freeBytes: freeBytes, currentlyResident: currentlyResident)
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        return p.evict.contains { byID[$0]?.role == .chat }
    }
}
