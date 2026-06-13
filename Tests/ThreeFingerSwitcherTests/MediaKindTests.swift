import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for `MediaKind.classify` (spec media-player: "Media-kind classification routes the open"):
/// video/audio/image/non-media classification by extension+UTI, the deterministic edge case (`.mkv`,
/// which macOS may not register a `.movie`-conforming UTType for but the player must still route to the
/// video path so the libmpv fallback can offer), and directories.
final class MediaKindTests: XCTestCase {

    private func entry(_ path: String, isDirectory: Bool = false) -> FileEntry {
        let url = URL(fileURLWithPath: path)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: isDirectory,
                         modificationDate: nil, kind: isDirectory ? .folder : .other)
    }

    func testCommonVideoExtensionsClassifyAsVideo() {
        for ext in ["mp4", "mov", "m4v", "avi", "webm", "wmv"] {
            XCTAssertEqual(MediaKind.classify(entry("/movies/clip.\(ext)")), .video, "\(ext)")
        }
    }

    func testCommonAudioExtensionsClassifyAsAudio() {
        for ext in ["mp3", "m4a", "aac", "wav", "flac", "aiff"] {
            XCTAssertEqual(MediaKind.classify(entry("/music/song.\(ext)")), .audio, "\(ext)")
        }
    }

    func testCommonImageExtensionsClassifyAsImage() {
        for ext in ["png", "jpg", "jpeg", "gif", "heic", "tiff"] {
            XCTAssertEqual(MediaKind.classify(entry("/pics/photo.\(ext)")), .image, "\(ext)")
        }
    }

    func testMkvEdgeCaseRoutesToVideoDeterministically() {
        // .mkv is the case AVFoundation can't decode — it must still classify as video so the player
        // opens and the libmpv fallback can be offered. The explicit allowlist makes this host-independent.
        XCTAssertEqual(MediaKind.classify(entry("/movies/show.mkv")), .video)
    }

    func testNonMediaFilesClassifyAsNil() {
        for ext in ["pdf", "txt", "docx", "zip", "swift", ""] {
            XCTAssertNil(MediaKind.classify(entry("/docs/file.\(ext)")), "\(ext)")
        }
    }

    func testDirectoryIsNeverMedia() {
        XCTAssertNil(MediaKind.classify(entry("/some/folder", isDirectory: true)))
        // Even a directory named like a movie is not media.
        XCTAssertNil(MediaKind.classify(entry("/some/bundle.mov", isDirectory: true)))
    }

    func testCaseInsensitiveExtensions() {
        XCTAssertEqual(MediaKind.classify(entry("/movies/CLIP.MP4")), .video)
        XCTAssertEqual(MediaKind.classify(entry("/pics/PHOTO.JPG")), .image)
    }
}
