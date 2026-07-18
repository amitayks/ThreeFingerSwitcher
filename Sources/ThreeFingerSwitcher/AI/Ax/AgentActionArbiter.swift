import Foundation
import CoreGraphics

/// The agent-vs-human input arbitration (`add-voice-computer-use-agent`, design D9 / spec "Any human
/// trackpad touch aborts agent action instantly"). Two jobs:
///
/// 1. **Tagged synthetic input**: every synthetic keyboard event the agent posts comes from THIS
///    arbiter's `CGEventSource`, whose `userData` carries a magic tag. The app's own event taps call
///    `isSyntheticAgentEvent(_:)` and IGNORE tagged events — the agent's typing can never be misread
///    as human gestures or trip the ⌘-Tab/scroll taps.
/// 2. **The kill switch**: while `isActing`, a HUMAN trackpad contact (fed from the raw touch
///    stream) triggers `abort()` — cancelling the in-flight act/turn as a DISCARD. The human always
///    wins the input; the visible "agent has the wheel" indicator binds to `isActing`.
@MainActor
public final class AgentActionArbiter: ObservableObject {

    /// The magic tag on every agent-posted event (`CGEventSource.userData`).
    public static let syntheticTag: Int64 = 0x7F53_A6E7

    /// True while an acting tool (click/type) is executing — drives the on-screen indicator and arms
    /// the touch kill switch.
    @Published public private(set) var isActing = false

    /// Called on abort (human touch during an act): the coordinator wires this to cancel the
    /// in-flight turn (engine discard + voice abort). The abort is an acknowledgment path, not an
    /// error path.
    public var onAbort: (@MainActor () -> Void)?

    /// The tagged source for ALL synthetic agent input.
    public let eventSource: CGEventSource?

    private var actingDepth = 0
    private var abortedCurrentAct = false

    public init() {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = Self.syntheticTag
        self.eventSource = source
    }

    /// Whether `event` was posted by the agent itself (the taps' ignore rule).
    public nonisolated static func isSyntheticAgentEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticTag
    }

    /// Run one acting scope. Nesting-safe (a tool that acts twice keeps the indicator up); the abort
    /// flag resets per outermost scope.
    public func acting<T>(_ body: () async throws -> T) async rethrows -> T {
        actingDepth += 1
        if actingDepth == 1 {
            abortedCurrentAct = false
            isActing = true
        }
        defer {
            actingDepth -= 1
            if actingDepth == 0 { isActing = false }
        }
        return try await body()
    }

    /// A HUMAN trackpad contact arrived. Only bites while acting — normal app gestures are untouched.
    public func humanTouchDetected() {
        guard isActing, !abortedCurrentAct else { return }
        abortedCurrentAct = true
        onAbort?()
    }
}
