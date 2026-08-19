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

    /// The user's gesture bindings (the switcher per-axis scrub directions). Persisted as a single
    /// JSON blob (`Data` is plist-native, mirroring `FavoritesStore`). Defaults to exactly today's
    /// behavior. The switcher axes are the single source of truth for the former `reverseDirection` /
    /// `reverseVerticalDirection` booleans, which are now computed accessors onto this binding (no
    /// duplicate persisted keys).
    @Published var gestureBindings: GestureBindings { didSet { persist(gestureBindings, Keys.gestureBindings) } }

    /// Invert slide direction (slide right → previous instead of next). A computed view onto the
    /// switcher's **windows** axis binding (`gesture-bindings`, the single source of truth) — existing
    /// consumers keep reading/writing this boolean unchanged while persistence lives in `gestureBindings`.
    var reverseDirection: Bool {
        get { gestureBindings.switcher.windowsAxis.isReversed }
        set { gestureBindings.switcher.windowsAxis = .init(reversed: newValue) }
    }

    /// EMA smoothing factor (0..1) for centroid velocity. Higher = snappier, lower = smoother.
    @Published var velocitySmoothing: Double { didSet { persist(velocitySmoothing, Keys.velocitySmoothing) } }

    /// Relative size of the windows in the switcher grid: a multiplier on the uniform-scale cap
    /// (`SwitcherLayout.kMax`). 1.0 = default; larger renders the cards bigger, smaller more compact.
    @Published var switcherWindowScale: Double { didSet { persist(switcherWindowScale, Keys.switcherWindowScale) } }

    /// Require exactly three fingers (true) vs. three-or-more (false).
    @Published var requireExactlyThree: Bool { didSet { defaults.set(requireExactlyThree, forKey: Keys.requireExactlyThree) } }

    /// Relax the switcher's window gate to include windows that don't report the standard
    /// `AXStandardWindow` subrole. The strict default lists only standard document windows (plus
    /// windows that expose no subrole at all), which drops real windows from foreign UI toolkits and
    /// setup/welcome surfaces — e.g. the Android emulator (a Qt window whose subrole isn't standard)
    /// and Xcode's start/welcome window (a panel/dialog subrole). When ON, any window-role element on
    /// the normal window layer is switchable regardless of subrole; the layer-0 gate still filters true
    /// floating HUD/utility panels, and minimized windows stay excluded. A pure behavior tunable — no
    /// system side effect, no new permission — so it live-applies on the next gesture. Default OFF
    /// (preserve today's strict behavior); older settings have no key and decode with it OFF.
    @Published var includeNonStandardWindows: Bool { didSet { defaults.set(includeNonStandardWindows, forKey: Keys.includeNonStandardWindows) } }

    /// Per-app window-listing rules (`WindowAppRule`) keyed by bundle ID (falling back to executable
    /// name for apps that have none — e.g. the Android emulator): `include` lists every window-role
    /// element of the app, `strict` applies the standard-subrole gate regardless of the global relaxed
    /// toggle, `exclude` lists nothing from the app; an absent key follows the global policy. Edited
    /// from the Hub's Window Inspector. A pure behavior tunable — live-applies on the next gesture.
    @Published var windowAppRules: [String: WindowAppRule] { didSet { persistCodable(windowAppRules, Keys.windowAppRules) } }

    /// Normalized vertical centroid travel that switches one Space-row. Larger than stepDistance
    /// so horizontal scrubbing jitter doesn't flip rows.
    @Published var rowStepDistance: Double { didSet { persist(rowStepDistance, Keys.rowStepDistance) } }

    /// Invert vertical direction (slide up → previous Space-row instead of next). A computed view onto
    /// the switcher's **Spaces** axis binding (`gesture-bindings`, the single source of truth) — existing
    /// consumers keep reading/writing this boolean unchanged while persistence lives in `gestureBindings`.
    var reverseVerticalDirection: Bool {
        get { gestureBindings.switcher.spacesAxis.isReversed }
        set { gestureBindings.switcher.spacesAxis = .init(reversed: newValue) }
    }

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

    /// Normalized centroid travel to move the selection by one item — horizontally between items and
    /// vertically between grid rows (odometer, with carry).
    @Published var launcherStepDistance: Double { didSet { persist(launcherStepDistance, Keys.launcherStepDistance) } }

    /// Normalized vertical travel on the band list to switch one band (odometer, with carry). Coarser
    /// than the item step so band switching stays deliberate without slowing item movement.
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

    /// Opt-in to the device link (iPhone↔Mac clipboard/file bridge). Like the clipboard opt-in it
    /// relocates no native gesture, needs no re-login, and has no `is…Effective` gate — it just starts/
    /// stops the receive/send service. Default OFF (privacy; it opens a local-network listener). Adds the
    /// macOS Local Network prompt the first time the service advertises/connects.
    @Published var enableDeviceLink: Bool { didSet { defaults.set(enableDeviceLink, forKey: Keys.enableDeviceLink) } }

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

    // MARK: - Per-app keyboard language (opt-in; default OFF)

    /// Opt-in to remembering and re-selecting the keyboard input source per application (bundle id),
    /// auto-learned from the user's own changes. Unlike the gesture opt-ins this relocates NO native
    /// gesture and needs NO re-login. While OFF the service registers no observers and performs no TIS
    /// reads or writes (lifecycle-gated). Default OFF — set only via explicit consent.
    /// Older settings that predate this feature have no key and decode with the opt-in OFF.
    @Published var keyboardLanguageEnabled: Bool { didSet { defaults.set(keyboardLanguageEnabled, forKey: Keys.keyboardLanguageEnabled) } }

    /// The user-chosen global default input-source id applied to apps with no remembered source, or ""
    /// for "no global default" (pure learn-as-you-go — nothing is applied to unseen apps). Stored as an
    /// `kTISPropertyInputSourceID` string; empty encodes the unset state, so older settings (and a
    /// never-chosen default) read back identically.
    @Published var keyboardLanguageDefaultSourceID: String { didSet { defaults.set(keyboardLanguageDefaultSourceID, forKey: Keys.keyboardLanguageDefaultSourceID) } }

    /// Opt-in sub-toggle of the per-app feature: also remember/apply the input source per active-tab
    /// *host* inside supported browsers (so `keep.google.com` and `mail.google.com` keep separate
    /// languages in the same Chrome process), reusing the same string-keyed store with richer keys.
    /// Relocates NO native gesture and needs NO re-login. While OFF the browser-context monitor never
    /// runs and browsers behave exactly per-app. Requires `keyboardLanguageEnabled` to be ON to have
    /// any effect. Default OFF — set only via explicit consent. Older settings have no key and decode
    /// with the sub-toggle OFF.
    @Published var keyboardLanguagePerSiteEnabled: Bool { didSet { defaults.set(keyboardLanguagePerSiteEnabled, forKey: Keys.keyboardLanguagePerSiteEnabled) } }

    /// Opt-in to the Apple Events host reader for exact per-host precision everywhere (including Safari,
    /// whose address bar hides the subdomain from the default Accessibility reader). When OFF the
    /// feature uses the Accessibility reader only (no new permission); when ON the first read triggers
    /// the per-browser Automation permission prompt, and a denied/undetermined grant degrades silently
    /// back to Accessibility. Default OFF — set only via explicit consent. Older settings decode OFF.
    @Published var keyboardLanguageAllowBrowserControl: Bool { didSet { defaults.set(keyboardLanguageAllowBrowserControl, forKey: Keys.keyboardLanguageAllowBrowserControl) } }

    // MARK: - Dock window previews (opt-in; default OFF)

    /// Opt-in to the Dock-hover window previews — the switcher "from another angle": hover an app's Dock
    /// tile to fan out its current-Space windows (including minimized), peek any one live, and click to
    /// raise it. Like the clipboard opt-in (and unlike the gesture opt-ins) this relocates NO
    /// native gesture, needs NO re-login, and requests NO new permission — it reuses the already-granted
    /// Accessibility (read the Dock's AX tree + raise) and Screen Recording (thumbnails) grants. There is
    /// NO `is…Effective` gate: flipping it ON installs the cursor monitor + Dock reader, OFF tears them
    /// down. Default OFF. Older settings have no key and decode with the opt-in OFF.
    @Published var showDockPreviews: Bool { didSet { defaults.set(showDockPreviews, forKey: Keys.showDockPreviews) } }

    /// Opt-in to snap-to-bind window groups: a window drag ending edge-flush against another window
    /// binds the two into a group that the switcher renders as a fused cluster and raises together
    /// (selected member focused). Like `showDockPreviews` this relocates NO native gesture, needs NO
    /// re-login, and requests NO new permission (passive left-mouse monitors + the existing window
    /// enumeration). Flipping it ON installs the snap monitor, OFF tears it down AND clears the
    /// runtime groups. Default OFF; older settings have no key and decode with the opt-in OFF.
    @Published var enableWindowGroups: Bool { didSet { defaults.set(enableWindowGroups, forKey: Keys.enableWindowGroups) } }

    /// Opt-in: drive the window switcher from ⌘-Tab (intercept it, suppress the native application
    /// switcher). Like `showDockPreviews` it needs NO re-login and requests NO new permission — it
    /// reuses the already-granted Accessibility (active consuming event tap + raise) and the tracked
    /// Input Monitoring. Because interception is a live event tap, flipping it ON installs the keyboard
    /// tap and OFF removes it (native ⌘-Tab restored immediately). Default OFF; older settings decode OFF.
    @Published var commandTabSwitcher: Bool { didSet { defaults.set(commandTabSwitcher, forKey: Keys.commandTabSwitcher) } }

    /// Opt-in: include minimized windows in the switcher and ⌘-Tab (flagged + badged), with selection
    /// un-minimizing the window in place. Independent of `includeNonStandardWindows`. Like the dock/⌘-Tab
    /// opt-ins it relocates NO native gesture, needs NO re-login, and requests NO new permission (it reuses
    /// the already-granted Accessibility read/raise). A pure behavior tunable — it resets to OFF. Default OFF.
    /// Locked ON while `swipeDownMinimizesAll` is on (else that gesture strands the windows it minimizes).
    @Published var includeMinimizedWindows: Bool {
        didSet {
            // Coupling guard (model level): minimize-all-on-down is unusable without reachability, so it
            // cannot be turned off while that opt-in is on. The re-entrant set-true terminates (the guard
            // condition is then false) and persists ON.
            if !includeMinimizedWindows && swipeDownMinimizesAll {
                includeMinimizedWindows = true
                return
            }
            defaults.set(includeMinimizedWindows, forKey: Keys.includeMinimizedWindows)
        }
    }

    /// Opt-in: a fresh three-finger DOWN swipe minimizes every current-Space window (revealing the desktop,
    /// Windows Win+D style) instead of synthesizing App Exposé. Only *effective* while the Space-row vertical
    /// opt-in (`manageVerticalGesture`) is effective — otherwise the OS owns three-finger vertical and the app
    /// never sees the down-swipe. Enabling it auto-enables `includeMinimizedWindows` so the minimized windows
    /// are never stranded. No relocation, no re-login, no new permission of its own. Resets to OFF. Default OFF.
    @Published var swipeDownMinimizesAll: Bool {
        didSet {
            defaults.set(swipeDownMinimizesAll, forKey: Keys.swipeDownMinimizesAll)
            // Reachability is what makes the minimized windows recoverable; enabling the trigger turns it on.
            if swipeDownMinimizesAll && !includeMinimizedWindows {
                includeMinimizedWindows = true
            }
        }
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
        // Gesture bindings: decode the JSON blob, else default to today's behavior. The former
        // `reverseDirection` / `reverseVerticalDirection` booleans (if a prior install wrote them) are
        // folded into the switcher axes so an upgrade preserves the user's reverse choices. Built in a
        // local first (read-modify-write can't touch the stored property mid-init) and assigned once.
        var bindings = AppSettings.loadGestureBindings(defaults, Keys.gestureBindings)
        if defaults.data(forKey: Keys.gestureBindings) == nil {
            if let legacyH = defaults.object(forKey: Keys.reverseDirection) as? Bool {
                bindings.switcher.windowsAxis = .init(reversed: legacyH)
            }
            if let legacyV = defaults.object(forKey: Keys.reverseVerticalDirection) as? Bool {
                bindings.switcher.spacesAxis = .init(reversed: legacyV)
            }
        }
        gestureBindings = bindings
        velocitySmoothing = defaults.object(forKey: Keys.velocitySmoothing) as? Double ?? Defaults.velocitySmoothing
        switcherWindowScale = defaults.object(forKey: Keys.switcherWindowScale) as? Double ?? Defaults.switcherWindowScale
        requireExactlyThree = defaults.object(forKey: Keys.requireExactlyThree) as? Bool ?? Defaults.requireExactlyThree
        includeNonStandardWindows = defaults.object(forKey: Keys.includeNonStandardWindows) as? Bool ?? Defaults.includeNonStandardWindows
        windowAppRules = AppSettings.loadCodable([String: WindowAppRule].self, defaults, Keys.windowAppRules) ?? Defaults.windowAppRules
        rowStepDistance = defaults.object(forKey: Keys.rowStepDistance) as? Double ?? Defaults.rowStepDistance
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
        enableDeviceLink = defaults.object(forKey: Keys.enableDeviceLink) as? Bool ?? Defaults.enableDeviceLink
        clipboardPaused = defaults.object(forKey: Keys.clipboardPaused) as? Bool ?? Defaults.clipboardPaused
        clipboardRecentWindow = defaults.object(forKey: Keys.clipboardRecentWindow) as? Int ?? Defaults.clipboardRecentWindow
        clipboardMaxCount = defaults.object(forKey: Keys.clipboardMaxCount) as? Int ?? Defaults.clipboardMaxCount
        clipboardMaxBytes = defaults.object(forKey: Keys.clipboardMaxBytes) as? Int ?? Defaults.clipboardMaxBytes
        clipboardMaxAgeDays = defaults.object(forKey: Keys.clipboardMaxAgeDays) as? Double ?? Defaults.clipboardMaxAgeDays
        clipboardPollInterval = defaults.object(forKey: Keys.clipboardPollInterval) as? Double ?? Defaults.clipboardPollInterval
        clipboardEdgeAcceleration = defaults.object(forKey: Keys.clipboardEdgeAcceleration) as? Double ?? Defaults.clipboardEdgeAcceleration
        clipboardPinDistance = defaults.object(forKey: Keys.clipboardPinDistance) as? Double ?? Defaults.clipboardPinDistance
        clipboardExcludedApps = defaults.object(forKey: Keys.clipboardExcludedApps) as? [String] ?? Defaults.clipboardExcludedApps
        keyboardLanguageEnabled = defaults.object(forKey: Keys.keyboardLanguageEnabled) as? Bool ?? Defaults.keyboardLanguageEnabled
        keyboardLanguageDefaultSourceID = defaults.object(forKey: Keys.keyboardLanguageDefaultSourceID) as? String ?? Defaults.keyboardLanguageDefaultSourceID
        keyboardLanguagePerSiteEnabled = defaults.object(forKey: Keys.keyboardLanguagePerSiteEnabled) as? Bool ?? Defaults.keyboardLanguagePerSiteEnabled
        keyboardLanguageAllowBrowserControl = defaults.object(forKey: Keys.keyboardLanguageAllowBrowserControl) as? Bool ?? Defaults.keyboardLanguageAllowBrowserControl
        showDockPreviews = defaults.object(forKey: Keys.showDockPreviews) as? Bool ?? Defaults.showDockPreviews
        enableWindowGroups = defaults.object(forKey: Keys.enableWindowGroups) as? Bool ?? Defaults.enableWindowGroups
        commandTabSwitcher = defaults.object(forKey: Keys.commandTabSwitcher) as? Bool ?? Defaults.commandTabSwitcher
        includeMinimizedWindows = defaults.object(forKey: Keys.includeMinimizedWindows) as? Bool ?? Defaults.includeMinimizedWindows
        swipeDownMinimizesAll = defaults.object(forKey: Keys.swipeDownMinimizesAll) as? Bool ?? Defaults.swipeDownMinimizesAll
    }

    func resetToDefaults() {
        activationThreshold = Defaults.activationThreshold
        axisLockRatio = Defaults.axisLockRatio
        stepDistance = Defaults.stepDistance
        wrapAtEnds = Defaults.wrapAtEnds
        velocitySmoothing = Defaults.velocitySmoothing
        switcherWindowScale = Defaults.switcherWindowScale
        requireExactlyThree = Defaults.requireExactlyThree
        // A pure behavior tunable (no system side effect / permission / download), so — like `wrapAtEnds`
        // and `requireExactlyThree` — it resets back to its strict default.
        includeNonStandardWindows = Defaults.includeNonStandardWindows
        windowAppRules = Defaults.windowAppRules
        // Pure behavior tunables (no relocation / permission / download), so both reset to OFF. Order
        // matters: clear the minimize-all trigger FIRST so the coupling guard does not re-enable reachability.
        swipeDownMinimizesAll = Defaults.swipeDownMinimizesAll
        includeMinimizedWindows = Defaults.includeMinimizedWindows
        rowStepDistance = Defaults.rowStepDistance
        // Resolution-gesture bindings (incl. the folded reverse-direction switcher axes) reset to today's
        // behavior — a single source of truth for the former `reverseDirection` / `reverseVerticalDirection`.
        gestureBindings = Defaults.gestureBindings
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
        // `keyboardLanguageEnabled` and the global-default source id are an opt-in user choice
        // (the learned per-app map is a separate store), so they're intentionally NOT reset.
        // The per-site sub-toggle and the Apple Events ("Allow browser control") opt-in are the same:
        // consent-gated user choices (the latter governs a per-browser permission), NOT reset here.
        // `showDockPreviews` is likewise an opt-in user choice (no tunables of its own), NOT reset here.
    }

    private func persist(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }

    /// Persist any `Encodable` value as a JSON blob (the `gestureBindings` pattern, generalized for the
    /// Files action-menu config). Encode failure is a no-op (the in-memory value still applies live).
    private func persistCodable<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// Decode a persisted JSON blob, or nil on a missing/corrupt value (the caller supplies the default).
    private static func loadCodable<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Persist the gesture bindings as a JSON blob (`Data` is plist-native, mirroring `FavoritesStore`).
    /// An encode failure is a no-op (the in-memory value still applies live), matching the store's
    /// best-effort persistence.
    private func persist(_ value: GestureBindings, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    /// Decode the persisted gesture bindings, falling back to the defaults on a missing/corrupt blob
    /// (so older settings — which have no key — read back exactly today's behavior).
    private static func loadGestureBindings(_ defaults: UserDefaults, _ key: String) -> GestureBindings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(GestureBindings.self, from: data)
        else { return Defaults.gestureBindings }
        return decoded
    }

    // The gesture-feel numbers below are tuned from extended real daily use (the maintainer's
    // dialed-in values, adopted as the shipped defaults): a feather-light trigger, fine steps,
    // and a quick dwell — the feel the product is meant to have out of the box.
    enum Defaults {
        static let activationThreshold = 0.01    // feather-light trigger (~1% of trackpad width)
        static let axisLockRatio = 1.13          // slight horizontal dominance before scrubbing (in-hand tuned)
        static let stepDistance = 0.027          // one window per ~2.7% of trackpad width (in-hand tuned)
        static let wrapAtEnds = false
        /// The resolution-gesture bindings default to exactly today's behavior (see `GestureBindings`).
        static let gestureBindings = GestureBindings.default
        /// Retained as the documented switcher-axis default (the `reverseDirection` boolean view of the
        /// `gestureBindings.switcher.windowsAxis`). Kept so existing tests/Hub reads stay valid.
        static let reverseDirection = false
        static let velocitySmoothing = 0.35
        static let switcherWindowScale = 0.60    // 0.60× of SwitcherLayout.kMax
        static let requireExactlyThree = true
        static let includeNonStandardWindows = false   // strict: only AXStandardWindow (opt-in to widen)
        static let windowAppRules: [String: WindowAppRule] = [:]   // no per-app overrides — global policy everywhere
        static let rowStepDistance = 0.06       // 2× the horizontal step; deliberate up/down
        static let reverseVerticalDirection = false
        static let focusWatchdogEnabled = true
        static let manageSpacesRearrange = false   // opt-in; only enabled via explicit consent
        static let manageVerticalGesture = false   // opt-in; relocates Mission Control to four fingers
        static let enableLauncher = false          // opt-in; frees four-finger native gestures
        static let launcherActivationThreshold = 0.01   // same feather-light trigger as the switcher
        static let launcherStepDistance = 0.04     // one item per ~4% travel
        static let launcherContextStepDistance = 0.09   // ~2.2× the item step; deliberate band switching
        static let dwellToArmDuration = 0.3        // quick tick; the charge stays readable
        static let showDiagnostics = false         // troubleshooting tools hidden from the menu by default
        static let keepClipboardHistory = false    // opt-in; records copied content locally (privacy)
        static let enableDeviceLink = false        // opt-in; opens a local-network link to the phone (privacy)
        static let clipboardPaused = false
        static let clipboardRecentWindow = 30      // entries shown in the band (pinned float to top)
        static let clipboardMaxCount = 200         // stored-entry cap (pinned exempt)
        static let clipboardMaxBytes = 256 * 1024 * 1024   // 256 MB of payloads (pinned exempt)
        static let clipboardMaxAgeDays = 0.0       // 0 = no age cap
        static let clipboardPollInterval = 0.5     // change-counter poll cadence (seconds)
        static let clipboardEdgeAcceleration = 1.0 // edge-scroll acceleration sensitivity
        static let clipboardPinDistance = 0.08     // deliberate horizontal flick to pin (≈2 item steps); left-exit is a single step
        static let clipboardExcludedApps: [String] = []
        static let keyboardLanguageEnabled = false // opt-in; gates per-app input-source learn/apply (no re-login)
        static let keyboardLanguageDefaultSourceID = ""  // "" = no global default (pure learn-as-you-go)
        // Per-host memory inside browsers rides along by default when the keyboard-language master
        // opt-in is enabled: the default (Accessibility) host reader needs NO new permission, so the
        // soft path costs nothing — only the Apple-Events "allow browser control" reader stays a
        // deliberate opt-in below. The feature is still fully inert until the MASTER toggle is on.
        static let keyboardLanguagePerSiteEnabled = true
        static let keyboardLanguageAllowBrowserControl = false   // opt-in; Apple Events host reader (per-browser permission)
        static let showDockPreviews = false        // opt-in; Dock-hover window previews (no re-login, no new permission)
        static let enableWindowGroups = false      // opt-in; snap-to-bind window groups (no re-login, no new permission)
        static let commandTabSwitcher = false      // opt-in; drive the switcher from ⌘-Tab (no re-login, no new permission)
        static let includeMinimizedWindows = false // opt-in; show minimized windows in the switcher + ⌘-Tab (de-minimize on select)
        static let swipeDownMinimizesAll = false   // opt-in; three-finger down minimizes all current-Space windows (reveal desktop)
    }

    private enum Keys {
        static let enabled = "enabled"
        static let activationThreshold = "activationThreshold"
        static let axisLockRatio = "axisLockRatio"
        static let stepDistance = "stepDistance"
        static let wrapAtEnds = "wrapAtEnds"
        /// The single JSON blob of all gesture bindings (the new single source of truth).
        static let gestureBindings = "gestureBindings"
        /// Legacy keys, read ONCE at init for the reverse-direction migration into the switcher axes; no
        /// longer written (the switcher binding is now the single source of truth).
        static let reverseDirection = "reverseDirection"
        static let velocitySmoothing = "velocitySmoothing"
        static let switcherWindowScale = "switcherWindowScale"
        static let requireExactlyThree = "requireExactlyThree"
        static let includeNonStandardWindows = "includeNonStandardWindows"
        static let windowAppRules = "windowAppRules"
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
        static let enableDeviceLink = "enableDeviceLink"
        static let clipboardPaused = "clipboardPaused"
        static let clipboardRecentWindow = "clipboardRecentWindow"
        static let clipboardMaxCount = "clipboardMaxCount"
        static let clipboardMaxBytes = "clipboardMaxBytes"
        static let clipboardMaxAgeDays = "clipboardMaxAgeDays"
        static let clipboardPollInterval = "clipboardPollInterval"
        static let clipboardEdgeAcceleration = "clipboardEdgeAcceleration"
        static let clipboardPinDistance = "clipboardPinDistance"
        static let clipboardExcludedApps = "clipboardExcludedApps"
        static let keyboardLanguageEnabled = "keyboardLanguageEnabled"
        static let keyboardLanguageDefaultSourceID = "keyboardLanguageDefaultSourceID"
        static let keyboardLanguagePerSiteEnabled = "keyboardLanguagePerSiteEnabled"
        static let keyboardLanguageAllowBrowserControl = "keyboardLanguageAllowBrowserControl"
        static let showDockPreviews = "showDockPreviews"
        static let enableWindowGroups = "enableWindowGroups"
        static let commandTabSwitcher = "commandTabSwitcher"
        static let includeMinimizedWindows = "includeMinimizedWindows"
        static let swipeDownMinimizesAll = "swipeDownMinimizesAll"
    }
}
