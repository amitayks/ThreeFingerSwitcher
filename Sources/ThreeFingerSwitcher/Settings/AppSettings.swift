import Foundation
import Combine

// MARK: - Files-band tunable enums

/// Which entry field the Files-band column sorts on. The list's secondary tiebreak (a stable name
/// compare) lives in the lister, so this only names the primary key. Persisted by `rawValue`.
enum FilesSortField: String, Codable, CaseIterable, Identifiable {
    case name   // case-insensitive display name
    case date   // last content-modification date
    case kind   // coarse `FileKind`, then name
    var id: String { rawValue }
}

/// Ascending vs. descending for the Files-band sort. Kept separate from the field so any field can
/// be flipped without multiplying the field enum. Persisted by `rawValue`.
enum FilesSortDirection: String, Codable, CaseIterable, Identifiable {
    case ascending
    case descending
    var id: String { rawValue }
}

/// Row height / padding of the Files-band current column — how tightly rows pack. Persisted by
/// `rawValue`; the concrete point metrics for each case live in the view layer.
enum FilesDensity: String, Codable, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious
    var id: String { rawValue }
}

/// Whether a Files-band row leads with the file's plain type icon or a live QuickLook preview
/// thumbnail. (The dedicated preview pane is separate; this governs the per-row leading glyph.)
/// Persisted by `rawValue`.
enum FilesIconStyle: String, Codable, CaseIterable, Identifiable {
    case icon      // the file/folder type icon (cheap, no QuickLook)
    case preview   // a QuickLook thumbnail when one is available, icon fallback
    var id: String { rawValue }
}

/// The default-open action committed for a highlighted **file** (a folder always opens as a Finder
/// window per the spec, regardless of this). `defaultApp` opens in the system default app;
/// `openWith` lands on the Open-With chooser instead of launching immediately. Persisted by `rawValue`.
enum FilesDefaultOpen: String, Codable, CaseIterable, Identifiable {
    case defaultApp   // open in the file's default application
    case openWith     // present the Open-With chooser instead of launching
    var id: String { rawValue }
}

/// Which secondary metadata a Files-band row shows beside its name. An `OptionSet` (mirroring
/// `DangerZoneSelection`) so several can show at once; persisted as the `Int` `rawValue`.
struct FilesRowMetadata: OptionSet, Equatable {
    let rawValue: Int

    /// Show the last-modified date.
    static let date = FilesRowMetadata(rawValue: 1 << 0)
    /// Show the coarse kind label (e.g. "Folder", "Image").
    static let kind = FilesRowMetadata(rawValue: 1 << 1)
    /// Show the file size (folders show item count in the view layer).
    static let size = FilesRowMetadata(rawValue: 1 << 2)
}

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

    /// The positional **outer threshold** for *item* movement (change `positional-navigation`, D7):
    /// the normalized centroid offset from the anchored center (≈1 at full footprint deflection) that
    /// crosses to emit one item-step. Repurposed from the old odometer "one item per N travel" knob;
    /// now expressed in offset units, not accumulated travel.
    @Published var launcherStepDistance: Double { didSet { persist(launcherStepDistance, Keys.launcherStepDistance) } }

    /// The positional **outer threshold** for *band* switching (change `positional-navigation`, D7):
    /// the vertical offset on the band list that switches one band. Coarser than the item threshold so
    /// band switching stays deliberate without slowing item movement.
    @Published var launcherContextStepDistance: Double { didSet { persist(launcherContextStepDistance, Keys.launcherContextStepDistance) } }

    /// The positional **inner deadzone** (change `positional-navigation`): returning the offset inside
    /// this (toward center) re-arms an axis, so a quick out-and-back is exactly one step. `< the item
    /// and band outer thresholds`.
    @Published var positionalInnerDeadzone: Double { didSet { persist(positionalInnerDeadzone, Keys.positionalInnerDeadzone) } }

    /// How many footprint-widths of centroid travel reach full deflection (change `positional-navigation`,
    /// D2). Larger = a bigger physical move is needed for the same offset.
    @Published var positionalFootprintFactor: Double { didSet { persist(positionalFootprintFactor, Keys.positionalFootprintFactor) } }

    /// The fixed full-deflection distance used when the fingers' footprint is unavailable / degenerate
    /// (test frames, a single contact) — the fallback scale for the anchored offset (change
    /// `positional-navigation`, D2).
    @Published var positionalFallbackScale: Double { didSet { persist(positionalFallbackScale, Keys.positionalFallbackScale) } }

    /// Seconds before the *second* auto-repeat step once an offset is held (the first step fires
    /// immediately on the outer-threshold crossing). The eased curve then shortens the interval from
    /// here toward `positionalRepeatFloor` (change `positional-navigation`, D4).
    @Published var positionalInitialRepeatDelay: Double { didSet { persist(positionalInitialRepeatDelay, Keys.positionalInitialRepeatDelay) } }

    /// The fastest auto-repeat interval the eased curve approaches while an offset is held (change
    /// `positional-navigation`, D4).
    @Published var positionalRepeatFloor: Double { didSet { persist(positionalRepeatFloor, Keys.positionalRepeatFloor) } }

    /// Dwell duration over which the auto-repeat interval eases from the initial delay down to the
    /// floor — the "accelerate along a curve, not slow→fast in no time" ramp (change
    /// `positional-navigation`, D4).
    @Published var positionalRepeatRampTime: Double { didSet { persist(positionalRepeatRampTime, Keys.positionalRepeatRampTime) } }

    /// How far the offset may retreat from its furthest held point (offset units) before the center snaps
    /// onto the finger and auto-repeat stops — the "small move back re-centers and stops the acceleration"
    /// refinement. Must sit above natural hold jitter or a steady hold can't sustain auto-repeat; lower it
    /// for a more sensitive stop. `0` disables it (re-arm only via the deadzone).
    @Published var positionalReArmBackoff: Double { didSet { persist(positionalReArmBackoff, Keys.positionalReArmBackoff) } }

    /// The launcher **padding-box** half-size, in offset units (the "make the padding bigger/smaller"
    /// control). Inside the box the selection position-tracks your finger in steps (center locked); leaving
    /// it accelerates. Bigger = more room to step before acceleration.
    @Published var positionalPaddingRadius: Double { didSet { persist(positionalPaddingRadius, Keys.positionalPaddingRadius) } }

    /// The fixed **edge-margin band** width near the trackpad border (absolute normalized units). Pushing
    /// the fingers into this band accelerates even before the padding box's radius is reached — the
    /// always-present "min margin" the padding squeezes against near the edges. `0` = box radius only.
    @Published var positionalEdgeMargin: Double { didSet { persist(positionalEdgeMargin, Keys.positionalEdgeMargin) } }

    /// Seconds the selection must rest on an item before it arms (then a lift fires it). Brief but
    /// deliberate — a quick scrub-and-lift never fires.
    @Published var dwellToArmDuration: Double { didSet { persist(dwellToArmDuration, Keys.dwellToArmDuration) } }

    /// Show the diagnostic tools ("Write Diagnostics", "Copy Focus Log") in the status menu. Off by
    /// default — these are troubleshooting affordances most users never need, so they're hidden
    /// behind this toggle to keep the menu tidy.
    @Published var showDiagnostics: Bool { didSet { defaults.set(showDiagnostics, forKey: Keys.showDiagnostics) } }

    /// Live-refresh the switcher's highlighted card: while the overlay is open the selected window is
    /// re-captured on a fast cadence so its preview updates in near-real-time (one window at a time,
    /// following the selection). Default ON; toggle off to show static one-shot thumbnails only.
    @Published var livePreviewEnabled: Bool { didSet { defaults.set(livePreviewEnabled, forKey: Keys.livePreviewEnabled) } }

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

    // MARK: - Files band (opt-in; default OFF)

    /// Opt-in to the launcher's Files band — a local-only Finder-mimic column navigator. Like the
    /// clipboard opt-in (and unlike the gesture opt-ins) this relocates no native gesture, needs no
    /// re-login, and requests no new permission; it reads the local filesystem on demand. There is NO
    /// `is…Effective` gate — the flip takes effect immediately: ON injects the band on the next launcher
    /// open, OFF removes it. Default OFF. Older settings have no key and decode with the opt-in OFF.
    @Published var filesBandEnabled: Bool { didSet { defaults.set(filesBandEnabled, forKey: Keys.filesBandEnabled) } }

    /// The user-configured **local** root folders the Files band opens onto (its entry column), as
    /// standardized absolute paths in display order. Stored as `[String]` paths (mirroring
    /// `clipboardExcludedApps`) because `AppSettings` persists only plist-native primitives and there is
    /// no security-scoped-bookmark precedent in this app; the Hub roots editor rejects network/iCloud
    /// locations at the boundary. Empty by default (the Hub seeds a sensible set on first configuration).
    @Published var filesRoots: [String] { didSet { defaults.set(filesRoots, forKey: Keys.filesRoots) } }

    /// Per-root remembered deepest location: a `root path → last deepest path` map so each root restores
    /// where the user left off (spec: "A root remembers where you left off"). Stored as a `[String: String]`
    /// exactly like `aiCommandLanguages`; orphan keys (a removed root) are harmless and pruned
    /// opportunistically. Use `rememberedLocation(forRoot:)` / `rememberLocation(_:forRoot:)`.
    @Published var filesRememberedLocations: [String: String] { didSet { defaults.set(filesRememberedLocations, forKey: Keys.filesRememberedLocations) } }

    /// Whether the Files band reopens **displaying the last folder you were in** rather than the roots
    /// list. When ON (default) the band opens straight onto the remembered deepest location of a configured
    /// root — restored AT OPEN, so the main column already shows that folder while the highlight is still on
    /// the band icon, and crossing into the column lands you exactly there with no jump. When OFF the band
    /// opens fresh on the roots list. The per-root remembered map (`filesRememberedLocations`) keeps tracking
    /// either way; this toggle only governs whether init consults it. Older settings decode with it ON.
    @Published var filesRememberLocation: Bool { didSet { defaults.set(filesRememberLocation, forKey: Keys.filesRememberLocation) } }

    /// Width of the Files band's current-list column, in points. Drives the bounded overlay width together
    /// with the thin ancestor icon-rail and the preview pane.
    @Published var filesColumnWidth: Double { didSet { persist(filesColumnWidth, Keys.filesColumnWidth) } }

    /// How tightly the current column's rows pack (row height / padding). Persisted by `rawValue`.
    @Published var filesDensity: FilesDensity { didSet { defaults.set(filesDensity.rawValue, forKey: Keys.filesDensity) } }

    /// The Files band's accent tint, stored as a `#RRGGBB` hex string (plist-native, single-property —
    /// matching how `AppSettings` persists every other setting; the band builder/view resolve it to the
    /// codebase's `ItemColor`/SwiftUI `Color` at their boundary). A synthetic band, so this is the one
    /// place its tint is configured (it has no entry in the authored bands store).
    @Published var filesBandTint: String { didSet { defaults.set(filesBandTint, forKey: Keys.filesBandTint) } }

    /// Whether a row leads with the plain type icon or a live QuickLook preview thumbnail. Persisted by
    /// `rawValue`.
    @Published var filesIconStyle: FilesIconStyle { didSet { defaults.set(filesIconStyle.rawValue, forKey: Keys.filesIconStyle) } }

    /// Primary sort key for a listed folder's entries. Persisted by `rawValue`; applied live by re-listing.
    @Published var filesSortField: FilesSortField { didSet { defaults.set(filesSortField.rawValue, forKey: Keys.filesSortField) } }

    /// Ascending vs. descending for `filesSortField`. Persisted by `rawValue`.
    @Published var filesSortDirection: FilesSortDirection { didSet { defaults.set(filesSortDirection.rawValue, forKey: Keys.filesSortDirection) } }

    /// The default-open action committed for a highlighted **file** (a folder always opens as a Finder
    /// window regardless). Persisted by `rawValue`.
    @Published var filesDefaultOpen: FilesDefaultOpen { didSet { defaults.set(filesDefaultOpen.rawValue, forKey: Keys.filesDefaultOpen) } }

    /// Which secondary metadata each row shows beside its name (date / kind / size — any combination).
    /// An `OptionSet` persisted as its `Int` `rawValue` (mirrors `DangerZoneSelection`).
    @Published var filesRowMetadata: FilesRowMetadata { didSet { defaults.set(filesRowMetadata.rawValue, forKey: Keys.filesRowMetadata) } }

    /// The remembered deepest path last navigated to inside `rootPath`, or nil if none has been recorded
    /// yet (cold start, or the root was just added).
    func rememberedLocation(forRoot rootPath: String) -> String? { filesRememberedLocations[rootPath] }

    /// Remember `path` as the deepest location inside `rootPath` (written when the user leaves the band or
    /// changes depth), so re-entering that root restores it.
    func rememberLocation(_ path: String, forRoot rootPath: String) {
        filesRememberedLocations[rootPath] = path
    }

    /// Best-effort orphan cleanup: drop remembered-location entries whose root is no longer configured.
    /// A no-op when nothing is orphaned (so it doesn't churn UserDefaults needlessly).
    func pruneRememberedLocations(keepingRoots liveRoots: Set<String>) {
        let kept = filesRememberedLocations.filter { liveRoots.contains($0.key) }
        if kept.count != filesRememberedLocations.count { filesRememberedLocations = kept }
    }

    // MARK: - Built-in media player (opt-in; default OFF)

    /// Opt-in to playing media files from the Files band in the built-in player. Like the clipboard /
    /// device-link / Files opt-ins (and unlike the gesture opt-ins) it relocates no native gesture, needs
    /// no re-login, and requests no new permission; there is NO `is…Effective` gate — the flip takes
    /// effect immediately. When OFF, opening a media file behaves exactly as before (system default app).
    /// Default OFF. Older settings have no key and decode with the opt-in OFF.
    @Published var useBuiltInPlayer: Bool { didSet { defaults.set(useBuiltInPlayer, forKey: Keys.useBuiltInPlayer) } }

    /// Per-media-kind default-open: when the opt-in is on, whether the built-in player handles video /
    /// audio / images respectively (each defaults ON). A disabled kind falls through to the system app.
    @Published var builtInPlayerHandlesVideo: Bool { didSet { defaults.set(builtInPlayerHandlesVideo, forKey: Keys.builtInPlayerHandlesVideo) } }
    @Published var builtInPlayerHandlesAudio: Bool { didSet { defaults.set(builtInPlayerHandlesAudio, forKey: Keys.builtInPlayerHandlesAudio) } }
    @Published var builtInPlayerHandlesImage: Bool { didSet { defaults.set(builtInPlayerHandlesImage, forKey: Keys.builtInPlayerHandlesImage) } }

    /// The default playback engine (AVFoundation or libmpv). AVFoundation is the default; libmpv is the
    /// alternative, also auto-offered when AVFoundation can't decode a file. Persisted by `rawValue`.
    @Published var playerDefaultEngine: PlaybackEngineKind { didSet { defaults.set(playerDefaultEngine.rawValue, forKey: Keys.playerDefaultEngine) } }

    /// Seconds per seek step (one two-finger out-and-back); auto-repeat issues more while held.
    @Published var playerSeekStep: Double { didSet { persist(playerSeekStep, Keys.playerSeekStep) } }

    /// Volume delta per step, in 0…1 units.
    @Published var playerVolumeStep: Double { didSet { persist(playerVolumeStep, Keys.playerVolumeStep) } }

    /// Resume a reopened file only when the saved position is at least this many seconds in (else start).
    @Published var playerResumeThreshold: Double { didSet { persist(playerResumeThreshold, Keys.playerResumeThreshold) } }

    /// Treat a saved position within this many seconds of the end as "finished" → start fresh.
    @Published var playerNearEndMargin: Double { didSet { persist(playerNearEndMargin, Keys.playerNearEndMargin) } }

    /// Whether the built-in player handles `kind` (the opt-in must also be on; checked by the caller).
    func builtInPlayerHandles(_ kind: MediaKind) -> Bool {
        switch kind {
        case .video: return builtInPlayerHandlesVideo
        case .audio: return builtInPlayerHandlesAudio
        case .image: return builtInPlayerHandlesImage
        }
    }

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
        positionalInnerDeadzone = defaults.object(forKey: Keys.positionalInnerDeadzone) as? Double ?? Defaults.positionalInnerDeadzone
        positionalFootprintFactor = defaults.object(forKey: Keys.positionalFootprintFactor) as? Double ?? Defaults.positionalFootprintFactor
        positionalFallbackScale = defaults.object(forKey: Keys.positionalFallbackScale) as? Double ?? Defaults.positionalFallbackScale
        positionalInitialRepeatDelay = defaults.object(forKey: Keys.positionalInitialRepeatDelay) as? Double ?? Defaults.positionalInitialRepeatDelay
        positionalRepeatFloor = defaults.object(forKey: Keys.positionalRepeatFloor) as? Double ?? Defaults.positionalRepeatFloor
        positionalRepeatRampTime = defaults.object(forKey: Keys.positionalRepeatRampTime) as? Double ?? Defaults.positionalRepeatRampTime
        positionalReArmBackoff = defaults.object(forKey: Keys.positionalReArmBackoff) as? Double ?? Defaults.positionalReArmBackoff
        positionalPaddingRadius = defaults.object(forKey: Keys.positionalPaddingRadius) as? Double ?? Defaults.positionalPaddingRadius
        positionalEdgeMargin = defaults.object(forKey: Keys.positionalEdgeMargin) as? Double ?? Defaults.positionalEdgeMargin
        dwellToArmDuration = defaults.object(forKey: Keys.dwellToArmDuration) as? Double ?? Defaults.dwellToArmDuration
        showDiagnostics = defaults.object(forKey: Keys.showDiagnostics) as? Bool ?? Defaults.showDiagnostics
        livePreviewEnabled = defaults.object(forKey: Keys.livePreviewEnabled) as? Bool ?? Defaults.livePreviewEnabled
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
        aiCommandsEnabled = defaults.object(forKey: Keys.aiCommandsEnabled) as? Bool ?? Defaults.aiCommandsEnabled
        aiSelectedModelID = defaults.object(forKey: Keys.aiSelectedModelID) as? String ?? Defaults.aiSelectedModelID
        aiCommandLanguages = defaults.object(forKey: Keys.aiCommandLanguages) as? [String: String] ?? Defaults.aiCommandLanguages
        aiReasoningEnabled = defaults.object(forKey: Keys.aiReasoningEnabled) as? Bool ?? Defaults.aiReasoningEnabled
        filesBandEnabled = defaults.object(forKey: Keys.filesBandEnabled) as? Bool ?? Defaults.filesBandEnabled
        filesRoots = defaults.object(forKey: Keys.filesRoots) as? [String] ?? Defaults.filesRoots
        filesRememberedLocations = defaults.object(forKey: Keys.filesRememberedLocations) as? [String: String] ?? Defaults.filesRememberedLocations
        filesRememberLocation = defaults.object(forKey: Keys.filesRememberLocation) as? Bool ?? Defaults.filesRememberLocation
        filesColumnWidth = defaults.object(forKey: Keys.filesColumnWidth) as? Double ?? Defaults.filesColumnWidth
        filesDensity = (defaults.object(forKey: Keys.filesDensity) as? String).flatMap(FilesDensity.init(rawValue:)) ?? Defaults.filesDensity
        filesBandTint = defaults.object(forKey: Keys.filesBandTint) as? String ?? Defaults.filesBandTint
        filesIconStyle = (defaults.object(forKey: Keys.filesIconStyle) as? String).flatMap(FilesIconStyle.init(rawValue:)) ?? Defaults.filesIconStyle
        filesSortField = (defaults.object(forKey: Keys.filesSortField) as? String).flatMap(FilesSortField.init(rawValue:)) ?? Defaults.filesSortField
        filesSortDirection = (defaults.object(forKey: Keys.filesSortDirection) as? String).flatMap(FilesSortDirection.init(rawValue:)) ?? Defaults.filesSortDirection
        filesDefaultOpen = (defaults.object(forKey: Keys.filesDefaultOpen) as? String).flatMap(FilesDefaultOpen.init(rawValue:)) ?? Defaults.filesDefaultOpen
        filesRowMetadata = (defaults.object(forKey: Keys.filesRowMetadata) as? Int).map(FilesRowMetadata.init(rawValue:)) ?? Defaults.filesRowMetadata
        useBuiltInPlayer = defaults.object(forKey: Keys.useBuiltInPlayer) as? Bool ?? Defaults.useBuiltInPlayer
        builtInPlayerHandlesVideo = defaults.object(forKey: Keys.builtInPlayerHandlesVideo) as? Bool ?? Defaults.builtInPlayerHandlesVideo
        builtInPlayerHandlesAudio = defaults.object(forKey: Keys.builtInPlayerHandlesAudio) as? Bool ?? Defaults.builtInPlayerHandlesAudio
        builtInPlayerHandlesImage = defaults.object(forKey: Keys.builtInPlayerHandlesImage) as? Bool ?? Defaults.builtInPlayerHandlesImage
        playerDefaultEngine = (defaults.object(forKey: Keys.playerDefaultEngine) as? String).flatMap(PlaybackEngineKind.init(rawValue:)) ?? Defaults.playerDefaultEngine
        playerSeekStep = defaults.object(forKey: Keys.playerSeekStep) as? Double ?? Defaults.playerSeekStep
        playerVolumeStep = defaults.object(forKey: Keys.playerVolumeStep) as? Double ?? Defaults.playerVolumeStep
        playerResumeThreshold = defaults.object(forKey: Keys.playerResumeThreshold) as? Double ?? Defaults.playerResumeThreshold
        playerNearEndMargin = defaults.object(forKey: Keys.playerNearEndMargin) as? Double ?? Defaults.playerNearEndMargin
        keyboardLanguageEnabled = defaults.object(forKey: Keys.keyboardLanguageEnabled) as? Bool ?? Defaults.keyboardLanguageEnabled
        keyboardLanguageDefaultSourceID = defaults.object(forKey: Keys.keyboardLanguageDefaultSourceID) as? String ?? Defaults.keyboardLanguageDefaultSourceID
        keyboardLanguagePerSiteEnabled = defaults.object(forKey: Keys.keyboardLanguagePerSiteEnabled) as? Bool ?? Defaults.keyboardLanguagePerSiteEnabled
        keyboardLanguageAllowBrowserControl = defaults.object(forKey: Keys.keyboardLanguageAllowBrowserControl) as? Bool ?? Defaults.keyboardLanguageAllowBrowserControl
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
        positionalInnerDeadzone = Defaults.positionalInnerDeadzone
        positionalFootprintFactor = Defaults.positionalFootprintFactor
        positionalFallbackScale = Defaults.positionalFallbackScale
        positionalInitialRepeatDelay = Defaults.positionalInitialRepeatDelay
        positionalRepeatFloor = Defaults.positionalRepeatFloor
        positionalRepeatRampTime = Defaults.positionalRepeatRampTime
        positionalReArmBackoff = Defaults.positionalReArmBackoff
        positionalPaddingRadius = Defaults.positionalPaddingRadius
        positionalEdgeMargin = Defaults.positionalEdgeMargin
        dwellToArmDuration = Defaults.dwellToArmDuration
        showDiagnostics = Defaults.showDiagnostics
        livePreviewEnabled = Defaults.livePreviewEnabled
        // Clipboard tunables reset; `keepClipboardHistory`, the exclusion list, and the stored history
        // itself are a privacy choice and are intentionally NOT reset (mirrors the opt-in handling).
        clipboardRecentWindow = Defaults.clipboardRecentWindow
        clipboardMaxCount = Defaults.clipboardMaxCount
        clipboardMaxBytes = Defaults.clipboardMaxBytes
        clipboardMaxAgeDays = Defaults.clipboardMaxAgeDays
        clipboardPollInterval = Defaults.clipboardPollInterval
        clipboardEdgeAcceleration = Defaults.clipboardEdgeAcceleration
        clipboardPinDistance = Defaults.clipboardPinDistance
        // Files appearance/behavior tunables reset; `filesBandEnabled` (the opt-in), the configured roots,
        // and the remembered-location map are a user choice (like the clipboard opt-in/exclusion list) and
        // are intentionally NOT reset.
        filesColumnWidth = Defaults.filesColumnWidth
        filesDensity = Defaults.filesDensity
        filesBandTint = Defaults.filesBandTint
        filesIconStyle = Defaults.filesIconStyle
        filesSortField = Defaults.filesSortField
        filesSortDirection = Defaults.filesSortDirection
        filesDefaultOpen = Defaults.filesDefaultOpen
        filesRowMetadata = Defaults.filesRowMetadata
        filesRememberLocation = Defaults.filesRememberLocation   // a behavior tunable (back to default ON); the remembered map itself is preserved above
        // Player tunables reset; `useBuiltInPlayer` (the opt-in) is a deliberate user choice and is
        // intentionally NOT reset, mirroring the launcher / clipboard / files opt-in handling.
        builtInPlayerHandlesVideo = Defaults.builtInPlayerHandlesVideo
        builtInPlayerHandlesAudio = Defaults.builtInPlayerHandlesAudio
        builtInPlayerHandlesImage = Defaults.builtInPlayerHandlesImage
        playerDefaultEngine = Defaults.playerDefaultEngine
        playerSeekStep = Defaults.playerSeekStep
        playerVolumeStep = Defaults.playerVolumeStep
        playerResumeThreshold = Defaults.playerResumeThreshold
        playerNearEndMargin = Defaults.playerNearEndMargin
        // `aiCommandsEnabled` (a consent-gated opt-in that allows a multi-gigabyte download) and the
        // selected-model pin are a deliberate user choice, so they're intentionally NOT reset — mirrors
        // the launcher / clipboard opt-in handling.
        // `keyboardLanguageEnabled` and the global-default source id are likewise an opt-in user choice
        // (the learned per-app map is a separate store), so they're intentionally NOT reset either.
        // The per-site sub-toggle and the Apple Events ("Allow browser control") opt-in are the same:
        // consent-gated user choices (the latter governs a per-browser permission), NOT reset here.
    }

    private func persist(_ value: Double, _ key: String) { defaults.set(value, forKey: key) }

    // The gesture-feel numbers below are tuned from extended real daily use (the maintainer's
    // dialed-in values, adopted as the shipped defaults): a feather-light trigger, fine steps,
    // and a quick dwell — the feel the product is meant to have out of the box.
    enum Defaults {
        static let activationThreshold = 0.01    // feather-light trigger (~1% of trackpad width)
        static let axisLockRatio = 1.0           // no dominance requirement; any drift picks the axis
        static let stepDistance = 0.03           // one window per ~3% of trackpad width (fine scrub)
        static let wrapAtEnds = false
        static let reverseDirection = false
        static let velocitySmoothing = 0.35
        static let requireExactlyThree = true
        static let rowStepDistance = 0.06       // 2× the horizontal step; deliberate up/down
        static let reverseVerticalDirection = false
        static let focusWatchdogEnabled = true
        static let manageSpacesRearrange = false   // opt-in; only enabled via explicit consent
        static let manageVerticalGesture = false   // opt-in; relocates Mission Control to four fingers
        static let enableLauncher = false          // opt-in; frees four-finger native gestures
        static let launcherActivationThreshold = 0.01   // same feather-light trigger as the switcher
        static let launcherStepDistance = 0.50     // item OUTER threshold (offset units, ≈half deflection)
        static let launcherContextStepDistance = 0.85   // band OUTER threshold; coarser → deliberate band switch
        // Positional navigation model (change `positional-navigation`).
        static let positionalInnerDeadzone = 0.22       // re-arm zone; < the item/band outer thresholds
        static let positionalFootprintFactor = 1.2      // footprint-widths of travel for full deflection
        static let positionalFallbackScale = 0.12       // fixed deflection distance when no footprint
        static let positionalInitialRepeatDelay = 0.22  // gap before the 2nd step (1st fires immediately)
        static let positionalRepeatFloor = 0.03         // fastest auto-repeat interval the curve approaches
        static let positionalRepeatRampTime = 1.2       // dwell seconds to ease from initial delay → floor
        static let positionalReArmBackoff = 0.25        // offset retreat that snaps center to finger & stops accel
        static let positionalPaddingRadius = 2.5        // padding-box half-size (offset units) before the margin
        static let positionalEdgeMargin = 0.10          // fixed border band (normalized) that always accelerates
        static let dwellToArmDuration = 0.3        // quick tick; the charge stays readable
        static let showDiagnostics = false         // troubleshooting tools hidden from the menu by default
        static let livePreviewEnabled = true       // show the in-flight preview while scrubbing (default ON)
        static let keepClipboardHistory = false    // opt-in; records copied content locally (privacy)
        static let enableDeviceLink = false        // opt-in; opens a local-network link to the phone (privacy)
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
        static let filesBandEnabled = false        // opt-in; injects the local-only Files band (no re-login, no new permission)
        static let filesRoots: [String] = []       // configured local root folders (the Hub seeds a default set)
        static let filesRememberedLocations: [String: String] = [:]   // root path → last deepest path
        static let filesRememberLocation = true    // reopen displaying the last folder (restored at open), not the roots list
        static let filesColumnWidth = 260.0        // points; current-list column width (bounded overlay)
        static let filesDensity: FilesDensity = .comfortable
        static let filesBandTint = "#3B82C4"       // a calm blue, distinct from the clipboard band's amber
        static let filesIconStyle: FilesIconStyle = .icon   // cheap type icon by default (no QuickLook churn)
        static let filesSortField: FilesSortField = .name
        static let filesSortDirection: FilesSortDirection = .ascending
        static let filesDefaultOpen: FilesDefaultOpen = .defaultApp
        static let filesRowMetadata: FilesRowMetadata = .date   // show the modified date beside the name
        static let useBuiltInPlayer = false        // opt-in; plays media from the Files band in the built-in player
        static let builtInPlayerHandlesVideo = true
        static let builtInPlayerHandlesAudio = true
        static let builtInPlayerHandlesImage = true
        static let playerDefaultEngine: PlaybackEngineKind = .avFoundation   // AVFoundation default; libmpv the alternative
        static let playerSeekStep = 10.0           // seconds per seek step (hold auto-repeats)
        static let playerVolumeStep = 0.05         // 5% volume per step
        static let playerResumeThreshold = 5.0     // resume only past 5s in
        static let playerNearEndMargin = 10.0      // within 10s of the end → start fresh
        static let keyboardLanguageEnabled = false // opt-in; gates per-app input-source learn/apply (no re-login)
        static let keyboardLanguageDefaultSourceID = ""  // "" = no global default (pure learn-as-you-go)
        // Per-host memory inside browsers rides along by default when the keyboard-language master
        // opt-in is enabled: the default (Accessibility) host reader needs NO new permission, so the
        // soft path costs nothing — only the Apple-Events "allow browser control" reader stays a
        // deliberate opt-in below. The feature is still fully inert until the MASTER toggle is on.
        static let keyboardLanguagePerSiteEnabled = true
        static let keyboardLanguageAllowBrowserControl = false   // opt-in; Apple Events host reader (per-browser permission)
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
        static let positionalInnerDeadzone = "positionalInnerDeadzone"
        static let positionalFootprintFactor = "positionalFootprintFactor"
        static let positionalFallbackScale = "positionalFallbackScale"
        static let positionalInitialRepeatDelay = "positionalInitialRepeatDelay"
        static let positionalRepeatFloor = "positionalRepeatFloor"
        static let positionalRepeatRampTime = "positionalRepeatRampTime"
        static let positionalReArmBackoff = "positionalReArmBackoff"
        static let positionalPaddingRadius = "positionalPaddingRadius"
        static let positionalEdgeMargin = "positionalEdgeMargin"
        static let dwellToArmDuration = "dwellToArmDuration"
        static let showDiagnostics = "showDiagnostics"
        static let livePreviewEnabled = "livePreviewEnabled"
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
        static let aiCommandsEnabled = "aiCommandsEnabled"
        static let aiSelectedModelID = "aiSelectedModelID"
        static let aiCommandLanguages = "aiCommandLanguages"
        static let aiReasoningEnabled = "aiReasoningEnabled"
        static let filesBandEnabled = "filesBandEnabled"
        static let filesRoots = "filesRoots"
        static let filesRememberedLocations = "filesRememberedLocations"
        static let filesRememberLocation = "filesRememberLocation"
        static let filesColumnWidth = "filesColumnWidth"
        static let filesDensity = "filesDensity"
        static let filesBandTint = "filesBandTint"
        static let filesIconStyle = "filesIconStyle"
        static let filesSortField = "filesSortField"
        static let filesSortDirection = "filesSortDirection"
        static let filesDefaultOpen = "filesDefaultOpen"
        static let filesRowMetadata = "filesRowMetadata"
        static let useBuiltInPlayer = "useBuiltInPlayer"
        static let builtInPlayerHandlesVideo = "builtInPlayerHandlesVideo"
        static let builtInPlayerHandlesAudio = "builtInPlayerHandlesAudio"
        static let builtInPlayerHandlesImage = "builtInPlayerHandlesImage"
        static let playerDefaultEngine = "playerDefaultEngine"
        static let playerSeekStep = "playerSeekStep"
        static let playerVolumeStep = "playerVolumeStep"
        static let playerResumeThreshold = "playerResumeThreshold"
        static let playerNearEndMargin = "playerNearEndMargin"
        static let keyboardLanguageEnabled = "keyboardLanguageEnabled"
        static let keyboardLanguageDefaultSourceID = "keyboardLanguageDefaultSourceID"
        static let keyboardLanguagePerSiteEnabled = "keyboardLanguagePerSiteEnabled"
        static let keyboardLanguageAllowBrowserControl = "keyboardLanguageAllowBrowserControl"
    }
}
