import Foundation
import UniformTypeIdentifiers

/// A coarse classification of a file into the three media kinds the built-in player handles
/// (`media-player` spec: "Media-kind classification routes the open"). Pure and side-effect-free —
/// it reads only the file's name/extension and (as a generalizing fallback) its `UTType`, never the
/// filesystem or an engine — so the open-routing branch and the per-kind Hub toggles share one
/// testable predicate. The *decode* check (can this engine actually play it) happens later, as the
/// AVFoundation→libmpv fallback trigger; classification deliberately routes a file to the player even
/// when AVFoundation can't decode it (e.g. `.mkv`), so the fallback can offer libmpv.
enum MediaKind: String, Codable, Equatable, CaseIterable {
    case video
    case audio
    case image

    /// Classify a Files-band entry, or `nil` for a directory / non-media file.
    static func classify(_ entry: FileEntry) -> MediaKind? {
        entry.isDirectory ? nil : classify(fileURL: entry.url)
    }

    /// Classify a file URL by extension first (a deterministic, host-independent allowlist that covers
    /// the common containers — including ones macOS may not register a `.movie`-conforming `UTType`
    /// for, like `.mkv`), then by `UTType` conformance as the generalizing fallback. Returns `nil` for
    /// anything that is not video, audio, or an image.
    static func classify(fileURL url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            if Self.videoExtensions.contains(ext) { return .video }
            if Self.audioExtensions.contains(ext) { return .audio }
            if Self.imageExtensions.contains(ext) { return .image }
        }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    // MARK: - Deterministic extension allowlists (host-independent, so classification unit-tests don't
    // depend on which UTIs the running machine happens to have registered).

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv",
        "mpg", "mpeg", "ts", "m2ts", "3gp", "3g2", "ogv", "vob", "mts", "divx"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus",
        "aiff", "aif", "aifc", "wma", "alac", "ape", "wv", "caf"
    ]
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp",
        "tiff", "tif", "svg", "raw", "dng", "cr2", "nef", "arw", "ico", "avif"
    ]
}
