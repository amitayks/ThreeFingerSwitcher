import Foundation

/// The auto-mode gate wrapper (`add-voice-computer-use-agent`, design D7 / spec "Acts respect the
/// write-policy gate, with a per-conversation auto-approve mode"): wraps the real foreground gate;
/// while the conversation's grant is live, a `.confirm` pause resolves `.approve` IMMEDIATELY and
/// the act is narrated (spoken when voice is active, always visible) — silence never hides an act.
/// Without the grant it is a transparent pass-through. The `enable_auto_mode` tool itself always
/// reaches the BASE gate through its own `.confirm` tier before any grant exists, so turning auto
/// mode on is the one approval that can't be skipped.
/// A lock-guarded boolean readable from any thread — the auto-grant's live storage. The route loop
/// reads it OFF the main actor (same reason `ParkScheduler.parkState(of:)` is lock-guarded), while
/// the engine mutates it on the main actor.
public final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init(_ initial: Bool = false) { flag = initial }

    public var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

/// The VOICE surface's base gate (`add-voice-computer-use-agent`): a voice conversation has no
/// approval canvas, so a `.confirm` step that reaches here SPEAKS one line of guidance and SKIPS —
/// never a silent decline, never a fabricated approval. Acts by voice therefore require the
/// auto-mode grant (given explicitly in the spoken command or on the surface toggle), which the
/// wrapping `AutoApprovingGate` resolves before this gate is ever consulted.
final class SpokenGuidanceGate: ApprovalGate {
    private let speak: @Sendable (String) -> Void

    init(speak: @escaping @Sendable (String) -> Void) {
        self.speak = speak
    }

    func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
        if case let .action(title, _, _) = review {
            speak("\(title) needs approval. Say “enable auto mode” to let me act, or use the chat surface.")
        }
        return .skip
    }
}

final class AutoApprovingGate: ApprovalGate {
    private let base: ApprovalGate
    /// Live read of the conversation's grant (thread-safe — the loop calls off-main).
    private let isGranted: @Sendable () -> Bool
    /// Narration sink for auto-approved acts (title + preview fields, one line).
    private let narrate: @Sendable (String) -> Void

    init(base: ApprovalGate,
         isGranted: @escaping @Sendable () -> Bool,
         narrate: @escaping @Sendable (String) -> Void = { _ in }) {
        self.base = base
        self.isGranted = isGranted
        self.narrate = narrate
    }

    func awaitDecision(for review: TaskReview) async -> ApprovalDecision {
        guard isGranted() else {
            return await base.awaitDecision(for: review)
        }
        if case let .action(title, fields, _) = review {
            let detail = fields.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
            narrate("Auto: \(title)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        return .approve
    }
}
