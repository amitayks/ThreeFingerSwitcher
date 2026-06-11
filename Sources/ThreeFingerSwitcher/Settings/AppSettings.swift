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

    /// Normalized travel that advances the launcher selection by one item — horizontal between items
    /// in a band, and vertical between grid rows and the band-headers row. (Band switching uses the
    /// separate `launcherContextStepDistance`.)
    @Published var launcherStepDistance: Double { didSet { persist(launcherStepDistance, Keys.launcherStepDistance) } }

    /// Normalized horizontal travel on the band-headers row that switches one band. Independent of the
    /// item step so band switching can be made deliberate without slowing item movement; defaults
    /// larger than the item step.
    @Published var launcherContextStepDistance: Double { didSet { persist(launcherContextStepDistance, Keys.launcherContextStepDistance) } }

    /// Seconds the selection must rest on an item before it arms (then a lift fires it). Brief but
    /// deliberate — a quick scrub-and-lift never fires.
    @Published var dwellToArmDuration: Double { didSet { persist(dwellToArmDuration, Keys.dwellToArmDuration) } }

    /// Show the diagnostic tools ("Write Diagnostics", "Copy Focus Log") in the status menu. Off by
    /// default — these are troubleshooting affordances most users never need, so they're hidden
    /// behind this toggle to keep the menu tidy.
    @Published var showDiagnostics: Bool { didSet { defaults.set(showDiagnostics, forKey: Keys.showDiagnostics) } }

    // MARK: - Clipboard history (opt-in; default OFF)

    /// Opt-in to recording clipboard history and showing the launcher's Clipboard band. Unlike the
    /// gesture opt-ins this relocates no native gesture, needs no re-login, and requests no new
    /// permission — it only enables local recording + the synthetic band. Default OFF (privacy).
    @Published var keepClipboardHistory: Bool { didSet { defaults.set(keepClipboardHistory, forKey: Keys.keepClipboardHistory) } }

    /// Temporarily stop recording without disabling the feature (the band still shows what's stored).
    @Published var clipboardPaused: Bool { didSet { defaults.set(clipboardPaused, forKey: Keys.clipboardPaused) } }

    /// How many most-recent entries the Clipboard band shows (pinned entries float to the top).
    @Published var clipboardRecentWindow: Int { didSet { defaults.set(clipboardRecentWindow, forKey: Keys.clipboardRecentWindow) } }

    /// Retention cap: maximum stored entries (pinned exempt).
    @Published var clipboardMaxCount: Int { didSet { defaults.set(clipboardMaxCount, forKey: Keys.clipboardMaxCount) } }

    /// Retention cap: maximum total bytes of stored payloads (pinned exempt).
    @Published var clipboardMaxBytes: Int { didSet { defaults.set(clipboardMaxBytes, forKey: Keys.clipboardMaxBytes) } }

    /// Retention cap: maximum age in days for non-pinned entries; 0 disables the age cap.
    @Published var clipboardMaxAgeDays: Double { didSet { persist(clipboardMaxAgeDays, Keys.clipboardMaxAgeDays) } }

    /// Seconds between change-counter polls.
    @Published var clipboardPollInterval: Double { didSet { persist(clipboardPollInterval, Keys.clipboardPollInterval) } }

    /// Edge-scroll acceleration sensitivity for long lists (≥1; higher accelerates faster at the edge).
    @Published var clipboardEdgeAcceleration: Double { didSet { persist(clipboardEdgeAcceleration, Keys.clipboardEdgeAcceleration) } }

    /// Normalized horizontal travel required for a deliberate clipboard pin / previous-band flick.
    /// Larger than the item step so pinning isn't twitchy; one flick = one action.
    @Published var clipboardPinDistance: Double { didSet { persist(clipboardPinDistance, Keys.clipboardPinDistance) } }

    /// Bundle ids whose copies are never recorded (e.g. password managers the user wants excluded).
    @Published var clipboardExcludedApps: [String] { didSet { defaults.set(clipboardExcludedApps, forKey: Keys.clipboardExcludedApps) } }

    // MARK: - AI commands (opt-in; default OFF)

    /// Opt-in to the AI command band and the on-device model. Unlike the Space-row / launcher opt-ins
    /// this relocates NO native gesture and needs NO re-login; unlike the clipboard opt-in, turning it
    /// ON does allow the (later) multi-gigabyte model download + residency, and the first calendar task
    /// will request the Calendar permission lazily. Default OFF — set only via explicit consent.
    /// Older settings that predate this feature have no key and decode with the opt-in OFF, leaving the
    /// band absent, nothing downloaded, and no commands surfaced.
    @Published var aiCommandsEnabled: Bool { didSet { defaults.set(aiCommandsEnabled, forKey: Keys.aiCommandsEnabled) } }

    /// The pinned on-device model id the model-management surface selects, or nil for "registry
    /// default". Stored so a deliberate model choice survives across launches; nil encodes as absent,
    /// so older settings (and a never-chosen default) read back identically.
    @Published var aiSelectedModelID: String? { didSet { defaults.set(aiSelectedModelID, forKey: Keys.aiSelectedModelID) } }

    /// Per-command remembered runtime-parameter language (spec: "Per-command runtime-parameter
    /// persistence"), keyed by the command's identifier string → the last chosen language. Out-of-band
    /// from the command itself, so seeds/catalog/band edits are unaffected; orphan keys (deleted
    /// commands) are harmless and pruned opportunistically. Stored as a `[String: String]` dictionary.
    @Published var aiCommandLanguages: [String: String] { didSet { defaults.set(aiCommandLanguages, forKey: Keys.aiCommandLanguages) } }

    /// Let the on-device model reason before answering (thinking is filtered from the result). Default
    /// ON; gated behind the AI opt-in like the other AI prefs.
    @Published var aiReasoningEnabled: Bool { didSet { defaults.set(aiReasoningEnabled, forKey: Keys.aiReasoningEnabled) } }

    /// The language last chosen for `commandID`, or nil if none has been chosen yet (cold start).
    func rememberedLanguage(for commandID: UUID) -> String? { aiCommandLanguages[commandID.uuidString] }

    /// Remember `language` as the next-run default for `commandID` (written when the user repicks).
    func rememberLanguage(_ language: String, for commandID: UUID) {
        aiCommandLanguages[commandID.uuidString] = language
    }

    /// Best-effort orphan cleanup: drop persisted language entries whose command id is not in
    /// `liveIDs`. A no-op when nothing is orphaned (so it doesn't churn UserDefaults needlessly).
    func pruneCommandLanguages(keeping liveIDs: Set<UUID>) {
        let live = Set(liveIDs.map(\.uuidString))
        let kept = aiCommandLanguages.filter { live.contains($0.key) }
        if kept.count != aiCommandLanguages.count { aiCommandLanguages = kept }
    }

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
        keepClipboardHistory = defaults.object(forKey: Keys.keepClipboardHistory) as? Bool ?? Defaults.keepClipboardHistory
        clipboardPaused = defaults.object(forKey: Keys.clipboardPaused) as? Bool ?? Defaults.clipboardPaused
        clipboardRecentWindow = defaults.object(forKey: Keys.clipboardRecentWindow) as? Int ?? Defaults.clipboardRecentWindow
        clipboardMaxCount = defaults.object(forKey: Keys.clipboardMaxCount) as? Int ?? Defaults.clipboardMaxCount
        clipboardMaxBytes = defaults.object(forKey: Keys.clipboardMaxBytes) as? Int ?? Defaults.clipboardMaxBytes
        clipboardMaxAgeDays = defaults.object(forKey: Keys.clipboardMaxAgeDays) as? Double ?? Defaults.clipboardMaxAgeDays
        clipboardPollInterval = defaults.object(forKey: Keys.clipboardPollInterval) as? Double ?? Defaults.clipboardPollInterval
        clipboardEdgeAcceleration = defaults.object(forKey: Keys.clipboardEdgeAcceleration) as? Double ?? Defaults.clipboardEdgeAcceleration
        clipboardPinDistance = defaults.object(forKey: Keys.clipboardPinDistance) as? Double ?? Defaults.clipboardPinDistance
        clipboardExcludedApps = defaults.object(forKey: Keys.clipboardExcludedApps) as? [String] ?? Defaults.clipboardExcludedApps
        aiCommandsEnabled = defaults.object(forKey: Keys.aiCommandsEnabled) as? Bool ?? Defaults.aiCommandsEnabled
        aiSelectedModelID = defaults.object(forKey: Keys.aiSelectedModelID) as? String ?? Defaults.aiSelectedModelID
        aiCommandLanguages = defaults.object(forKey: Keys.aiCommandLanguages) as? [String: String] ?? Defaults.aiCommandLanguages
        aiReasoningEnabled = defaults.object(forKey: Keys.aiReasoningEnabled) as? Bool ?? Defaults.aiReasoningEnabled
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
        // Clipboard tunables reset; `keepClipboardHistory`, the exclusion list, and the stored history
        // itself are a privacy choice and are intentionally NOT reset (mirrors the opt-in handling).
        clipboardRecentWindow = Defaults.clipboardRecentWindow
        clipboardMaxCount = Defaults.clipboardMaxCount
        clipboardMaxBytes = Defaults.clipboardMaxBytes
        clipboardMaxAgeDays = Defaults.clipboardMaxAgeDays
        clipboardPollInterval = Defaults.clipboardPollInterval
        clipboardEdgeAcceleration = Defaults.clipboardEdgeAcceleration
        clipboardPinDistance = Defaults.clipboardPinDistance
        // `aiCommandsEnabled` (a consent-gated opt-in that allows a multi-gigabyte download) and the
        // selected-model pin are a deliberate user choice, so they're intentionally NOT reset — mirrors
        // the launcher / clipboard opt-in handling.
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
        static let launcherContextStepDistance = 0.12   // ~1.7× the item step; deliberate horizontal band switching
        static let dwellToArmDuration = 0.5        // brief but deliberate; not a full second
        static let showDiagnostics = false         // troubleshooting tools hidden from the menu by default
        static let keepClipboardHistory = false    // opt-in; records copied content locally (privacy)
        static let clipboardPaused = false
        static let clipboardRecentWindow = 30      // entries shown in the band (pinned float to top)
        static let clipboardMaxCount = 200         // stored-entry cap (pinned exempt)
        static let clipboardMaxBytes = 256 * 1024 * 1024   // 256 MB of payloads (pinned exempt)
        static let clipboardMaxAgeDays = 0.0       // 0 = no age cap
        static let clipboardPollInterval = 0.5     // change-counter poll cadence (seconds)
        static let clipboardEdgeAcceleration = 1.0 // edge-scroll acceleration sensitivity
        static let clipboardPinDistance = 0.22     // deliberate horizontal flick to pin / leave (≈3 item steps)
        static let clipboardExcludedApps: [String] = []
        static let aiCommandsEnabled = false       // opt-in; gates the AI band + model download/residency
        static let aiSelectedModelID: String? = nil  // nil = registry default model
        static let aiCommandLanguages: [String: String] = [:]  // per-command remembered runtime language
        static let aiReasoningEnabled = true       // let the model think (filtered out of the result); gated by the AI opt-in
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
        static let keepClipboardHistory = "keepClipboardHistory"
        static let clipboardPaused = "clipboardPaused"
        static let clipboardRecentWindow = "clipboardRecentWindow"
        static let clipboardMaxCount = "clipboardMaxCount"
        static let clipboardMaxBytes = "clipboardMaxBytes"
        static let clipboardMaxAgeDays = "clipboardMaxAgeDays"
        static let clipboardPollInterval = "clipboardPollInterval"
        static let clipboardEdgeAcceleration = "clipboardEdgeAcceleration"
        static let clipboardPinDistance = "clipboardPinDistance"
        static let clipboardExcludedApps = "clipboardExcludedApps"
        static let aiCommandsEnabled = "aiCommandsEnabled"
        static let aiSelectedModelID = "aiSelectedModelID"
        static let aiCommandLanguages = "aiCommandLanguages"
        static let aiReasoningEnabled = "aiReasoningEnabled"
    }
}
