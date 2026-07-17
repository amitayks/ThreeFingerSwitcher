import Foundation

/// Output #1 — the generated-media GALLERY (design D6). A finished `MediaAsset.url` is written under a
/// dedicated, local-only, recoverable gallery root and surfaces as an ordinary Files-band `.fileEntry`
/// (reuse the band; do NOT build a new browser). The gallery honors the band's non-destructive scope: no
/// permanent delete, no overwrite (each asset is a uniquely-named file).
///
/// MLX-free Core. The writer touches `FileManager` (that's the boundary where an OS failure maps to
/// `MediaError.outputWriteFailed`); the `.fileEntry` mapping is pure.
public protocol MediaGalleryWriting: Sendable {
    /// Persist `bytes` for a finished generation under the gallery root and return the asset that
    /// references the written file. Throws `MediaError.outputWriteFailed` (OS reason in details) on
    /// failure — never a partial/false success.
    func write(_ bytes: Data, kind: MediaKind, width: Int, height: Int, durationMs: Int?) throws -> MediaAsset

    /// The gallery root (so the Files band can list it). Local-only.
    var root: URL { get }
}

/// The on-disk gallery writer. The root defaults under Application Support (local-only, survives relaunch,
/// recoverable). Each asset gets a fresh UUID filename so a write NEVER overwrites an existing asset
/// (non-destructive scope, design D6). The file extension follows the kind (PNG image / MP4 video).
public struct MediaGallery: MediaGalleryWriting {
    public let root: URL
    private let fileManager: FileManager

    /// The default gallery root under Application Support: `…/ThreeFingerSwitcher/GeneratedMedia`.
    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false))
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("ThreeFingerSwitcher", isDirectory: true)
                   .appendingPathComponent("GeneratedMedia", isDirectory: true)
    }

    public init(root: URL? = nil, fileManager: FileManager = .default) {
        self.root = root ?? MediaGallery.defaultRoot(fileManager: fileManager)
        self.fileManager = fileManager
    }

    public func write(_ bytes: Data, kind: MediaKind, width: Int, height: Int,
                      durationMs: Int?) throws -> MediaAsset {
        let id = UUID()
        let ext = MediaGallery.fileExtension(for: kind)
        let url = root.appendingPathComponent("\(id.uuidString).\(ext)", isDirectory: false)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            // `.atomic` so a crash mid-write never leaves a half-file in the gallery listing.
            try bytes.write(to: url, options: .atomic)
        } catch {
            // Map the FileManager/OS error at the boundary into the taxonomy (design D10). The raw OS
            // reason rides in copyable details, never the headline.
            throw MediaError.outputWriteFailed(detail: String(describing: error))
        }
        return MediaAsset(id: id, url: url, kind: kind, width: width, height: height, durationMs: durationMs)
    }

    /// The file extension for a kind. Images are PNG (the seam normalizes to PNG); video is MP4 (the
    /// container the backends produce). Pure helper.
    public static func fileExtension(for kind: MediaKind) -> String {
        switch kind {
        case .image: return "png"
        case .video: return "mp4"
        }
    }
}

// MARK: - .fileEntry mapping (output #1, §5.2)

extension MediaAsset {
    /// Map a gallery asset to a Files-band `FileEntry` — an ordinary entry the band lists, opens,
    /// opens-with, and delivers (no new browser). Identity is the asset's PATH (via `FileEntry.init`,
    /// which derives `id` from the standardized path), so re-listing the gallery never strobes the
    /// highlight (design D6 / the band's path-stable identity rule).
    func fileEntry(modificationDate: Date? = nil) -> FileEntry {
        FileEntry(url: url,
                  name: url.lastPathComponent,
                  isDirectory: false,
                  modificationDate: modificationDate,
                  kind: kind.fileKind)
    }
}

extension MediaKind {
    /// The Files-band `FileKind` row-glyph classification for this media kind.
    var fileKind: FileKind {
        switch self {
        case .image: return .image
        case .video: return .video
        }
    }
}
