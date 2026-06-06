import Foundation
import Combine

/// Tunable parameters for the gesture, persisted in UserDefaults and applied live.
/// All distance values are in *normalized* trackpad units (0..1 across the surface),
/// since OpenMultitouchSupport reports normalized positions.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    /// Master enable for the switcher.
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Keys.enabled) } }

    /// Normalized horizontal centroid travel required to show the switcher.
    @Published var activationThreshold: Double { didSet { persist(activationThreshold, Keys.activationThreshold) } }

    /// |Δx| must exceed axisLockRatio * |Δy| to lock to horizontal (and vice-versa for vertical).
    @Published var axisLockRatio: Double { didSet { persist(axisLockRatio, Keys.axisLockRatio) } }

    /// Normalized centroid travel that advances the selection by one window ("one window per N").
    @Published var stepDistance: Double { didSet { persist(stepDistance, Keys.stepDistance) } }

    /// Wrap around at the ends of the list instead of clamping.
    @Published var wrapAtEnds: Bool { didSet { defaults.set(wrapAtEnds, forKey: Keys.wrapAtEnds) } }

    /// Invert slide direction (slide right → previous instead of next).
    @Published var reverseDirection: Bool { didSet { defaults.set(reverseDirection, forKey: Keys.reverseDirection) } }

    /// EMA smoothing factor (0..1) for centroid velocity. Higher = snappier, lower = smoother.
    @Published var velocitySmoothing: Double { didSet { persist(velocitySmoothing, Keys.velocitySmoothing) } }

    /// Require exactly three fingers (true) vs. three-or-more (false).
    @Published var requireExactlyThree: Bool { didSet { defaults.set(requireExactlyThree, forKey: Keys.requireExactlyThree) } }

    /// Normalized vertical centroid travel that switches one Space-row. Larger than stepDistance
    /// so horizontal scrubbing jitter doesn't flip rows.
    @Published var rowStepDistance: Double { didSet { persist(rowStepDistance, Keys.rowStepDistance) } }

    /// Invert vertical direction (slide up → previous Space-row instead of next).
    @Published var reverseVerticalDirection: Bool { didSet { defaults.set(reverseVerticalDirection, forKey: Keys.reverseVerticalDirection) } }

    /// Post-commit self-healing focus watchdog. Verifies that the raised window actually became
    /// key shortly after commit and, if not, runs a bounded recovery so the user never has to
    /// open Mission Control to escape a focus vacuum. Default ON; toggle off if it misbehaves.
    @Published var focusWatchdogEnabled: Bool { didSet { defaults.set(focusWatchdogEnabled, forKey: Keys.focusWatchdogEnabled) } }

    /// Opt-in to managing the macOS "Automatically rearrange Spaces based on most recent use"
    /// setting. When ON, the app disables it on launch and restores it on quit, so Mission Control
    /// (and therefore the switcher) keeps a fixed Space order. Default OFF — set only via consent.
    @Published var manageSpacesRearrange: Bool { didSet { defaults.set(manageSpacesRearrange, forKey: Keys.manageSpacesRearrange) } }

    /// Opt-in to Space-row switching. When ON, the app relocates the native three-finger vertical
    /// gesture (Mission Control / App Exposé) to four fingers — on launch, restored on quit — and
    /// the recognizer steps Space-rows on vertical motion. Binding both sides to this one flag is
    /// what prevents the conflict where row stepping is live while the OS still owns three-finger
    /// vertical. Default OFF — set only via consent (which moves Mission Control to four fingers).
    @Published var manageVerticalGesture: Bool { didSet { defaults.set(manageVerticalGesture, forKey: Keys.manageVerticalGesture) } }

    /// Shared singleton uses the standard user defaults.
    private convenience init() {
        self.init(defaults: .standard)
    }

    /// Test/seam initializer: inject an isolated `UserDefaults` (e.g. `UserDefaults(suiteName:)`)
    /// so tests get an instance independent of the real app preferences.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        activationThreshold = defaults.object(forKey: Keys.activationThreshold) as? Double ?? Defaults.activationThreshold
        axisLockRatio = defaults.object(forKey: Keys.axisLockRatio) as? Double ?? Defaults.axisLockRatio
        stepDistance = defaults.object(forKey: Keys.stepDistance) as? Double ?? Defaults.stepDistance
        wrapAtEnds = defaults.object(forKey: Keys.wrapAtEnds) as? Bool ?? Defaults.wrapAtEnds
        reverseDirection = defaults.object(forKey: Keys.reverseDirection) as? Bool ?? Defaults.reverseDirection
        velocitySmoothing = defaults.object(forKey: Keys.velocitySmoothing) as? Double ?? Defaults.velocitySmoothing
        requireExactlyThree = defaults.object(forKey: Keys.requireExactlyThree) as? Bool ?? Defaults.requireExactlyThree
        rowStepDistance = defaults.object(forKey: Keys.rowStepDistance) as? Double ?? Defaults.rowStepDistance
        reverseVerticalDirection = defaults.object(forKey: Keys.reverseVerticalDirection) as? Bool ?? Defaults.reverseVerticalDirection
        focusWatchdogEnabled = defaults.object(forKey: Keys.focusWatchdogEnabled) as? Bool ?? Defaults.focusWatchdogEnabled
        manageSpacesRearrange = defaults.object(forKey: Keys.manageSpacesRearrange) as? Bool ?? Defaults.manageSpacesRearrange
        manageVerticalGesture = defaults.object(forKey: Keys.manageVerticalGesture) as? Bool ?? Defaults.manageVerticalGesture
    }

    func resetToDefaults() {
        activationThreshold = Defaults.activationThreshold
        axisLockRatio = Defaults.axisLockRatio
        stepDistance = Defaults.stepDistance
        wrapAtEnds = Defaults.wrapAtEnds
        reverseDirection = Defaults.reverseDirection
        velocitySmoothing = Defaults.velocitySmoothing
        requireExactlyThree = Defaults.requireExactlyThree
        rowStepDistance = Defaults.rowStepDistance
        reverseVerticalDirection = Defaults.reverseVerticalDirection
        focusWatchdogEnabled = Defaults.focusWatchdogEnabled
    }

    private func persist(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }

    enum Defaults {
        static let activationThreshold = 0.045   // ~4.5% of trackpad width to trigger
        static let axisLockRatio = 1.4           // horizontal must clearly dominate vertical
        static let stepDistance = 0.05           // one window per ~5% of trackpad width
        static let wrapAtEnds = false
        static let reverseDirection = false
        static let velocitySmoothing = 0.35
        static let requireExactlyThree = true
        static let rowStepDistance = 0.12       // ~2.4× the horizontal step; deliberate up/down
        static let reverseVerticalDirection = false
        static let focusWatchdogEnabled = true
        static let manageSpacesRearrange = false   // opt-in; only enabled via explicit consent
        static let manageVerticalGesture = false   // opt-in; relocates Mission Control to four fingers
    }

    private enum Keys {
        static let enabled = "enabled"
        static let activationThreshold = "activationThreshold"
        static let axisLockRatio = "axisLockRatio"
        static let stepDistance = "stepDistance"
        static let wrapAtEnds = "wrapAtEnds"
        static let reverseDirection = "reverseDirection"
        static let velocitySmoothing = "velocitySmoothing"
        static let requireExactlyThree = "requireExactlyThree"
        static let rowStepDistance = "rowStepDistance"
        static let reverseVerticalDirection = "reverseVerticalDirection"
        static let focusWatchdogEnabled = "focusWatchdogEnabled"
        static let manageSpacesRearrange = "manageSpacesRearrange"
        static let manageVerticalGesture = "manageVerticalGesture"
    }
}
