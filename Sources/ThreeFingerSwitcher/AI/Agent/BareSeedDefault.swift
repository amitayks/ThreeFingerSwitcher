import Foundation

/// The seed's nature, derived from a command's `InputSource` (design D6). The conversational canvas needs
/// only the text-vs-image distinction to pick a sane default question for a bare seed, so this collapses
/// the five input sources into the two that matter for the default.
enum SeedKind: Equatable, Sendable {
    case text
    case image

    /// Map an `InputSource` to its seed kind: the two image sources (`clipboardImage` / `screenRegion`)
    /// are `.image`; everything else (`selection` / `clipboard` / `none`) is `.text`. Pure + deterministic.
    static func from(_ source: InputSource) -> SeedKind {
        switch source {
        case .clipboardImage, .screenRegion: return .image
        case .selection, .clipboard, .none: return .text
        }
    }
}

/// The pure resolver for a **bare seed** — "send just the copied text/image with no question" (design D6).
/// A bare seed must still be a valid turn 1, never an empty model call, so the canvas folds this default
/// question with the seed exactly as a preset instruction is folded. Pure, `nonisolated`, deterministic,
/// string-stable (so it is `swift test`-able off the main actor). NOT persisted or user-editable in this
/// slice — a per-command editable default is a documented future preference, not built here.
enum BareSeedDefault {
    /// The default question used when a bare seed is sent with no typed question. An **image** seed asks
    /// the model to describe / identify it; a **text** seed asks for a brief summary / explanation.
    static func question(for seed: SeedKind) -> String {
        switch seed {
        case .image: return "Describe this image. What is it?"
        case .text: return "Summarize this. Explain it briefly."
        }
    }
}
