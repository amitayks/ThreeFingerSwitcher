import Foundation

/// The pure cost-disclosure + busy-painting STATE values for the local image backend (design D5, tasks
/// 5.1–5.3 pure parts). The disclosure ethos: state RAM / heat / latency cost IN THE SAME BREATH the
/// capability is offered. Both this disclosure AND the runtime's pre-flight "busy painting" decision read
/// the SAME `ImageResidencyClass` value (task 2.3) — so what the user is TOLD before firing and what the
/// runtime DOES at fire can never disagree.
///
/// All values are pure (computed from the chosen descriptor + the injected `ImageResidencyClass`), so the
/// underlying numbers are `swift test`-verified; the app UI (a Hub row / the canvas pre-fire card) renders
/// these strings and is `xcodebuild` compile-verified, run-verified by the user.
///
/// MLX-free Core.
public struct ImageCostDisclosure: Equatable, Sendable {
    /// The RAM line — the resident footprint AND its co-reside-vs-evict-chat consequence (from the class).
    public let ram: String
    /// The heat/compute note — sustained M5 GPU diffusion (the neural-accelerator sweet spot is still a burn).
    public let heat: String
    /// The latency note — seconds-to-tens-of-seconds at default steps.
    public let latency: String
    /// True when the chosen variant EVICTS chat (FP16) — the UI emphasises the "chat pauses" consequence.
    public let evictsChat: Bool

    public init(ram: String, heat: String, latency: String, evictsChat: Bool) {
        self.ram = ram
        self.heat = heat
        self.latency = latency
        self.evictsChat = evictsChat
    }

    /// Build the disclosure for a chosen image `descriptor` given its residency `classification` (the
    /// SINGLE input — design D4/D5). The RAM line reflects co-resident (~7 GB, chat stays alive) vs
    /// evicts-chat (~24 GB, chat pauses).
    public static func make(descriptor: ModelDescriptor,
                            classification: ImageResidencyClass) -> ImageCostDisclosure {
        let gb = Double(descriptor.residencyBytes) / Double(1024 * 1024 * 1024)
        let gbRounded = (gb * 10).rounded() / 10
        let evicts = (classification == .evictsChat)
        let ram: String
        if evicts {
            ram = "~\(format(gbRounded)) GB resident — this PAUSES the chat model while it paints (chat resumes when it's done)."
        } else {
            ram = "~\(format(gbRounded)) GB resident — co-resides with chat (the assistant keeps talking while it paints)."
        }
        return ImageCostDisclosure(
            ram: ram,
            heat: "Sustained GPU diffusion — the M5 neural accelerators run hot for the duration.",
            latency: "Seconds to tens of seconds per image at default steps.",
            evictsChat: evicts
        )
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

/// The pre-flight "busy painting" decision (design D5, task 5.2) — a PURE function over the residency
/// class. It is the runtime/sink's pre-flight state decision input, the SAME class value the disclosure
/// reads (task 2.3). `.busyPainting` ↔ `.evictsChat`; `.coResident` otherwise. It maps onto the seam's
/// existing `MediaResidencyNote` (`ai-media-runtime`) so the canvas/rail surface is unchanged — this
/// slice does NOT introduce a second busy-state type, it derives the seam's note from its own classifier.
public enum ImageBusyPaintingState: Equatable, Sendable {
    /// Chat stays available (Q4 co-resident) — no busy banner.
    case coResident
    /// Chat is unavailable while FP16 paints — surface the calm, bounded "busy painting" state (never an
    /// `NSAlert`, never raw error text). Chat resumes when the gen finishes / parks.
    case busyPainting

    /// Derive the pre-flight state from the residency classification (the single shared input).
    public init(_ classification: ImageResidencyClass) {
        self = (classification == .evictsChat) ? .busyPainting : .coResident
    }

    /// Bridge to the seam's existing `MediaResidencyNote` (so the canvas/rail observer is unchanged).
    public var residencyNote: MediaResidencyNote {
        switch self {
        case .coResident:   return .coResident
        case .busyPainting: return .busyPainting
        }
    }
}
