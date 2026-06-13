import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for `PlayerController` — the integration brain — against `StubPlaybackEngine` + a fake surface:
/// the open/dismiss lifecycle (recognizer `playerActive` toggled, surface shown/hidden), per-file resume,
/// dismiss persists state, and the action-menu open / highlight-move / select flow.
@MainActor
final class PlayerControllerTests: XCTestCase {

    private final class FakeSurface: PlayerSurfacing {
        private(set) var shown = 0
        private(set) var hidden = 0
        private(set) var lastMenu: [PlayerActionMenuItem]?
        private(set) var lastHighlight: Int?
        private(set) var heldZones: [(Int, Int)] = []
        func showPlayer(model: PlayerTransportModel, kind: MediaKind) { shown += 1 }
        func setActionMenu(_ items: [PlayerActionMenuItem]?, highlight: Int?) { lastMenu = items; lastHighlight = highlight }
        func setHeldZone(dx: Int, dy: Int) { heldZones.append((dx, dy)) }
        func hidePlayer() { hidden += 1 }
    }

    private final class Flags {
        var active = false
        var menuOpen = false
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!)
    }

    private func tempStore() -> PlaybackStateStore {
        PlaybackStateStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-pc-\(UUID().uuidString)", isDirectory: true))
    }

    private func entry(_ path: String) -> FileEntry {
        let url = URL(fileURLWithPath: path)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: false, modificationDate: nil, kind: .video)
    }

    /// Build a controller whose engine factory hands out (and retains, for assertions) a stub engine.
    private func makeController(settings: AppSettings, store: PlaybackStateStore,
                                surface: FakeSurface, flags: Flags,
                                engineBox: @escaping (StubPlaybackEngine) -> Void,
                                audioTracks: [MediaTrack] = [],
                                metadata: @escaping (URL) -> (size: Int64, modificationDate: Date?) = { _ in (1000, nil) })
    -> PlayerController {
        PlayerController(
            settings: settings,
            store: store,
            availableEngines: [.avFoundation, .libmpv],
            makeEngine: { kind in
                let e = StubPlaybackEngine(kind: kind, status: PlaybackStatus(duration: 100),
                                           audioTracks: audioTracks, nextLoadOutcome: .success)
                engineBox(e)
                return e
            },
            surface: surface,
            fileMetadata: metadata,
            setPlayerActive: { flags.active = $0 },
            setPlayerMenuOpen: { flags.menuOpen = $0 })
    }

    func testPlayShowsSurfaceAndOwnsTheTrackpad() async {
        let surface = FakeSurface(); let flags = Flags()
        let controller = makeController(settings: makeSettings(), store: tempStore(),
                                        surface: surface, flags: flags, engineBox: { _ in })
        await controller.play(entry("/movies/clip.mp4"), kind: .video)
        XCTAssertEqual(surface.shown, 1, "the surface is presented")
        XCTAssertTrue(flags.active, "the player owns the trackpad (recognizer playerActive = true)")
        XCTAssertEqual(controller.model?.state, .playing)
    }

    func testDismissPersistsHidesAndReleasesTrackpad() async {
        let surface = FakeSurface(); let flags = Flags(); let store = tempStore()
        var engine: StubPlaybackEngine?
        let controller = makeController(settings: makeSettings(), store: store,
                                        surface: surface, flags: flags, engineBox: { engine = $0 })
        let e = entry("/movies/clip.mp4")
        await controller.play(e, kind: .video)
        engine?.seek(to: 42)        // simulate having watched to 0:42
        controller.dismiss()

        XCTAssertEqual(surface.hidden, 1, "the surface is torn down")
        XCTAssertFalse(flags.active, "the trackpad is released")
        // State was persisted at the watched position.
        let saved = store.state(forPath: e.path, size: 1000, modificationDate: nil)
        XCTAssertEqual(saved?.resumePosition ?? -1, 42, accuracy: 0.001)
    }

    func testReopenResumesFromSavedPosition() async {
        let store = tempStore()
        let date = Date(timeIntervalSince1970: 1000)
        store.record(path: "/movies/clip.mp4",
                     state: PlaybackState(resumePosition: 50, duration: 100, audioTrackID: nil,
                                          subtitleTrackID: nil, volume: 1, rate: 1,
                                          lastOpened: date, fileSize: 1000, modificationDate: date))
        var engine: StubPlaybackEngine?
        let controller = makeController(settings: makeSettings(), store: store,
                                        surface: FakeSurface(), flags: Flags(), engineBox: { engine = $0 },
                                        metadata: { _ in (1000, date) })
        await controller.play(entry("/movies/clip.mp4"), kind: .video)
        XCTAssertEqual(engine?.seekPositions.first, 50, "playback resumes at the saved position")
    }

    func testActionMenuOpenHighlightAndSelect() async {
        let surface = FakeSurface(); let flags = Flags()
        let audio = [MediaTrack(id: "a1", kind: .audio, label: "English"),
                     MediaTrack(id: "a2", kind: .audio, label: "Commentary")]
        var engine: StubPlaybackEngine?
        let controller = makeController(settings: makeSettings(), store: tempStore(),
                                        surface: surface, flags: flags, engineBox: { engine = $0 },
                                        audioTracks: audio)
        await controller.play(entry("/movies/clip.mp4"), kind: .video)

        controller.openActionMenu()
        XCTAssertTrue(controller.menuOpen)
        XCTAssertTrue(flags.menuOpen, "recognizer is told the menu is open (a lift then selects)")
        XCTAssertNotNil(surface.lastMenu)

        // A vertical step while the menu is open moves the highlight (does NOT change volume).
        controller.volume(1)
        XCTAssertEqual(controller.menuHighlight, 1)

        // Lifting selects the highlighted row and closes the menu.
        controller.selectMenuItem()
        XCTAssertFalse(controller.menuOpen)
        XCTAssertFalse(flags.menuOpen)
        XCTAssertEqual(engine?.selectedTracks.count, 1, "the highlighted track was applied to the engine")
    }

    func testImageHasNoActionMenu() async {
        let surface = FakeSurface(); let flags = Flags()
        let controller = makeController(settings: makeSettings(), store: tempStore(),
                                        surface: surface, flags: flags, engineBox: { _ in })
        await controller.play(entry("/pics/photo.heic"), kind: .image)
        controller.openActionMenu()
        XCTAssertFalse(controller.menuOpen, "an image has no timeline/track rows, so no menu opens")
    }
}
