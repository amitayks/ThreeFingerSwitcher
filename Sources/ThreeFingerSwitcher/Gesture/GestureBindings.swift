import Foundation

// MARK: - Gesture bindings (pure, MLX-free Core)

/// User-configurable **resolution**-gesture bindings for the three remappable open surfaces — the AI
/// command canvas, the Files-band drill, and the window switcher's scrub axes.
///
/// Each surface has its OWN action set and its OWN excursion vocabulary; they are deliberately distinct
/// grammars and are NOT unified into one remap (CLAUDE.md: "do not generalize it to this navigation
/// surface"; the spec delta forbids unification). The model is a pure value type — the recognizer's
/// raw-direction emission is unchanged; only the *action* an excursion maps to is configurable.
///
/// Defaults equal today's hardcoded behavior exactly: the canvas down-swipe commits / horizontal
/// dismisses / up is ignored; the Files drill lift opens / +1-finger lift opens-with / four-finger
/// horizontal discards; both switcher axes scrub normally.
///
/// The vocabularies exclude reserved/invalid excursions by construction: single-finger motion (never a
/// trigger anywhere) and the AI canvas's sub-threshold two-finger pan (which stays "read/scroll the
/// canvas") are simply not members of any excursion enum, so they can never be bound.
public struct GestureBindings: Codable, Equatable, Sendable {
    public var canvas: CanvasBinding
    public var filesDrill: FilesDrillBinding
    public var switcher: SwitcherBinding

    public init(
        canvas: CanvasBinding = .default,
        filesDrill: FilesDrillBinding = .default,
        switcher: SwitcherBinding = .default
    ) {
        self.canvas = canvas
        self.filesDrill = filesDrill
        self.switcher = switcher
    }

    /// Every surface bound to exactly today's behavior.
    public static let `default` = GestureBindings()
}

// MARK: - AI command canvas

extension GestureBindings {
    /// What an AI-canvas resolve excursion does. The canvas's `{commit, dismiss, ignore}` actions.
    public enum CanvasAction: String, Codable, CaseIterable, Identifiable, Sendable {
        case commit
        case dismiss
        case ignore
        public var id: String { rawValue }
    }

    /// The two-finger resolve excursions the canvas can bind. Deliberately excludes the sub-threshold
    /// two-finger pan (which scrolls/reads the canvas) and any single-finger motion — neither is a member.
    public enum CanvasExcursion: String, Codable, CaseIterable, Identifiable, Sendable {
        case swipeUp
        case swipeDown
        case swipeLeft
        case swipeRight
        public var id: String { rawValue }
    }

    /// The canvas action→excursion mapping. A strict one-to-one map: each of the three actions owns one
    /// distinct excursion. Four excursions exist, so exactly one excursion is the **spare** (unbound) —
    /// the consumer treats the spare per the surface's fallback (today: any horizontal excursion that is
    /// not explicitly bound elsewhere discards, preserving "horizontal = dismiss").
    public struct CanvasBinding: Codable, Equatable, Sendable {
        public var commit: CanvasExcursion
        public var dismiss: CanvasExcursion
        public var ignore: CanvasExcursion

        public init(commit: CanvasExcursion, dismiss: CanvasExcursion, ignore: CanvasExcursion) {
            self.commit = commit
            self.dismiss = dismiss
            self.ignore = ignore
        }

        /// Today's behavior: down = commit, horizontal = dismiss (bound to left; right is the spare and
        /// also discards in the consumer's "any horizontal" fallback), up = ignore.
        public static let `default` = CanvasBinding(commit: .swipeDown, dismiss: .swipeLeft, ignore: .swipeUp)

        /// The excursion currently bound to `action`.
        public func excursion(for action: CanvasAction) -> CanvasExcursion {
            switch action {
            case .commit:  return commit
            case .dismiss: return dismiss
            case .ignore:  return ignore
            }
        }

        /// Return a renormalized binding that maps `action → excursion`, keeping a strict one-to-one
        /// mapping by **swapping** with whichever action currently holds `excursion`. Pure; `self` is
        /// unchanged. If `action` already holds `excursion`, the binding is returned unchanged.
        public func assigning(_ excursion: CanvasExcursion, to action: CanvasAction) -> Self {
            let previous = self.excursion(for: action)
            guard previous != excursion else { return self }
            var result = self
            for other in CanvasAction.allCases
            where other != action && result.excursion(for: other) == excursion {
                result.set(previous, for: other)   // the conflicting action inherits the old excursion
            }
            result.set(excursion, for: action)
            return result
        }

        private mutating func set(_ excursion: CanvasExcursion, for action: CanvasAction) {
            switch action {
            case .commit:  commit = excursion
            case .dismiss: dismiss = excursion
            case .ignore:  ignore = excursion
            }
        }
    }
}

// MARK: - Files-band drill

extension GestureBindings {
    /// What a Files-drill resolve excursion does. The drill's `{open, openWith, discard}` actions.
    public enum FilesAction: String, Codable, CaseIterable, Identifiable, Sendable {
        case open
        case openWith
        case discard
        public var id: String { rawValue }
    }

    /// The Files-drill resolution excursions. Deliberately excludes single-finger motion.
    public enum FilesExcursion: String, Codable, CaseIterable, Identifiable, Sendable {
        case lift
        case plusOneFingerLift
        case fourFingerHorizontal
        public var id: String { rawValue }
    }

    /// The Files action→excursion mapping. A strict one-to-one map over the three excursions.
    public struct FilesDrillBinding: Codable, Equatable, Sendable {
        public var open: FilesExcursion
        public var openWith: FilesExcursion
        public var discard: FilesExcursion

        public init(open: FilesExcursion, openWith: FilesExcursion, discard: FilesExcursion) {
            self.open = open
            self.openWith = openWith
            self.discard = discard
        }

        /// Today's behavior: lift = open, +1-finger lift = Open-With, four-finger horizontal = discard.
        public static let `default` = FilesDrillBinding(
            open: .lift, openWith: .plusOneFingerLift, discard: .fourFingerHorizontal
        )

        /// The excursion currently bound to `action`.
        public func excursion(for action: FilesAction) -> FilesExcursion {
            switch action {
            case .open:     return open
            case .openWith: return openWith
            case .discard:  return discard
            }
        }

        /// Return a renormalized binding that maps `action → excursion`, swapping with whichever action
        /// currently holds `excursion` so the result stays one-to-one. Pure; `self` is unchanged.
        public func assigning(_ excursion: FilesExcursion, to action: FilesAction) -> Self {
            let previous = self.excursion(for: action)
            guard previous != excursion else { return self }
            var result = self
            for other in FilesAction.allCases
            where other != action && result.excursion(for: other) == excursion {
                result.set(previous, for: other)
            }
            result.set(excursion, for: action)
            return result
        }

        private mutating func set(_ excursion: FilesExcursion, for action: FilesAction) {
            switch action {
            case .open:     open = excursion
            case .openWith: openWith = excursion
            case .discard:  discard = excursion
            }
        }
    }
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
