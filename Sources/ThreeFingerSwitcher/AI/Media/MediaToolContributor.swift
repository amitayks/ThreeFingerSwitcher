import Foundation

/// The two media tools in the `ToolRegistry` (design D2/D11). `generate_image` and `generate_video` are
/// ordinary `ToolDescriptor`s contributed through the EXISTING `ToolContributor` seam — no route-loop
/// change. When the router selects one, the loop dispatches to `MediaGenSink` (the contributor's `run`)
/// exactly as it dispatches a task kind. The model "chose the menu item"; the sink does the long job.
///
/// Availability gating (design D11 — the router never routes to a dead end): the contributor advertises
///  - `generate_image` ONLY if `mediaGenEnabled && fullPotentialEnabled` AND an image `MediaRuntime`
///    advertises `.image`;
///  - `generate_video` ONLY if the master/media flags are on AND a video provider exists AND (for cloud)
///    `fleetCloudEscalationEnabled` is on AND the per-day budget has room left.
/// Under either flag OFF, the contributor contributes NOTHING.
///
/// MLX-free Core.

// MARK: - Availability

/// The gating inputs the contributor reads to decide which media tools are live. The flags are OWNED by
/// `ai-full-potential-toggle` (§D1) / `ai-model-fleet`; this slice CONSUMES them via injected closures
/// (default OFF), exactly like `FleetCloudGate`. `now` feeds the budget check.
public struct MediaToolAvailability: Sendable {
    /// Master gate (`fullPotentialEnabled`) — a sub-flag never overrides the master OFF.
    public let isFullPotentialEnabled: @Sendable () -> Bool
    /// The media sub-flag (`mediaGenEnabled`).
    public let isMediaGenEnabled: @Sendable () -> Bool
    /// Cloud escalation (`fleetCloudEscalationEnabled`) — required for a CLOUD video provider.
    public let isCloudEscalationEnabled: @Sendable () -> Bool
    /// Whether a video provider is configured at all (cloud or local LTXV). A `nil`/false → no video tool.
    public let hasVideoProvider: @Sendable () -> Bool
    /// Whether the configured video provider is cloud (→ `.dangerous` + budget + cloud gate) vs local.
    public let videoProviderIsCloud: @Sendable () -> Bool

    public init(isFullPotentialEnabled: @escaping @Sendable () -> Bool = { false },
                isMediaGenEnabled: @escaping @Sendable () -> Bool = { false },
                isCloudEscalationEnabled: @escaping @Sendable () -> Bool = { false },
                hasVideoProvider: @escaping @Sendable () -> Bool = { false },
                videoProviderIsCloud: @escaping @Sendable () -> Bool = { true }) {
        self.isFullPotentialEnabled = isFullPotentialEnabled
        self.isMediaGenEnabled = isMediaGenEnabled
        self.isCloudEscalationEnabled = isCloudEscalationEnabled
        self.hasVideoProvider = hasVideoProvider
        self.videoProviderIsCloud = videoProviderIsCloud
    }

    /// The master ∧ media predicate — the floor for offering ANY media tool.
    var mediaActive: Bool { isFullPotentialEnabled() && isMediaGenEnabled() }
}

// MARK: - Tool names (stable routing keys)

public enum MediaTool {
    public static let generateImage = "generate_image"
    public static let generateVideo = "generate_video"
}

// MARK: - Contributor

/// Contributes the two media tools and runs a routed media call via the injected `MediaGenSink`.
struct MediaToolContributor: ToolContributor {
    private let availability: MediaToolAvailability
    /// The image runtime (its `capabilities` must advertise `.image` for `generate_image` to appear).
    private let imageRuntime: MediaRuntime?
    /// The video runtime (its `capabilities` must advertise `.video` for `generate_video` to appear).
    private let videoRuntime: MediaRuntime?
    private let budget: MediaVideoBudgeting
    private let sink: MediaGenSink
    /// Injected clock for the budget check (deterministic in tests).
    private let now: @Sendable () -> Date

    init(availability: MediaToolAvailability,
                imageRuntime: MediaRuntime?,
                videoRuntime: MediaRuntime?,
                budget: MediaVideoBudgeting,
                sink: MediaGenSink,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.availability = availability
        self.imageRuntime = imageRuntime
        self.videoRuntime = videoRuntime
        self.budget = budget
        self.sink = sink
        self.now = now
    }

    // MARK: ToolContributor

    func descriptors() -> [ToolDescriptor] {
        guard availability.mediaActive else { return [] }   // master ∧ media floor (D11)
        var out: [ToolDescriptor] = []
        if imageAvailable { out.append(Self.imageDescriptor) }
        if videoAvailable { out.append(videoDescriptor) }
        return out
    }

    func canHandle(_ tool: String) -> Bool {
        tool == MediaTool.generateImage || tool == MediaTool.generateVideo
    }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        await sink.run(call, gate: gate)
    }

    // MARK: Availability (D11)

    /// `generate_image` is live iff master ∧ media AND an image runtime advertises `.image`.
    var imageAvailable: Bool {
        guard availability.mediaActive else { return false }
        return imageRuntime?.capabilities.contains(.image) ?? false
    }

    /// `generate_video` is live iff master ∧ media AND a video runtime advertises `.video` AND a video
    /// provider is configured AND (for cloud) cloud escalation is on AND the per-day budget has room.
    var videoAvailable: Bool {
        guard availability.mediaActive else { return false }
        guard videoRuntime?.capabilities.contains(.video) ?? false else { return false }
        guard availability.hasVideoProvider() else { return false }
        if availability.videoProviderIsCloud() {
            guard availability.isCloudEscalationEnabled() else { return false }
            guard budget.hasRemaining(now: now()) else { return false }
        }
        return true
    }

    // MARK: Descriptors

    /// `generate_image`: a `.confirm`-tier tool (design D3) — local but GPU-saturating + evicts chat, so
    /// it confirms before painting.
    static let imageDescriptor = ToolDescriptor(
        name: MediaTool.generateImage,
        summary: "Generate an image from a text prompt (optionally from a source image).",
        argsSchema: StructuredSchema(name: MediaTool.generateImage, json: imageArgsSchemaJSON),
        writePolicy: .confirm,
        keywords: ["image", "picture", "draw", "render", "generate", "art", "illustration", "photo"]
    )

    /// `generate_video`: `.dangerous` when the provider is cloud (real spend, leaves the device — escalates
    /// even when parked), `.confirm` for a local provider. Budget-capped at the sink regardless.
    var videoDescriptor: ToolDescriptor {
        let tier: WritePolicyTier = availability.videoProviderIsCloud() ? .dangerous : .confirm
        return ToolDescriptor(
            name: MediaTool.generateVideo,
            summary: "Generate a short video clip from a prompt (optionally animating a source image).",
            argsSchema: StructuredSchema(name: MediaTool.generateVideo, json: Self.videoArgsSchemaJSON),
            writePolicy: tier,
            keywords: ["video", "animate", "animation", "clip", "motion", "film", "generate"]
        )
    }

    // MARK: argsSchema

    /// Prompt + size (width/height) + steps + an optional seed-image handle. The handle is a STRING tag
    /// (`"screenRegion"`/`"clipboardImage"`) the sink resolves through the existing capture seams — the
    /// JSON never carries raw image bytes.
    static let imageArgsSchemaJSON = """
    {"type":"object","required":["prompt"],"properties":{\
    "prompt":{"type":"string"},\
    "width":{"type":"integer","minimum":64,"maximum":2048},\
    "height":{"type":"integer","minimum":64,"maximum":2048},\
    "steps":{"type":"integer","minimum":1,"maximum":100},\
    "seedImage":{"type":"string","enum":["screenRegion","clipboardImage"]}}}
    """

    /// As image, plus a video `durationMs`.
    static let videoArgsSchemaJSON = """
    {"type":"object","required":["prompt"],"properties":{\
    "prompt":{"type":"string"},\
    "width":{"type":"integer","minimum":64,"maximum":2048},\
    "height":{"type":"integer","minimum":64,"maximum":2048},\
    "steps":{"type":"integer","minimum":1,"maximum":100},\
    "durationMs":{"type":"integer","minimum":200,"maximum":20000},\
    "seedImage":{"type":"string","enum":["screenRegion","clipboardImage"]}}}
    """
}
