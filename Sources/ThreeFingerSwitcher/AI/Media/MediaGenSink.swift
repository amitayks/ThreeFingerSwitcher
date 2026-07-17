import Foundation

/// The media job's observable progress sink — the canvas (output #2) + the parked feed (§7) subscribe to
/// it so they advance in lockstep with the generation, and so a heavy gen's "busy painting" state is
/// surfaced not hidden (design D9). The `MediaGenSink` calls these as it drives the runtime; a test spy
/// records them. Every method is non-throwing (observation never breaks the gen). MLX-free Core.
public protocol MediaJobObserving: Sendable {
    /// Residency decided (before any compute) — `.busyPainting` means chat was evicted.
    func didDecideResidency(_ note: MediaResidencyNote)
    /// A diffusion step settled (live preview + the parked thinking badge).
    func didStep(index: Int, total: Int, preview: Data?)
    /// The gen finished with its terminal asset.
    func didFinish(_ asset: MediaAsset)
    /// The gen failed with a CLEAN headline (already routed through `AIError.message(for:)`).
    func didFail(headline: String)
    /// The gen was cancelled (a discard) — DISTINCT from a failure (no failed badge).
    func didCancel()
}

/// A no-op observer (a context with no canvas/rail wired) — a safe default.
public struct NoopMediaJobObserver: MediaJobObserving {
    public init() {}
    public func didDecideResidency(_ note: MediaResidencyNote) {}
    public func didStep(index: Int, total: Int, preview: Data?) {}
    public func didFinish(_ asset: MediaAsset) {}
    public func didFail(headline: String) {}
    public func didCancel() {}
}

/// The route-loop executor for a routed media call (design D2/D3, §3). Invoked by the EXISTING route →
/// execute → continue loop when the router selects `generate_image`/`generate_video` — no new control
/// flow. It:
///   1. resolves the EFFECTIVE write-policy tier via the injected `WritePolicyResolving` (a `.dangerous`
///      cloud-video tier is NEVER lowered);
///   2. for `.confirm`/`.dangerous`, surfaces an AWAITING-APPROVAL step (DOWN=approve / RIGHT=skip)
///      BEFORE any compute or spend;
///   3. enforces the cloud-video BUDGET CAP before the call (an exhausted budget → clean `.failed`/
///      `.declined`, NO spend);
///   4. resolves the SEED (img2img/img2video) from the existing captures (a missing-but-required seed →
///      `MediaError.seedRequired`; an undecodable seed → `.seedInvalid`);
///   5. consults `ModelRegistry`/`ensureResident` (surfacing "busy painting" when the gen evicts chat);
///   6. drives the runtime's `generate(_:)`, threading `MediaProgress` into the observer (canvas + parked
///      feed);
///   7. writes the finished asset to the gallery (output #1);
///   8. writes ONE `AuditRecord` for the terminal outcome;
///   9. returns a `ToolStepResult` — `.done` (gallery path) / `.declined` / `.failed` (clean headline).
///      Cancellation is NOT a failure (design D10).
///
/// Pure orchestration over injected seams — MLX-free Core, `swift test`-verified against `StubMediaRuntime`.
struct MediaGenSink: Sendable {
    private let imageRuntime: MediaRuntime?
    private let videoRuntime: MediaRuntime?
    private let resolver: WritePolicyResolving
    private let seed: MediaSeedResolving
    private let gallery: MediaGalleryWriting
    private let budget: MediaVideoBudgeting
    private let residency: MediaResidencyCoordinator?
    private let observer: MediaJobObserving
    private let audit: AuditLog?
    /// The session this call runs for (audit attribution + parked feed). A foreground call may pass a
    /// fresh id; a parked subagent passes its session id.
    private let sessionID: AgentSessionID
    /// The runtime's model id for the residency check (image/video backend). nil → skip residency.
    private let imageModelID: String?
    private let videoModelID: String?
    /// Whether this call is running in the background (parked) — recorded on the audit record.
    private let isBackground: Bool
    private let now: @Sendable () -> Date

    init(imageRuntime: MediaRuntime?,
                videoRuntime: MediaRuntime?,
                resolver: WritePolicyResolving = DescriptorWritePolicy(),
                seed: MediaSeedResolving = NoSeed(),
                gallery: MediaGalleryWriting,
                budget: MediaVideoBudgeting,
                residency: MediaResidencyCoordinator? = nil,
                observer: MediaJobObserving = NoopMediaJobObserver(),
                audit: AuditLog? = nil,
                sessionID: AgentSessionID = AgentSessionID(),
                imageModelID: String? = nil,
                videoModelID: String? = nil,
                isBackground: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.imageRuntime = imageRuntime
        self.videoRuntime = videoRuntime
        self.resolver = resolver
        self.seed = seed
        self.gallery = gallery
        self.budget = budget
        self.residency = residency
        self.observer = observer
        self.audit = audit
        self.sessionID = sessionID
        self.imageModelID = imageModelID
        self.videoModelID = videoModelID
        self.isBackground = isBackground
        self.now = now
    }

    /// The kind the routed tool generates (or nil for a non-media tool — defensive).
    private func kind(for tool: String) -> MediaKind? {
        switch tool {
        case MediaTool.generateImage: return .image
        case MediaTool.generateVideo: return .video
        default: return nil
        }
    }

    private func runtime(for kind: MediaKind) -> MediaRuntime? {
        switch kind {
        case .image: return imageRuntime
        case .video: return videoRuntime
        }
    }

    private func modelID(for kind: MediaKind) -> String? {
        switch kind {
        case .image: return imageModelID
        case .video: return videoModelID
        }
    }

    func run(_ call: RoutedCall, gate: ApprovalGate) async -> ToolStepResult {
        let tool = call.descriptor.name
        guard let kind = kind(for: tool) else {
            return failed(tool: tool, error: MediaError.noCapableBackend(kind: .image),
                          effectiveTier: call.descriptor.writePolicy, argsSummary: "")
        }

        let args = MediaArgs.parse(argumentsJSON: call.route.argumentsJSON, userText: call.userText)
        let argsSummary = AuditRedaction.summary(forRawArguments: call.route.argumentsJSON)

        // (1) Effective tier — `.dangerous` (cloud video) is NEVER lowered (the resolver enforces that).
        let effectiveTier = resolver.effectiveTier(for: call.descriptor)

        // (3a) BUDGET — checked BEFORE approval AND before any spend for cloud video. An exhausted budget
        // refuses with NO compute, NO network, NO spend (design D3).
        let isCloudVideo = (kind == .video && effectiveTier == .dangerous)
        if isCloudVideo, !budget.hasRemaining(now: now()) {
            return failed(tool: tool, error: MediaError.cloudBudgetExhausted,
                          effectiveTier: effectiveTier, argsSummary: argsSummary)
        }

        // (5) A capable runtime must exist (the contributor already gates this, but defend the dead end).
        guard let runtime = runtime(for: kind), runtime.capabilities.contains(kind) else {
            return failed(tool: tool, error: MediaError.noCapableBackend(kind: kind),
                          effectiveTier: effectiveTier, argsSummary: argsSummary)
        }

        // (2) APPROVAL — `.confirm`/`.dangerous` pause as an awaiting-approval step BEFORE any compute or
        // spend; `.auto` runs straight through (the resolver lowered it via an explicit whitelist).
        switch effectiveTier {
        case .auto:
            break
        case .confirm, .dangerous:
            let review = Self.approvalReview(tool: tool, args: args, kind: kind, dangerous: effectiveTier == .dangerous)
            switch await gate.awaitDecision(for: review) {
            case .approve:
                break
            case .skip:
                recordAudit(tool: tool, tier: effectiveTier,
                            outcome: .declined(reason: "skipped"), argsSummary: argsSummary)
                return ToolStepResult(tool: tool, status: .declined(reason: "skipped"),
                                      summary: "Skipped \(Self.kindNoun(kind)) generation.")
            case .cancel:
                // The whole canvas was discarded — a cancellation, NOT a failure (no audit-failed, no
                // failed badge). Recorded as declined-cancelled (the loop's sentinel).
                observer.didCancel()
                recordAudit(tool: tool, tier: effectiveTier,
                            outcome: .declined(reason: Self.cancelledReason), argsSummary: argsSummary)
                return ToolStepResult(tool: tool, status: .declined(reason: Self.cancelledReason),
                                      summary: "Cancelled.")
            }
        }

        // (4) SEED — resolve from the existing captures. A tool authored as img2img/img2video that names a
        // seed but resolves none → `.seedRequired`; a present-but-undecodable seed → `.seedInvalid`. Never
        // a fabricated blank frame, never compute on a bad seed.
        var seedBytes: Data?
        if args.requiresSeed {
            guard let bytes = seed.resolveSeed() else {
                return failed(tool: tool, error: MediaError.seedRequired,
                              effectiveTier: effectiveTier, argsSummary: argsSummary)
            }
            guard MediaSeedValidation.isDecodablePNG(bytes) else {
                return failed(tool: tool, error: MediaError.seedInvalid,
                              effectiveTier: effectiveTier, argsSummary: argsSummary)
            }
            seedBytes = bytes
        }

        // (3b) Spend is now COMMITTED for cloud video — count it against the per-day cap (the cap counts
        // admitted generations, like the handoff per-day count).
        if isCloudVideo { budget.consume(now: now()) }

        // (5) RESIDENCY — make room; surface "busy painting" if the gen evicts chat. A target that can't
        // be admitted at all maps to a clean `.failed` (never a hang).
        if let residency, let id = modelID(for: kind) {
            do {
                let note = try await residency.ensureRoom(for: id)
                observer.didDecideResidency(note)
            } catch {
                return failed(tool: tool, error: error, effectiveTier: effectiveTier, argsSummary: argsSummary)
            }
        }

        // (6–7) DRIVE the runtime, thread progress, write the finished asset.
        let request = args.request(kind: kind, seed: seedBytes)
        do {
            var finished: MediaAsset?
            for try await progress in runtime.generate(request) {
                switch progress {
                case let .step(index, total, preview):
                    observer.didStep(index: index, total: total, preview: preview)
                case let .finished(asset):
                    finished = asset
                }
            }
            guard let asset = finished else {
                // The stream ended without finishing AND without throwing — treat as a cancellation
                // (a discarded gen stops the stream cleanly). Distinct from a failure (design D10).
                observer.didCancel()
                recordAudit(tool: tool, tier: effectiveTier,
                            outcome: .declined(reason: Self.cancelledReason), argsSummary: argsSummary)
                return ToolStepResult(tool: tool, status: .declined(reason: Self.cancelledReason),
                                      summary: "Cancelled.")
            }
            observer.didFinish(asset)
            recordAudit(tool: tool, tier: effectiveTier, outcome: .done, argsSummary: argsSummary)
            return ToolStepResult(tool: tool, status: .done,
                                  summary: "Generated \(Self.kindNoun(kind)) → \(asset.url.lastPathComponent).")
        } catch {
            // (8) A CANCELLATION is distinct from a failure (design D10): no failed badge, no failed audit.
            if MediaOutcome.isCancellation(error) {
                observer.didCancel()
                recordAudit(tool: tool, tier: effectiveTier,
                            outcome: .declined(reason: Self.cancelledReason), argsSummary: argsSummary)
                return ToolStepResult(tool: tool, status: .declined(reason: Self.cancelledReason),
                                      summary: "Cancelled.")
            }
            return failed(tool: tool, error: error, effectiveTier: effectiveTier, argsSummary: argsSummary)
        }
    }

    // MARK: - Terminal helpers

    /// A sentinel decline reason the loop recognizes as "the user cancelled the whole canvas" (mirrors
    /// `TaskKindToolContributor.cancelledReason`).
    public static let cancelledReason = "__cancelled__"

    /// Build a clean `.failed` result: map the error → a clean headline (THE one translator), notify the
    /// observer, write the failed audit (a `.failed` carries the clean headline only), and return.
    private func failed(tool: String, error: Error, effectiveTier: WritePolicyTier,
                        argsSummary: String) -> ToolStepResult {
        let headline = AIError.message(for: error).headline
        observer.didFail(headline: headline)
        recordAudit(tool: tool, tier: effectiveTier, outcome: .failed(headline: headline),
                    argsSummary: argsSummary)
        return ToolStepResult(tool: tool, status: .failed(headline: headline),
                              summary: "Couldn't generate \(Self.kindNoun(kindNounFallback(tool))).")
    }

    private func kindNounFallback(_ tool: String) -> MediaKind {
        kind(for: tool) ?? .image
    }

    /// Write exactly ONE audit record per terminal media step (auto/confirmed/declined/escalated/failed),
    /// with the EFFECTIVE tier + a redacted args summary; a `.failed` carries only the clean headline
    /// (already on the outcome). Non-blocking + infallible (the `AuditLog` contract).
    private func recordAudit(tool: String, tier: WritePolicyTier, outcome: ToolStepStatus,
                             argsSummary: String) {
        guard let audit else { return }
        audit.record(AuditRecord(sessionID: sessionID, tool: tool, policy: tier,
                                 argumentsSummary: argsSummary, outcome: outcome,
                                 wasBackground: isBackground, timestamp: now()))
    }

    // MARK: - Approval review

    /// The `TaskReview`-backed awaiting-approval surface for a `.confirm`/`.dangerous` media step — a
    /// concrete preview (prompt + size + steps + the spend warning for cloud video) the canvas renders and
    /// the compass resolves (DOWN=approve / RIGHT=skip). The `.unavailable` payload is unused; we model the
    /// review as a no-op `.action` whose `fields` carry the preview (no side effect rides on it — the sink
    /// runs the gen itself on approval).
    static func approvalReview(tool: String, args: MediaArgs, kind: MediaKind, dangerous: Bool) -> TaskReview {
        var fields: [ReviewField] = [
            ReviewField("Prompt", args.prompt.isEmpty ? "(none)" : args.prompt),
            ReviewField("Size", "\(args.width ?? MediaSize.square1024.width)×\(args.height ?? MediaSize.square1024.height)")
        ]
        if let d = args.durationMs, kind == .video { fields.append(ReviewField("Duration", "\(d) ms")) }
        if dangerous { fields.append(ReviewField("Note", "Cloud video — this spends from today's budget.")) }
        let title = "Generate \(kindNoun(kind))"
        // The payload is a benign placeholder — the sink, not the dispatcher, performs the generation on
        // approval (media is a tool whose executor is the MediaRuntime, design D1/D2).
        return .action(title: title, fields: fields,
                       payload: .openTool(tool: tool,
                                          action: ParsedOpenTool(applicable: true, reason: nil, payload: args.prompt)))
    }

    static func kindNoun(_ kind: MediaKind) -> String {
        switch kind {
        case .image: return "image"
        case .video: return "video"
        }
    }
}
