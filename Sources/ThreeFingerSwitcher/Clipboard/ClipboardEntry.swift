import Foundation

/// The clipboard-history data model.
///
/// Like `LaunchItem`, everything here is a pure value type with **no AppKit/SwiftUI dependency**, so
/// the store's de-dup / retention / ordering logic is `Codable` and unit-testable without a running
/// app or a live pasteboard. Turning an `NSPasteboard` snapshot into a `ClipboardEntry` (and an entry
/// back onto the pasteboard) lives in the AppKit layer (`ClipboardMonitor` / the paste path).

/// What kind of content an entry holds — drives the key derivation and the value-preview renderer.
enum ClipboardKind: String, Codable, Equatable, CaseIterable {
    case text          // plain (or styled) text
    case richText      // text with an RTF representation alongside plain
    case image         // image data with no backing file (paste restores the bytes)
    case file          // a file-URL reference (paste restores the reference, not a byte copy)
    case color         // a color value
    case url           // a web/app URL
}

/// One stored representation's bytes: kept **inline** for small payloads (text, color, url, rtf) or
/// as a **blob** file (large payloads: image bytes, cached thumbnails) under the store's blob dir.
/// The in-memory entries the band/preview/paste use always carry `.inline` (the store materializes
/// blobs on load); `.blob` exists only in the on-disk index.
enum ClipboardPayload: Equatable {
    case inline(Data)
    case blob(String)   // blob file name, relative to the store's blob directory

    /// The inline bytes if materialized; nil for an unresolved blob reference.
    var inlineData: Data? { if case let .inline(d) = self { return d }; return nil }
}

extension ClipboardPayload: Codable {
    private enum CodingKeys: String, CodingKey { case inline, blob }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let data = try c.decodeIfPresent(Data.self, forKey: .inline) {
            self = .inline(data)
        } else {
            self = .blob(try c.decode(String.self, forKey: .blob))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inline(let d): try c.encode(d, forKey: .inline)
        case .blob(let name): try c.encode(name, forKey: .blob)
        }
    }
}

/// Where an entry came from — a *device* provenance, distinct from `sourceApp` (the app that made a
/// local copy). Additive and backward-compatible: it is optional on `ClipboardEntry`, so an index
/// persisted before this existed loads with `origin == nil` (treated as local). Local pasteboard
/// capture leaves it unset; an item received over the device link is stamped `.peer`.
enum ClipboardOrigin: Codable, Equatable {
    case local
    case peer(deviceName: String?)
}

/// A single recorded clipboard item: stable identity + when/where it was copied + the kind + the
/// representations needed for a faithful re-paste + a derived single-line `key` for the list column.
struct ClipboardEntry: Codable, Equatable, Identifiable {
    var id: UUID
    /// When the copy was recorded (drives recency ordering).
    var capturedAt: Date
    var kind: ClipboardKind
    /// Short single-line label shown in the key column (already trimmed to one line; the view may
    /// truncate further). Derived at capture time so the model has no AppKit dependency.
    var key: String
    /// Bundle id of the application that made the copy, when known (for the exclusion list + display).
    var sourceApp: String?
    var pinned: Bool
    /// UTI string → payload. All representations captured for the copy; restored to the pasteboard on
    /// paste, and the richest previewable one drives the value preview.
    var representations: [String: ClipboardPayload]
    /// Stable content fingerprint used for de-duplication (two copies with the same fingerprint are
    /// the same entry). Derived from the canonical representation at capture time.
    var fingerprint: String
    /// Device provenance. Optional + additive: `nil` (absent in legacy indexes) and `.local` both mean
    /// "captured on this Mac"; `.peer` means it arrived over the device link. See `isPeer`.
    var origin: ClipboardOrigin?

    init(id: UUID = UUID(),
         capturedAt: Date,
         kind: ClipboardKind,
         key: String,
         sourceApp: String? = nil,
         pinned: Bool = false,
         representations: [String: ClipboardPayload],
         fingerprint: String,
         origin: ClipboardOrigin? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.key = key
        self.sourceApp = sourceApp
        self.pinned = pinned
        self.representations = representations
        self.fingerprint = fingerprint
        self.origin = origin
    }

    /// The originating device name when this came from a paired device, else nil. Reads `nil`/`.local`
    /// origin as not-a-peer (centralizes the "absent == local" convention).
    var peerDeviceName: String? {
        if case let .peer(name) = origin { return name }
        return nil
    }

    /// True when this entry was received from a paired device (not a local copy).
    var isPeer: Bool {
        if case .peer = origin { return true }
        return false
    }

    // MARK: Convenience accessors (used by the preview + paste paths)

    /// Inline bytes for a representation UTI, if present and materialized.
    func data(for uti: String) -> Data? { representations[uti]?.inlineData }

    /// Approximate byte size of this entry's inline payloads (drives the byte-cap retention).
    var inlineByteSize: Int {
        representations.values.reduce(0) { $0 + ($1.inlineData?.count ?? 0) }
    }
}

/// Well-known pasteboard UTIs the recorder/paste path use. Kept as plain strings so the model stays
/// AppKit-free (the AppKit layer maps these to `NSPasteboard.PasteboardType`).
enum ClipboardUTI {
    static let plainText = "public.utf8-plain-text"
    static let rtf = "public.rtf"
    static let png = "public.png"
    static let tiff = "public.tiff"
    static let fileURL = "public.file-url"
    static let url = "public.url"
    static let color = "com.apple.cocoa.pasteboard.color"
}

/// Derives the single-line `key` for an entry. Pure (testable): no AppKit, no pasteboard.
enum ClipboardKey {
    /// Collapse to the first non-empty line, trimmed, capped to `maxLength` with an ellipsis.
    static func fromText(_ text: String, maxLength: Int = 80) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    static func fromFile(_ url: URL) -> String { url.lastPathComponent }

    static func fromImage(width: Int, height: Int) -> String { "Image \(width)×\(height)" }
}
