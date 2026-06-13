import Foundation

/// The player surface the controller drives (`media-player` spec: "Non-activating, full-screen,
/// gesture-driven player surface"). A protocol so `PlayerController` — the integration brain — is unit-
/// testable against a fake, while the real `PlayerOverlayController` (the non-activating panel + SwiftUI
/// `PlayerView`) lives behind it. Mirrors how `FileOpenService` and the AI executor keep their AppKit
/// surfaces injectable.
@MainActor
protocol PlayerSurfacing: AnyObject {
    /// Present the player for `model` (a `kind`-specific layout: images omit the timeline).
    func showPlayer(model: PlayerTransportModel, kind: MediaKind)
    /// Show (`items` non-nil, with the `highlight` row) or hide (`nil`) the scrubbable action menu.
    func setActionMenu(_ items: [PlayerActionMenuItem]?, highlight: Int?)
    /// The current per-axis held-in-zone sign, for the surface to drive eased auto-repeat of seek/volume.
    func setHeldZone(dx: Int, dy: Int)
    /// Tear down the surface (synchronously, so a Space-switching dismiss leaves no ghost).
    func hidePlayer()
}

/// Owns the live player session: opening a media file, routing the recognizer's transport intents into
/// the `PlayerTransportModel`, the scrubbable action-menu state, and per-file resume persistence. Engine-
/// agnostic — it drives playback only through the `MediaPlaybackEngine` seam (built by an injected
/// factory), so it verifies against `StubPlaybackEngine` with no media framework linked.
///
/// `AppCoordinator` forwards the recognizer's `player…` delegate calls here; this controller flips the
/// recognizer's `playerActive` / `playerMenuOpen` (via injected hooks) so the player owns the trackpad
/// while open and a lift selects an open menu row.
@MainActor
final class PlayerController {
    private let settings: AppSettings
    private let store: PlaybackStateStore
    private let availableEngines: Set<PlaybackEngineKind>
    private let makeEngine: (PlaybackEngineKind) -> MediaPlaybackEngine?
    /// Strong: the controller owns its surface; the surface never holds the controller back (intents are
    /// forwarded to the controller by `AppCoordinator`, not via the surface), so there is no retain cycle.
    private let surface: PlayerSurfacing
    /// Reads a file's size + modification date for the resume identity tiebreak. Injected so tests don't
    /// touch the filesystem; production reads `FileManager` resource values.
    private let fileMetadata: (URL) -> (size: Int64, modificationDate: Date?)
    /// Flip the recognizer's `playerActive` (the player owns the trackpad while open).
    private let setPlayerActive: (Bool) -> Void
    /// Flip the recognizer's `playerMenuOpen` (a lift then selects the highlighted menu row).
    private let setPlayerMenuOpen: (Bool) -> Void
    /// Clock for `lastOpened`, injected for deterministic tests.
    private let now: () -> Date

    private(set) var model: PlayerTransportModel?
    private var currentEntry: FileEntry?
    private var currentKind: MediaKind = .video

    // Action-menu state (kept here so it's testable; the surface just renders what it's handed).
    private(set) var menuOpen = false
    private(set) var menuItems: [PlayerActionMenuItem] = []
    private(set) var menuHighlight = 0

    init(settings: AppSettings,
         store: PlaybackStateStore,
         availableEngines: Set<PlaybackEngineKind>,
         makeEngine: @escaping (PlaybackEngineKind) -> MediaPlaybackEngine?,
         surface: PlayerSurfacing,
         fileMetadata: @escaping (URL) -> (size: Int64, modificationDate: Date?) = PlayerController.defaultMetadata,
         setPlayerActive: @escaping (Bool) -> Void,
         setPlayerMenuOpen: @escaping (Bool) -> Void,
         now: @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.store = store
        self.availableEngines = availableEngines
        self.makeEngine = makeEngine
        self.surface = surface
        self.fileMetadata = fileMetadata
        self.setPlayerActive = setPlayerActive
        self.setPlayerMenuOpen = setPlayerMenuOpen
        self.now = now
    }

    /// Production metadata reader: size + modification date via `FileManager`.
    static func defaultMetadata(_ url: URL) -> (size: Int64, modificationDate: Date?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0), values?.contentModificationDate)
    }

    // MARK: - Lifecycle

    /// Open `entry` (a `kind` media file) in the player, resuming where the user left off if applicable.
    func play(_ entry: FileEntry, kind: MediaKind) async {
        currentEntry = entry
        currentKind = kind
        closeMenuState()

        let config = PlayerTransportModel.Config(
            seekStep: settings.playerSeekStep,
            volumeStep: settings.playerVolumeStep,
            resumeThreshold: settings.playerResumeThreshold,
            nearEndMargin: settings.playerNearEndMargin)
        let model = PlayerTransportModel(config: config,
                                         defaultEngine: settings.playerDefaultEngine,
                                         availableEngines: availableEngines,
                                         makeEngine: makeEngine)
        self.model = model

        let resumeAt = resumePosition(for: entry)
        surface.showPlayer(model: model, kind: kind)
        setPlayerActive(true)
        await model.start(url: entry.url, name: entry.name, kind: kind, resumeAt: resumeAt)
    }

    /// Tear down the player: persist resume state, stop the engine, hide the surface, and release the
    /// trackpad. NOT a failure — a dismiss never records a `.failed` state.
    func dismiss() {
        persistState()
        model?.dismiss()
        surface.hidePlayer()
        setPlayerActive(false)
        closeMenuState()
        model = nil
        currentEntry = nil
    }

    // MARK: - Transport intents (forwarded from the recognizer via AppCoordinator)

    func seek(_ direction: Int) { model?.seek(direction) }

    /// Vertical step: move the menu highlight while the action menu is open, else change volume.
    func volume(_ direction: Int) {
        if menuOpen {
            moveMenuHighlight(direction)
        } else {
            model?.adjustVolume(direction)
        }
    }

    func togglePlayPause() { model?.togglePlayPause() }

    func heldZone(dx: Int, dy: Int) { surface.setHeldZone(dx: dx, dy: dy) }

    // MARK: - Action menu

    /// Raise the scrubbable action menu for the current media. No-op (menu stays closed) when there is
    /// nothing applicable to show (e.g. an image with no tracks/speed).
    func openActionMenu() {
        guard let model else { return }
        let items = PlayerActionMenu.items(
            kind: currentKind,
            audioTracks: model.currentEngine?.audioTracks ?? [],
            subtitleTracks: model.currentEngine?.subtitleTracks ?? [],
            chapters: [],
            currentEngine: model.currentEngineKind,
            availableEngines: availableEngines,
            currentRate: model.status.rate,
            currentAudioTrackID: model.currentAudioTrackID,
            currentSubtitleTrackID: model.currentSubtitleTrackID)
        guard !items.isEmpty else { return }
        menuItems = items
        menuHighlight = 0
        menuOpen = true
        setPlayerMenuOpen(true)
        surface.setActionMenu(items, highlight: menuHighlight)
    }

    /// Select the highlighted menu row (a lift while the menu is open): apply it and close the menu.
    func selectMenuItem() {
        guard menuOpen else { return }
        if menuItems.indices.contains(menuHighlight) {
            model?.apply(menuItems[menuHighlight].action)
        }
        closeMenu()
    }

    private func moveMenuHighlight(_ direction: Int) {
        guard menuOpen, !menuItems.isEmpty else { return }
        menuHighlight = max(0, min(menuItems.count - 1, menuHighlight + direction))
        surface.setActionMenu(menuItems, highlight: menuHighlight)
    }

    private func closeMenu() {
        closeMenuState()
        surface.setActionMenu(nil, highlight: nil)
    }

    private func closeMenuState() {
        menuOpen = false
        menuItems = []
        menuHighlight = 0
        setPlayerMenuOpen(false)
    }

    // MARK: - Resume persistence

    private func resumePosition(for entry: FileEntry) -> TimeInterval {
        let meta = fileMetadata(entry.url)
        guard let saved = store.state(forPath: entry.path, size: meta.size,
                                      modificationDate: meta.modificationDate) else { return 0 }
        return PlaybackStateStore.resumePosition(savedPosition: saved.resumePosition,
                                                 duration: saved.duration,
                                                 threshold: settings.playerResumeThreshold,
                                                 nearEndMargin: settings.playerNearEndMargin)
    }

    private func persistState() {
        guard let entry = currentEntry, let model else { return }
        let meta = fileMetadata(entry.url)
        let state = PlaybackState(resumePosition: model.status.position,
                                  duration: model.status.duration,
                                  audioTrackID: model.currentAudioTrackID,
                                  subtitleTrackID: model.currentSubtitleTrackID,
                                  volume: model.status.volume,
                                  rate: model.status.rate,
                                  lastOpened: now(),
                                  fileSize: meta.size,
                                  modificationDate: meta.modificationDate)
        store.record(path: entry.path, state: state)
    }
}
