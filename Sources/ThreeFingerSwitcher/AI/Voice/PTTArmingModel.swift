import Foundation

/// The push-to-talk trigger state machine (`voice-double-tap-dwell-trigger`): **double-tap-then-hold**,
/// the macOS dictation idiom. Pure; the NSEvent monitor is a thin one-timer driver.
///
/// Grammar: a first CLICK of the key (down and up, each within `tapMaxDuration`), a second press
/// within `secondTapGap`, HELD past `dwellTime` → push-to-talk begins (`firePTTDown`); release sends
/// (`firePTTUp`). Everything else is structurally a no-op:
/// - a LONG SINGLE hold is plain modifier use (special-character typing untouched),
/// - a bare double-tap without the dwell does nothing,
/// - any OTHER key at any pre-capture stage cancels to typing (chords can never trigger voice),
/// - the capture stack is untouched, and the mic closed, until the dwell elapses.
///
/// Exactly ONE timer is pending in any phase (tap-max in `firstDown`, gap in `awaitingSecond`,
/// dwell in `dwelling`), so the driver needs a single one-shot slot and an undifferentiated
/// `.timerFired` event is unambiguous.
public struct PTTArmingModel {

    /// Max down-time (and up-time symmetry) for a press to read as a "click".
    public static let tapMaxDuration: TimeInterval = 0.30
    /// Max wait between the first click's release and the second press.
    public static let secondTapGap: TimeInterval = 0.30
    /// How long the second press must be held before capture begins.
    public static let dwellTime: TimeInterval = 0.15

    public enum Phase: Equatable, Sendable {
        case idle
        /// First press is down; the tap-max timer decides click vs plain hold.
        case firstDown
        /// First click completed; waiting (gap timer) for the second press.
        case awaitingSecond
        /// Second press is down; the dwell timer decides talk vs bare double-tap.
        case dwelling
        /// Push-to-talk is live (capture running).
        case held
        /// The key is down but the gesture is disqualified (long hold / chord) — wait for release.
        case inert
    }

    public enum Event: Equatable, Sendable {
        case pttFlagDown
        case pttFlagUp
        /// Any OTHER key went down (the chord/typing signal, observed passively).
        case otherKeyDown
        /// The phase's one pending timer fired.
        case timerFired
    }

    public enum TimerKind: Equatable, Sendable {
        case tapMax
        case gap
        case dwell

        public var duration: TimeInterval {
            switch self {
            case .tapMax: return PTTArmingModel.tapMaxDuration
            case .gap:    return PTTArmingModel.secondTapGap
            case .dwell:  return PTTArmingModel.dwellTime
            }
        }
    }

    public enum Action: Equatable, Sendable {
        case schedule(TimerKind)
        case cancelTimer
        /// Begin push-to-talk (capture starts HERE, never earlier).
        case firePTTDown
        /// End push-to-talk.
        case firePTTUp
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func handle(_ event: Event) -> [Action] {
        switch (phase, event) {

        // MARK: idle
        case (.idle, .pttFlagDown):
            phase = .firstDown
            return [.schedule(.tapMax)]

        // MARK: firstDown (click vs plain hold)
        case (.firstDown, .pttFlagUp):
            phase = .awaitingSecond
            return [.cancelTimer, .schedule(.gap)]
        case (.firstDown, .timerFired):
            // Held too long for a click: plain modifier use — stand down until release.
            phase = .inert
            return []
        case (.firstDown, .otherKeyDown):
            phase = .inert
            return [.cancelTimer]

        // MARK: awaitingSecond (the gap)
        case (.awaitingSecond, .pttFlagDown):
            phase = .dwelling
            return [.cancelTimer, .schedule(.dwell)]
        case (.awaitingSecond, .timerFired):
            phase = .idle          // no second tap came
            return []
        case (.awaitingSecond, .otherKeyDown):
            phase = .idle          // typing resumed between taps
            return [.cancelTimer]

        // MARK: dwelling (talk vs bare double-tap)
        case (.dwelling, .timerFired):
            phase = .held
            return [.firePTTDown]
        case (.dwelling, .pttFlagUp):
            phase = .idle          // bare double-tap: a complete no-op
            return [.cancelTimer]
        case (.dwelling, .otherKeyDown):
            phase = .inert
            return [.cancelTimer]

        // MARK: held (talking)
        case (.held, .pttFlagUp):
            phase = .idle
            return [.firePTTUp]
        case (.held, .otherKeyDown):
            return []              // keys while genuinely talking don't cancel

        // MARK: inert (disqualified; wait for the key to come back up)
        case (.inert, .pttFlagUp):
            phase = .idle
            return []

        default:
            return []
        }
    }
}
