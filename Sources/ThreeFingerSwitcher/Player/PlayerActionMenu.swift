import Foundation

/// One row in the player's scrubbable action menu (`media-player` spec: "Scrubbable action menu for
/// track, speed, loop, and engine controls"). Raised by the relative +1-finger posture and resolved by
/// lifting on a row (the Open-With picker pattern). Pure value type — the recognizer/controller act on
/// `action`; the view renders `label`.
struct PlayerActionMenuItem: Equatable, Identifiable {
    enum Action: Equatable {
        case selectAudioTrack(MediaTrack)
        case selectSubtitleTrack(MediaTrack)
        case subtitlesOff
        case setRate(Double)
        case toggleLoop
        case selectChapter(index: Int)
        case openInEngine(PlaybackEngineKind)
    }
    let id: String
    let label: String
    let action: Action
    /// True when this row reflects the current selection (so the view can mark it).
    let isCurrent: Bool
}

/// Builds the contextual action-menu rows for the current media kind + engine capabilities, omitting rows
/// that don't apply (e.g. no audio/subtitle/speed for an image; no "open in libmpv" when libmpv isn't an
/// available alternative). Pure and testable.
enum PlayerActionMenu {
    /// The standard speed choices offered for video/audio.
    static let standardSpeeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func items(kind: MediaKind,
                      audioTracks: [MediaTrack],
                      subtitleTracks: [MediaTrack],
                      chapters: [String],
                      currentEngine: PlaybackEngineKind,
                      availableEngines: Set<PlaybackEngineKind>,
                      speeds: [Double] = standardSpeeds,
                      currentRate: Double = 1.0,
                      currentAudioTrackID: String? = nil,
                      currentSubtitleTrackID: String? = nil,
                      loopEnabled: Bool = false) -> [PlayerActionMenuItem] {
        var items: [PlayerActionMenuItem] = []

        // Images have no timeline-based transport — only the engine override (and nothing else) applies.
        if kind != .image {
            for track in audioTracks {
                items.append(PlayerActionMenuItem(
                    id: "audio:\(track.id)", label: "Audio: \(track.label)",
                    action: .selectAudioTrack(track),
                    isCurrent: track.id == currentAudioTrackID))
            }
            if !subtitleTracks.isEmpty {
                items.append(PlayerActionMenuItem(
                    id: "sub:off", label: "Subtitles: Off",
                    action: .subtitlesOff,
                    isCurrent: currentSubtitleTrackID == nil))
                for track in subtitleTracks {
                    items.append(PlayerActionMenuItem(
                        id: "sub:\(track.id)", label: "Subtitles: \(track.label)",
                        action: .selectSubtitleTrack(track),
                        isCurrent: track.id == currentSubtitleTrackID))
                }
            }
            for speed in speeds {
                items.append(PlayerActionMenuItem(
                    id: "rate:\(speed)", label: "Speed: \(formatSpeed(speed))",
                    action: .setRate(speed),
                    isCurrent: abs(speed - currentRate) < 0.001))
            }
            items.append(PlayerActionMenuItem(
                id: "loop", label: loopEnabled ? "Loop: On" : "Loop: Off",
                action: .toggleLoop, isCurrent: loopEnabled))
            for (i, title) in chapters.enumerated() {
                items.append(PlayerActionMenuItem(
                    id: "chapter:\(i)", label: "Chapter: \(title)",
                    action: .selectChapter(index: i), isCurrent: false))
            }
        }

        // "Open in <alternative engine>" — offered only when the alternative is an available engine
        // (libmpv applies to video/audio, not images).
        if kind != .image {
            let alternative: PlaybackEngineKind = (currentEngine == .avFoundation) ? .libmpv : .avFoundation
            if alternative != currentEngine, availableEngines.contains(alternative) {
                items.append(PlayerActionMenuItem(
                    id: "engine:\(alternative.rawValue)", label: "Open in \(alternative.displayName)",
                    action: .openInEngine(alternative), isCurrent: false))
            }
        }

        return items
    }

    private static func formatSpeed(_ s: Double) -> String {
        s == s.rounded() ? String(format: "%.0f×", s) : String(format: "%g×", s)
    }
}
