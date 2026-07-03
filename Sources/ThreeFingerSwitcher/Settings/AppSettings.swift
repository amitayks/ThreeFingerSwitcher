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

    /// The user's resolution-gesture bindings for the three remappable surfaces (the AI canvas resolve,
    /// the Files-drill resolution, and the switcher per-axis scrub directions). Persisted as a single
    /// JSON blob (`Data` is plist-native, mirroring `FavoritesStore`) so the per-surface vocabularies
    /// stay co-versioned. Defaults to exactly today's behavior. The switcher axes are the single source
    /// of truth for the former `reverseDirection` / `reverseVerticalDirection` booleans, which are now
    /// computed accessors onto this binding (no duplicate persisted keys).
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
    /// vertically between grid rows (odometer, with carry). Also drives the Files navigator's depth /
    /// highlight stepping.
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

    /// The fleet roster's pinned ACTIVE CHAT model id (the radio AMONG chat-role members), or nil for the
    /// registry/fleet chat default. Distinct from the capability toggles below: a chat model is the single
    /// resident conversational brain, so it is a radio choice. nil encodes as absent (legacy-safe).
    @Published var aiSelectedChatModelID: String? {
        didSet { defaults.set(aiSelectedChatModelID, forKey: Keys.aiSelectedChatModelID) }
    }

    /// The set of ENABLED capability-model ids (image / ternary / video) — INDEPENDENT toggles, NOT a
    /// radio, because these co-reside with (or are evicted around) the chat model rather than replacing
    /// it. Enabling one inserts its id here AND triggers its download if not already on disk. Persisted as
    /// a string array; absent ⇒ empty (legacy-safe — pre-wave settings read back with nothing enabled).
    @Published var aiEnabledCapabilityModelIDs: Set<String> {
        didSet { defaults.set(Array(aiEnabledCapabilityModelIDs), forKey: Keys.aiEnabledCapabilityModelIDs) }
    }

    // MARK: - Release Full Potential (master gate + sub-flags; default OFF — addendum §D1)

    /// The master **Release Full Potential** opt-in (`ai-full-potential-toggle`, addendum §D1). Default
    /// OFF — V2.5 ships calm; this one deliberate, user-owned act lights up the heavy AI fleet. Like the
    /// clipboard/device-link opt-ins it relocates NO native gesture, needs NO re-login, and requests NO
    /// new permission; it takes effect immediately. Turning it OFF closes every sub-capability gate at
    /// once (the calm panic-off) WITHOUT zeroing the sub-flags below — re-arming restores the prior
    /// selection (the gate relocks by computation, never by mutating the stored flags). Older settings
    /// have no key and decode with the master OFF. Preserved by `resetToDefaults` like the other AI opt-ins.
    @Published var fullPotentialEnabled: Bool { didSet { defaults.set(fullPotentialEnabled, forKey: Keys.fullPotentialEnabled) } }

    /// Sub-flag: the CPU ternary lane (`ai-compute-tiers`). Gated under the master. Cost: heat/battery —
    /// a second (CPU) lane runs concurrently; short structured bursts only, CPU per-token is slower.
    /// Default OFF; persisted; preserved by reset.
    @Published var cpuLaneEnabled: Bool { didSet { defaults.set(cpuLaneEnabled, forKey: Keys.cpuLaneEnabled) } }

    /// Sub-flag: the K-stream GPU batched runtime + growable context (`ai-batched-runtime-and-context`).
    /// Gated under the master. Cost: RAM + latency — multiplexes K sessions over one weight read; larger
    /// context = more resident KV; latency rises under load. Default OFF; persisted; preserved by reset.
    @Published var batchedRuntimeEnabled: Bool { didSet { defaults.set(batchedRuntimeEnabled, forKey: Keys.batchedRuntimeEnabled) } }

    /// Sub-flag: image/video generation tools (`ai-media-runtime` + backends). Gated under the master.
    /// Cost: RAM (eviction) + latency + disk — a heavy gen EVICTS chat ("the assistant goes quiet while
    /// it paints"); minutes per clip; tens of GB of weights. Default OFF; persisted; preserved by reset.
    @Published var mediaGenEnabled: Bool { didSet { defaults.set(mediaGenEnabled, forKey: Keys.mediaGenEnabled) } }

    /// Sub-flag: parked auto-vs-escalate + whitelist + audit (`ai-background-autonomy`). Gated under the
    /// master. Cost: unattended action — the agent may act while you are away (whitelisted/contained
    /// writes only; dangerous ones still escalate; all audited). Default OFF; persisted; preserved by reset.
    @Published var backgroundAutonomyEnabled: Bool { didSet { defaults.set(backgroundAutonomyEnabled, forKey: Keys.backgroundAutonomyEnabled) } }

    /// Sub-flag: cloud fleet members — Claude / GLM-5.2 (`ai-model-fleet` cloud members). Gated under the
    /// master. Cost: $ + network + data off-device — sends prompts to a paid cloud model; budget-capped +
    /// audited; off until armed. Default OFF; persisted; preserved by reset.
    @Published var fleetCloudEscalationEnabled: Bool { didSet { defaults.set(fleetCloudEscalationEnabled, forKey: Keys.fleetCloudEscalationEnabled) } }

    /// The pure `FullPotentialFlags` the gate consumes, assembled from the six persisted keys plus the
    /// existing AI-commands opt-in (consumed verbatim — the AI-commands opt-in is owned by
    /// `tunable-settings`, not redefined here). Read at consult time so a flag edit live-applies.
    var fullPotentialFlags: FullPotentialFlags {
        FullPotentialFlags(aiCommandsEnabled: aiCommandsEnabled,
                           fullPotentialEnabled: fullPotentialEnabled,
                           cpuLane: cpuLaneEnabled,
                           batchedRuntime: batchedRuntimeEnabled,
                           mediaGen: mediaGenEnabled,
                           backgroundAutonomy: backgroundAutonomyEnabled,
                           fleetCloud: fleetCloudEscalationEnabled)
    }

    /// The Full Potential gate every heavy slice consults via one `isUnlocked(_:)` check before
    /// activating. A computed convenience over `fullPotentialFlags` — pure, total, never throws.
    var fullPotentialGate: FullPotentialGate {
        FullPotentialGate(flags: fullPotentialFlags)
    }

    /// The selected VIDEO backend behind the `MediaRuntime` seam (`ai-video-animation-generation`,
    /// addendum §1). `.cloud` (the honest default — a hosted API, nothing downloaded) or `.localLTXV`
    /// (the frontier — 35 GB+, gated by the master toggle). Persisted by `rawValue`; an unreadable /
    /// absent value reads back as the calm `.cloud` default. The master-gate validity of `.localLTXV`
    /// is enforced at selection by `VideoProvider.isSelectable(...)`, not here.
    @Published var videoProvider: VideoProvider { didSet { defaults.set(videoProvider.rawValue, forKey: Keys.videoProvider) } }

    /// The per-rolling-24h CLOUD-video budget cap (`ai-video-animation-generation`, addendum §1). Cloud
    /// video spends real money + uploads bytes, so it is `.dangerous` AND rate-capped: the `VideoBudget`
    /// admits at most this many cloud generations per rolling-24h window (NOT a calendar reset). A
    /// conservative default so an autonomous loop physically cannot rack up spend before the user
    /// deliberately raises it; 0 effectively disables cloud video.
    @Published var mediaVideoBudgetPerDay: Int { didSet { defaults.set(mediaVideoBudgetPerDay, forKey: Keys.mediaVideoBudgetPerDay) } }

    /// Per-command remembered runtime-parameter language (spec: "Per-command runtime-parameter
    /// persistence"), keyed by the command's identifier string → the last chosen language. Out-of-band
    /// from the command itself, so seeds/catalog/band edits are unaffected; orphan keys (deleted
    /// commands) are harmless and pruned opportunistically. Stored as a `[String: String]` dictionary.
    @Published var aiCommandLanguages: [String: String] { didSet { defaults.set(aiCommandLanguages, forKey: Keys.aiCommandLanguages) } }

    /// Let the on-device model reason before answering (thinking is filtered from the result). Default
    /// ON; gated behind the AI opt-in like the other AI prefs.
    @Published var aiReasoningEnabled: Bool { didSet { defaults.set(aiReasoningEnabled, forKey: Keys.aiReasoningEnabled) } }

    /// The agent's context-size preset (`ai-batched-runtime-and-context`, design D5). Drives
    /// `agentContextTokens`; longer context trades background concurrency + speed for recall (the Hub
    /// surfaces the RAM/stream cost). Default Balanced.
    @Published var agentContextPreset: AgentContextPreset { didSet { defaults.set(agentContextPreset.rawValue, forKey: Keys.agentContextPreset) } }
    /// The resolved context-token budget (clamped to the model max). Feeds conversation-runtime
    /// compaction through the injected `ContextBudgetProviding`, so growing it raises the compaction
    /// trigger and the two never disagree about "the budget."
    @Published var agentContextTokens: Int { didSet { defaults.set(agentContextTokens, forKey: Keys.agentContextTokens) } }
    /// Compact long contexts with 8-bit KV cache — a longer context fits the same RAM at a small quality
    /// cost (design D6). Default OFF.
    @Published var agentCompactKV: Bool { didSet { defaults.set(agentCompactKV, forKey: Keys.agentCompactKV) } }

    /// Soft target for the parked-session set (`ai-parked-sessions`, design §7). When exceeded, the
    /// least-recently-updated IDLE session is evicted (never an active/needs-you/thinking one).
    @Published var agentMaxParkedSessions: Int { didSet { defaults.set(agentMaxParkedSessions, forKey: Keys.agentMaxParkedSessions) } }
    /// How long a parked session may stay idle before it summarizes-and-sleeps (drops its KV cache, keeps
    /// a one-line resume). Seconds. RETIRED by design D1 (no live consumer) — kept only so an existing
    /// stored value migrates cleanly; the live aging behavior is now `agentParkAutoDismissCountdown`.
    @Published var agentParkIdleTimeout: TimeInterval { didSet { defaults.set(agentParkIdleTimeout, forKey: Keys.agentParkIdleTimeout) } }
    /// The single user-configurable AUTO-DISMISS countdown (design D1): a parked/idle session untouched for
    /// this long — and any session whose task COMPLETED — is dismissed FOREVER through the same
    /// authoritative discard path as a manual dismiss (no summarize-and-sleep). Seconds; default 300 (5 min).
    @Published var agentParkAutoDismissCountdown: TimeInterval { didSet { defaults.set(agentParkAutoDismissCountdown, forKey: Keys.agentParkAutoDismissCountdown) } }
    /// The two-finger UP excursion (normalized) past the canvas bottom that parks the conversation. Sits
    /// ABOVE the incidental scroll threshold (`canvasResolveThreshold`) so a normal scroll-to-bottom
    /// never parks.
    @Published var agentOverscrollParkThreshold: Double { didSet { defaults.set(agentOverscrollParkThreshold, forKey: Keys.agentOverscrollParkThreshold) } }
    /// Peak smoothed centroid velocity (normalized units/sec) a canvas excursion must reach before its
    /// lift counts as a FLICK (commit/park) rather than a slow reading-scroll (D4). A sub-threshold peak —
    /// or fingers held down without a prompt lift — is SCROLL and never resolves the canvas. Run-verify
    /// tuning (real trackpad EMA + frame cadence).
    @Published var flickVelocityThreshold: Double { didSet { defaults.set(flickVelocityThreshold, forKey: Keys.flickVelocityThreshold) } }
    /// Maximum delay (seconds) between the last high-velocity in-contact frame and the lift for that lift to
    /// count as a flick. A longer pause before lifting means the fingers decelerated to a scroll/hold, so it
    /// is NOT a flick (D4). Run-verify tuning.
    @Published var flickLiftWindow: Double { didSet { defaults.set(flickLiftWindow, forKey: Keys.flickLiftWindow) } }

    // MARK: - Background autonomy whitelist (ai-background-autonomy; default EMPTY)

    /// The user's trusted folder path prefixes — a parked agent may auto-run a `confirm` write whose
    /// target standardizes under one of these (component-boundary match). Default empty: a fresh install
    /// trusts nothing arbitrary (the app's own memory/project stores are CONTAINED and auto WITHOUT a
    /// whitelist row). A privacy/trust choice, so it is NOT cleared by `resetToDefaults` (mirrors the
    /// AI/clipboard/files opt-in handling).
    @Published var agentWhitelistPaths: [String] { didSet { defaults.set(agentWhitelistPaths, forKey: Keys.agentWhitelistPaths) } }

    /// The user's trusted command patterns (anchored `*`/`?` globs against a tool/Shortcut name or a
    /// shell `argv[0]`). Default empty; NOT cleared by `resetToDefaults` (same trust-choice rationale).
    @Published var agentWhitelistCommands: [String] { didSet { defaults.set(agentWhitelistCommands, forKey: Keys.agentWhitelistCommands) } }

    /// The pure `Whitelist` value the routing loop's `BackgroundPolicyResolver` consumes — assembled from
    /// the two persisted lists. Read at resolution time so edits live-apply on the next step.
    var agentWhitelist: Whitelist {
        Whitelist(trustedPathPrefixes: agentWhitelistPaths, trustedCommandPatterns: agentWhitelistCommands)
    }

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

    /// What the Files-band **lift** (the drill's primary resolve excursion) does on commit: `deliver`
    /// (default) pastes the highlighted entry into the captured front app (`files-contextual-delivery`);
    /// `open` opens it (file → default app per `filesDefaultOpen`, folder → Finder window). Orthogonal to
    /// `filesDefaultOpen`, which only refines what an *open* of a file does. Persisted by `rawValue`.
    @Published var filesLiftAction: FilesLiftAction { didSet { defaults.set(filesLiftAction.rawValue, forKey: Keys.filesLiftAction) } }

    /// The user-configurable Files **action-menu** contents, per entry type (`files-action-menu`). Persisted
    /// as a JSON blob (like `gestureBindings`); defaults to the specified per-type menus.
    @Published var filesActionMenu: FilesActionMenu { didSet { persistCodable(filesActionMenu, Keys.filesActionMenu) } }

    /// Bundle ids of detected terminals/editors the user has **disabled** from the action menu. The curated
    /// set is "all detected tools, minus these," so default empty = every detected tool enabled.
    @Published var filesToolsDisabled: [String] { didSet { defaults.set(filesToolsDisabled, forKey: Keys.filesToolsDisabled) } }

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
    /// raise it. Like the clipboard / Files opt-ins (and unlike the gesture opt-ins) this relocates NO
    /// native gesture, needs NO re-login, and requests NO new permission — it reuses the already-granted
    /// Accessibility (read the Dock's AX tree + raise) and Screen Recording (thumbnails) grants. There is
    /// NO `is…Effective` gate: flipping it ON installs the cursor monitor + Dock reader, OFF tears them
    /// down. Default OFF. Older settings have no key and decode with the opt-in OFF.
    @Published var showDockPreviews: Bool { didSet { defaults.set(showDockPreviews, forKey: Keys.showDockPreviews) } }

    /// Opt-in: drive the window switcher from ⌘-Tab (intercept it, suppress the native application
    /// switcher). Like `showDockPreviews` it needs NO re-login and requests NO new permission — it
    /// reuses the already-granted Accessibility (active consuming event tap + raise) and the tracked
    /// Input Monitoring. Because interception is a live event tap, flipping it ON installs the keyboard
    /// tap and OFF removes it (native ⌘-Tab restored immediately). Default OFF; older settings decode OFF.
    @Published var commandTabSwitcher: Bool { didSet { defaults.set(commandTabSwitcher, forKey: Keys.commandTabSwitcher) } }

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
        aiCommandsEnabled = defaults.object(forKey: Keys.aiCommandsEnabled) as? Bool ?? Defaults.aiCommandsEnabled
        aiSelectedModelID = defaults.object(forKey: Keys.aiSelectedModelID) as? String ?? Defaults.aiSelectedModelID
        aiSelectedChatModelID = defaults.object(forKey: Keys.aiSelectedChatModelID) as? String ?? Defaults.aiSelectedChatModelID
        aiEnabledCapabilityModelIDs = Set(defaults.object(forKey: Keys.aiEnabledCapabilityModelIDs) as? [String]
                                          ?? Defaults.aiEnabledCapabilityModelIDs)
        // Full Potential master + sub-flags (addendum §D1): absent key ⇒ false (legacy-load), so settings
        // written before this wave decode with the whole fleet OFF, leaving existing settings unchanged.
        fullPotentialEnabled = defaults.object(forKey: Keys.fullPotentialEnabled) as? Bool ?? Defaults.fullPotentialEnabled
        cpuLaneEnabled = defaults.object(forKey: Keys.cpuLaneEnabled) as? Bool ?? Defaults.cpuLaneEnabled
        batchedRuntimeEnabled = defaults.object(forKey: Keys.batchedRuntimeEnabled) as? Bool ?? Defaults.batchedRuntimeEnabled
        mediaGenEnabled = defaults.object(forKey: Keys.mediaGenEnabled) as? Bool ?? Defaults.mediaGenEnabled
        backgroundAutonomyEnabled = defaults.object(forKey: Keys.backgroundAutonomyEnabled) as? Bool ?? Defaults.backgroundAutonomyEnabled
        fleetCloudEscalationEnabled = defaults.object(forKey: Keys.fleetCloudEscalationEnabled) as? Bool ?? Defaults.fleetCloudEscalationEnabled
        videoProvider = (defaults.object(forKey: Keys.videoProvider) as? String)
            .flatMap(VideoProvider.init(rawValue:)) ?? Defaults.videoProvider
        mediaVideoBudgetPerDay = defaults.object(forKey: Keys.mediaVideoBudgetPerDay) as? Int ?? Defaults.mediaVideoBudgetPerDay
        aiCommandLanguages = defaults.object(forKey: Keys.aiCommandLanguages) as? [String: String] ?? Defaults.aiCommandLanguages
        aiReasoningEnabled = defaults.object(forKey: Keys.aiReasoningEnabled) as? Bool ?? Defaults.aiReasoningEnabled
        agentContextPreset = AgentContextPreset(rawValue: defaults.string(forKey: Keys.agentContextPreset) ?? "") ?? Defaults.agentContextPreset
        agentContextTokens = defaults.object(forKey: Keys.agentContextTokens) as? Int ?? Defaults.agentContextTokens
        agentCompactKV = defaults.object(forKey: Keys.agentCompactKV) as? Bool ?? Defaults.agentCompactKV
        agentMaxParkedSessions = defaults.object(forKey: Keys.agentMaxParkedSessions) as? Int ?? Defaults.agentMaxParkedSessions
        agentParkIdleTimeout = defaults.object(forKey: Keys.agentParkIdleTimeout) as? TimeInterval ?? Defaults.agentParkIdleTimeout
        agentParkAutoDismissCountdown = defaults.object(forKey: Keys.agentParkAutoDismissCountdown) as? TimeInterval ?? Defaults.agentParkAutoDismissCountdown
        agentOverscrollParkThreshold = defaults.object(forKey: Keys.agentOverscrollParkThreshold) as? Double ?? Defaults.agentOverscrollParkThreshold
        flickVelocityThreshold = defaults.object(forKey: Keys.flickVelocityThreshold) as? Double ?? Defaults.flickVelocityThreshold
        flickLiftWindow = defaults.object(forKey: Keys.flickLiftWindow) as? Double ?? Defaults.flickLiftWindow
        agentWhitelistPaths = defaults.object(forKey: Keys.agentWhitelistPaths) as? [String] ?? Defaults.agentWhitelistPaths
        agentWhitelistCommands = defaults.object(forKey: Keys.agentWhitelistCommands) as? [String] ?? Defaults.agentWhitelistCommands
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
        filesLiftAction = (defaults.object(forKey: Keys.filesLiftAction) as? String).flatMap(FilesLiftAction.init(rawValue:)) ?? Defaults.filesLiftAction
        filesActionMenu = AppSettings.loadCodable(FilesActionMenu.self, defaults, Keys.filesActionMenu) ?? Defaults.filesActionMenu
        filesToolsDisabled = defaults.object(forKey: Keys.filesToolsDisabled) as? [String] ?? Defaults.filesToolsDisabled
        keyboardLanguageEnabled = defaults.object(forKey: Keys.keyboardLanguageEnabled) as? Bool ?? Defaults.keyboardLanguageEnabled
        keyboardLanguageDefaultSourceID = defaults.object(forKey: Keys.keyboardLanguageDefaultSourceID) as? String ?? Defaults.keyboardLanguageDefaultSourceID
        keyboardLanguagePerSiteEnabled = defaults.object(forKey: Keys.keyboardLanguagePerSiteEnabled) as? Bool ?? Defaults.keyboardLanguagePerSiteEnabled
        keyboardLanguageAllowBrowserControl = defaults.object(forKey: Keys.keyboardLanguageAllowBrowserControl) as? Bool ?? Defaults.keyboardLanguageAllowBrowserControl
        showDockPreviews = defaults.object(forKey: Keys.showDockPreviews) as? Bool ?? Defaults.showDockPreviews
        commandTabSwitcher = defaults.object(forKey: Keys.commandTabSwitcher) as? Bool ?? Defaults.commandTabSwitcher
    }

    func resetToDefaults() {
        activationThreshold = Defaults.activationThreshold
        axisLockRatio = Defaults.axisLockRatio
        stepDistance = Defaults.stepDistance
        wrapAtEnds = Defaults.wrapAtEnds
        velocitySmoothing = Defaults.velocitySmoothing
        switcherWindowScale = Defaults.switcherWindowScale
        requireExactlyThree = Defaults.requireExactlyThree
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
        filesLiftAction = Defaults.filesLiftAction   // back to deliver (the default contextual-delivery lift)
        filesActionMenu = Defaults.filesActionMenu   // per-type menus back to the specified defaults
        filesToolsDisabled = Defaults.filesToolsDisabled   // all detected terminals/editors enabled again
        filesRememberLocation = Defaults.filesRememberLocation   // a behavior tunable (back to default ON); the remembered map itself is preserved above
        // Agent context tuning is a behavior tunable (like the clipboard/files appearance tunables), so it
        // resets here back to Balanced / 8-bit-KV-off. The AI opt-in + model pin below are NOT reset.
        agentContextPreset = Defaults.agentContextPreset
        agentContextTokens = Defaults.agentContextTokens
        agentCompactKV = Defaults.agentCompactKV
        agentMaxParkedSessions = Defaults.agentMaxParkedSessions
        agentParkIdleTimeout = Defaults.agentParkIdleTimeout
        agentParkAutoDismissCountdown = Defaults.agentParkAutoDismissCountdown
        agentOverscrollParkThreshold = Defaults.agentOverscrollParkThreshold
        flickVelocityThreshold = Defaults.flickVelocityThreshold
        flickLiftWindow = Defaults.flickLiftWindow
        // `aiCommandsEnabled` (a consent-gated opt-in that allows a multi-gigabyte download) and the
        // selected-model pin are a deliberate user choice, so they're intentionally NOT reset — mirrors
        // the launcher / clipboard opt-in handling.
        // The background-autonomy whitelist (`agentWhitelistPaths`/`agentWhitelistCommands`) is the
        // security boundary — a deliberate trust choice — so it is intentionally NOT reset here either
        // (same handling as the other AI opt-ins; a reset never silently widens or narrows trust).
        // `keyboardLanguageEnabled` and the global-default source id are likewise an opt-in user choice
        // (the learned per-app map is a separate store), so they're intentionally NOT reset either.
        // The per-site sub-toggle and the Apple Events ("Allow browser control") opt-in are the same:
        // consent-gated user choices (the latter governs a per-browser permission), NOT reset here.
        // `showDockPreviews` is likewise an opt-in user choice (no tunables of its own), NOT reset here.
        // The Release Full Potential master + five sub-flags (`fullPotentialEnabled`, `cpuLaneEnabled`,
        // `batchedRuntimeEnabled`, `mediaGenEnabled`, `backgroundAutonomyEnabled`,
        // `fleetCloudEscalationEnabled`) are consent-gated opt-ins (some allow a multi-GB media download or
        // real cloud spend), so they JOIN the AI opt-in preserve-set — intentionally NOT reset here. A
        // tunables reset must never silently re-arm or disarm a fleet the user deliberately configured.
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
        static let rowStepDistance = 0.06       // 2× the horizontal step; deliberate up/down
        static let reverseVerticalDirection = false
        static let focusWatchdogEnabled = true
        static let manageSpacesRearrange = false   // opt-in; only enabled via explicit consent
        static let manageVerticalGesture = false   // opt-in; relocates Mission Control to four fingers
        static let enableLauncher = false          // opt-in; frees four-finger native gestures
        static let launcherActivationThreshold = 0.01   // same feather-light trigger as the switcher
        static let launcherStepDistance = 0.04     // one item per ~4% travel; also Files depth/highlight
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
        static let clipboardPinDistance = 0.22     // deliberate horizontal flick to pin / leave (≈3 item steps)
        static let clipboardExcludedApps: [String] = []
        static let aiCommandsEnabled = false       // opt-in; gates the AI band + model download/residency
        static let aiSelectedModelID: String? = nil  // nil = registry default model
        static let aiSelectedChatModelID: String? = nil  // nil = fleet/registry chat default
        static let aiEnabledCapabilityModelIDs: [String] = []  // no capability models enabled by default
        static let fullPotentialEnabled = false      // master gate; OFF → V2.5 ships calm (addendum §D1)
        static let cpuLaneEnabled = false            // sub-flag; OFF (heat/battery)
        static let batchedRuntimeEnabled = false     // sub-flag; OFF (RAM + latency)
        static let mediaGenEnabled = false           // sub-flag; OFF (evicts chat; minutes/clip; GB of weights)
        static let backgroundAutonomyEnabled = false // sub-flag; OFF (unattended action, audited)
        static let fleetCloudEscalationEnabled = false   // sub-flag; OFF ($ + network + data off-device)
        static let videoProvider: VideoProvider = .cloud   // honest default: hosted API, nothing downloaded
        static let mediaVideoBudgetPerDay = 3        // conservative cloud-video cap (rolling 24h); 0 disables
        static let aiCommandLanguages: [String: String] = [:]  // per-command remembered runtime language
        static let aiReasoningEnabled = true       // let the model think (filtered out of the result); gated by the AI opt-in
        static let agentContextPreset: AgentContextPreset = .balanced   // comfortable mid context, the default
        static let agentContextTokens = 8_192      // Balanced; clamped to the model max at use
        static let agentCompactKV = false          // 8-bit KV off by default
        static let agentMaxParkedSessions = 6      // soft cap; evicts the least-recently-updated idle one
        static let agentParkIdleTimeout: TimeInterval = 30 * 60   // RETIRED (D1): legacy summarize-and-sleep
        static let agentParkAutoDismissCountdown: TimeInterval = 300   // 5 min idle → auto-dismiss forever (D1)
        static let agentOverscrollParkThreshold = 0.22            // above canvasResolveThreshold (0.12)
        static let flickVelocityThreshold = 0.8                   // peak normalized vel/sec; below = reading-scroll (D4, run-verify)
        static let flickLiftWindow = 0.12                         // seconds from last fast frame to lift (D4, run-verify)
        static let agentWhitelistPaths: [String] = []             // trust nothing arbitrary on a fresh install
        static let agentWhitelistCommands: [String] = []          // trust no command pattern on a fresh install
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
        static let filesLiftAction: FilesLiftAction = .deliver  // lift delivers the entry to the front app by default
        static let filesActionMenu = FilesActionMenu.default    // per-type menus exactly as specified
        static let filesToolsDisabled: [String] = []            // all detected terminals/editors enabled
        static let keyboardLanguageEnabled = false // opt-in; gates per-app input-source learn/apply (no re-login)
        static let keyboardLanguageDefaultSourceID = ""  // "" = no global default (pure learn-as-you-go)
        // Per-host memory inside browsers rides along by default when the keyboard-language master
        // opt-in is enabled: the default (Accessibility) host reader needs NO new permission, so the
        // soft path costs nothing — only the Apple-Events "allow browser control" reader stays a
        // deliberate opt-in below. The feature is still fully inert until the MASTER toggle is on.
        static let keyboardLanguagePerSiteEnabled = true
        static let keyboardLanguageAllowBrowserControl = false   // opt-in; Apple Events host reader (per-browser permission)
        static let showDockPreviews = false        // opt-in; Dock-hover window previews (no re-login, no new permission)
        static let commandTabSwitcher = false      // opt-in; drive the switcher from ⌘-Tab (no re-login, no new permission)
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
        static let aiCommandsEnabled = "aiCommandsEnabled"
        static let aiSelectedModelID = "aiSelectedModelID"
        static let aiSelectedChatModelID = "aiSelectedChatModelID"
        static let aiEnabledCapabilityModelIDs = "aiEnabledCapabilityModelIDs"
        static let fullPotentialEnabled = "fullPotentialEnabled"
        static let cpuLaneEnabled = "cpuLaneEnabled"
        static let batchedRuntimeEnabled = "batchedRuntimeEnabled"
        static let mediaGenEnabled = "mediaGenEnabled"
        static let backgroundAutonomyEnabled = "backgroundAutonomyEnabled"
        static let fleetCloudEscalationEnabled = "fleetCloudEscalationEnabled"
        static let videoProvider = "videoProvider"
        static let mediaVideoBudgetPerDay = "mediaVideoBudgetPerDay"
        static let aiCommandLanguages = "aiCommandLanguages"
        static let aiReasoningEnabled = "aiReasoningEnabled"
        static let agentContextPreset = "agentContextPreset"
        static let agentContextTokens = "agentContextTokens"
        static let agentCompactKV = "agentCompactKV"
        static let agentMaxParkedSessions = "agentMaxParkedSessions"
        static let agentParkIdleTimeout = "agentParkIdleTimeout"
        static let agentParkAutoDismissCountdown = "agentParkAutoDismissCountdown"
        static let agentOverscrollParkThreshold = "agentOverscrollParkThreshold"
        static let flickVelocityThreshold = "flickVelocityThreshold"
        static let flickLiftWindow = "flickLiftWindow"
        static let agentWhitelistPaths = "agentWhitelistPaths"
        static let agentWhitelistCommands = "agentWhitelistCommands"
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
        static let filesLiftAction = "filesLiftAction"
        static let filesActionMenu = "filesActionMenu"
        static let filesToolsDisabled = "filesToolsDisabled"
        static let keyboardLanguageEnabled = "keyboardLanguageEnabled"
        static let keyboardLanguageDefaultSourceID = "keyboardLanguageDefaultSourceID"
        static let keyboardLanguagePerSiteEnabled = "keyboardLanguagePerSiteEnabled"
        static let keyboardLanguageAllowBrowserControl = "keyboardLanguageAllowBrowserControl"
        static let showDockPreviews = "showDockPreviews"
        static let commandTabSwitcher = "commandTabSwitcher"
    }
}
