import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure action-menu model (spec media-player: "Scrubbable action menu"): video shows
/// track/subtitle/speed/loop + "open in libmpv"; an image omits all timeline rows; "open in libmpv" is
/// hidden when libmpv isn't an available alternative.
final class PlayerActionMenuTests: XCTestCase {

    private let audio = [MediaTrack(id: "a1", kind: .audio, label: "English"),
                         MediaTrack(id: "a2", kind: .audio, label: "Commentary")]
    private let subs = [MediaTrack(id: "s1", kind: .subtitle, label: "English")]

    func testVideoMenuHasTracksSpeedLoopAndEngine() {
        let items = PlayerActionMenu.items(kind: .video,
                                           audioTracks: audio, subtitleTracks: subs, chapters: [],
                                           currentEngine: .avFoundation,
                                           availableEngines: [.avFoundation, .libmpv])
        let actions = items.map(\.action)
        XCTAssertTrue(actions.contains(.selectAudioTrack(audio[0])))
        XCTAssertTrue(actions.contains(.subtitlesOff))
        XCTAssertTrue(actions.contains(.selectSubtitleTrack(subs[0])))
        XCTAssertTrue(actions.contains(.setRate(1.5)))
        XCTAssertTrue(actions.contains(.toggleLoop))
        XCTAssertTrue(actions.contains(.openInEngine(.libmpv)))
    }

    func testImageMenuOmitsTimelineRows() {
        let items = PlayerActionMenu.items(kind: .image,
                                           audioTracks: audio, subtitleTracks: subs, chapters: [],
                                           currentEngine: .avFoundation,
                                           availableEngines: [.avFoundation, .libmpv])
        for item in items {
            switch item.action {
            case .selectAudioTrack, .selectSubtitleTrack, .subtitlesOff, .setRate, .toggleLoop:
                XCTFail("image menu must omit timeline/track rows, found \(item.action)")
            default:
                break
            }
        }
    }

    func testOpenInLibmpvHiddenWhenUnavailable() {
        let items = PlayerActionMenu.items(kind: .video,
                                           audioTracks: audio, subtitleTracks: subs, chapters: [],
                                           currentEngine: .avFoundation,
                                           availableEngines: [.avFoundation])
        XCTAssertFalse(items.map(\.action).contains(.openInEngine(.libmpv)))
    }

    func testCurrentSelectionMarked() {
        let items = PlayerActionMenu.items(kind: .video,
                                           audioTracks: audio, subtitleTracks: subs, chapters: [],
                                           currentEngine: .avFoundation,
                                           availableEngines: [.avFoundation, .libmpv],
                                           currentRate: 1.5,
                                           currentAudioTrackID: "a2")
        let currentRate = items.first { $0.action == .setRate(1.5) }
        XCTAssertEqual(currentRate?.isCurrent, true)
        let currentAudio = items.first { $0.action == .selectAudioTrack(audio[1]) }
        XCTAssertEqual(currentAudio?.isCurrent, true)
    }
}
