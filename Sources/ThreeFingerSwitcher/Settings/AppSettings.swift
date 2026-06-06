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

    /// Opt-in to the four-finger launcher. When ON, the recognizer emits four-finger launcher
    /// intents AND the native four-finger horizontal/vertical swipe gestures are freed (one-time
    /// re-login). Binding both sides to this one flag mirrors `manageVerticalGesture`: row stepping
    /// must never be live while the OS still owns the gesture. Default OFF — set only via consent.
    @Published var enableLauncher: Bool { didSet { defaults.set(enableLauncher, forKey: Keys.enableLauncher) } }

    /// Normalized horizontal centroid travel required to show the launcher (four-finger).
    @Published var launcherActivationThreshold: Double { didSet { persist(launcherActivationThreshold, Keys.launcherActivationThreshold) } }

    /// Normalized horizontal travel that advances the launcher selection by one item.
    @Published var launcherStepDistance: Double { didSet { persist(launcherStepDistance, Keys.launcherStepDistance) } }

    /// Normalized vertical travel that switches one context band in the launcher. Larger than the
    /// item step so horizontal scrubbing jitter doesn't flip bands.
    @Published var launcherContextStepDistance: Double { didSet { persist(launcherContextStepDistance, Keys.launcherContextStepDistance) } }

    /// Seconds the selection must rest on an item before it arms (then a lift fires it). Brief but
    /// deliberate — a quick scrub-and-lift never fires.
    @Published var dwellToArmDuration: Double { didSet { persist(dwellToArmDuration, Keys.dwellToArmDuration) } }

    /// Show the diagnostic tools ("Write Diagnostics", "Copy Focus Log") in the status menu. Off by
    /// default — these are troubleshooting affordances most users never need, so they're hidden
    /// behind this toggle to keep the menu tidy.
    @Published var showDiagnostics: Bool { didSet { defaults.set(showDiagnostics, forKey: Keys.showDiagnostics) } }

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
        enableLauncher = defaults.object(forKey: Keys.enableLauncher) as? Bool ?? Defaults.enableLauncher
        launcherActivationThreshold = defaults.object(forKey: Keys.launcherActivationThreshold) as? Double ?? Defaults.launcherActivationThreshold
        launcherStepDistance = defaults.object(forKey: Keys.launcherStepDistance) as? Double ?? Defaults.launcherStepDistance
        launcherContextStepDistance = defaults.object(forKey: Keys.launcherContextStepDistance) as? Double ?? Defaults.launcherContextStepDistance
        dwellToArmDuration = defaults.object(forKey: Keys.dwellToArmDuration) as? Double ?? Defaults.dwellToArmDuration
        showDiagnostics = defaults.object(forKey: Keys.showDiagnostics) as? Bool ?? Defaults.showDiagnostics
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
        // Launcher tunables reset too; `enableLauncher` is a consent-gated opt-in (system side
        // effect) and is intentionally NOT reset, mirroring `manageVerticalGesture`.
        launcherActivationThreshold = Defaults.launcherActivationThreshold
        launcherStepDistance = Defaults.launcherStepDistance
        launcherContextStepDistance = Defaults.launcherContextStepDistance
        dwellToArmDuration = Defaults.dwellToArmDuration
        showDiagnostics = Defaults.showDiagnostics
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
        static let enableLauncher = false          // opt-in; frees four-finger native gestures
        static let launcherActivationThreshold = 0.045  // same deliberate trigger as the horizontal switcher
        static let launcherStepDistance = 0.07     // one item per ~7%; items are larger, fewer targets
        static let launcherContextStepDistance = 0.12   // ~1.7× the item step; deliberate up/down between bands
        static let dwellToArmDuration = 0.5        // brief but deliberate; not a full second
        static let showDiagnostics = false         // troubleshooting tools hidden from the menu by default
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
        static let enableLauncher = "enableLauncher"
        static let launcherActivationThreshold = "launcherActivationThreshold"
        static let launcherStepDistance = "launcherStepDistance"
        static let launcherContextStepDistance = "launcherContextStepDistance"
        static let dwellToArmDuration = "dwellToArmDuration"
        static let showDiagnostics = "showDiagnostics"
    }
}
