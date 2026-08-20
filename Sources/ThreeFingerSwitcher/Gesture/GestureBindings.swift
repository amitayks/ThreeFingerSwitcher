import Foundation

// MARK: - Gesture bindings (pure Core)

/// User-configurable gesture bindings — today, the window switcher's per-axis scrub directions.
///
/// The model is a pure value type — the recognizer's raw-direction emission is unchanged; only the
/// *action* an excursion maps to is configurable. Defaults equal today's hardcoded behavior exactly:
/// both switcher axes scrub normally.
///
/// A stored blob written by an older build may carry retired surfaces (the former AI-canvas and
/// Files-drill bindings) as extra JSON keys; `JSONDecoder` ignores unknown keys, so those records
/// still decode into just the switcher binding.
public struct GestureBindings: Codable, Equatable, Sendable {
    public var switcher: SwitcherBinding

    public init(switcher: SwitcherBinding = .default) {
        self.switcher = switcher
    }

    /// Every surface bound to exactly today's behavior.
    public static let `default` = GestureBindings()
}

// MARK: - Window switcher

extension GestureBindings {
    /// The scrub direction of a switcher axis. `normal` reproduces today's mapping; `reversed` flips
    /// the sign of the index movement only (never the magnitude or step distance).
    public enum AxisDirection: String, Codable, CaseIterable, Identifiable, Sendable {
        case normal
        case reversed
        public var id: String { rawValue }

        /// Bridge to the old boolean `reverse…` accessors (a `true` means reversed).
        public init(reversed: Bool) { self = reversed ? .reversed : .normal }
        public var isReversed: Bool { self == .reversed }
    }

    /// The switcher's per-axis scrub directions. Folds the former `reverseDirection` /
    /// `reverseVerticalDirection` booleans into the single source of truth.
    public struct SwitcherBinding: Codable, Equatable, Sendable {
        /// Horizontal axis: stepping between windows within a Space-row.
        public var windowsAxis: AxisDirection
        /// Vertical axis: stepping between Space-rows.
        public var spacesAxis: AxisDirection

        public init(windowsAxis: AxisDirection, spacesAxis: AxisDirection) {
            self.windowsAxis = windowsAxis
            self.spacesAxis = spacesAxis
        }

        /// Today's behavior: both axes normal (no reversal).
        public static let `default` = SwitcherBinding(windowsAxis: .normal, spacesAxis: .normal)
    }
}
