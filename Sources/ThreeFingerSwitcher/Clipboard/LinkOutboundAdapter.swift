import Foundation
import DeviceLinkProtocol

/// The inverse of `LinkInboundAdapter`: turns a materialized `ClipboardEntry` into a wire `LinkItem`
/// for sending to a paired device. Non-file kinds carry their inline representation bytes verbatim;
/// a `.file` entry resolves its `file://` reference and sends the **file's bytes** (so the other device
/// receives content, not a meaningless local path). The item is stamped with the local device identity.
struct LinkOutboundAdapter {

    /// A generic content UTI used to carry a file's raw bytes on the wire.
    static let fileContentUTI = "public.data"

    func linkItem(from entry: ClipboardEntry, origin: DeviceIdentity, messageID: UUID = UUID()) throws -> LinkItem {
        let kind = Self.linkKind(for: entry.kind)

        if entry.kind == .file {
            guard let urlData = entry.data(for: ClipboardUTI.fileURL),
                  let url = URL(string: String(decoding: urlData, as: UTF8.self)), url.isFileURL else {
                throw LinkOutboundError.unreadableFile
            }
            let bytes: Data
            do { bytes = try Data(contentsOf: url) } catch { throw LinkOutboundError.unreadableFile }
            return LinkItem(messageID: messageID, kind: .file,
                            representations: [Self.fileContentUTI: bytes],
                            suggestedName: url.lastPathComponent,
                            capturedAt: entry.capturedAt, origin: origin)
        }

        var reps: [String: Data] = [:]
        for (uti, payload) in entry.representations {
            if let data = payload.inlineData { reps[uti] = data }
        }
        guard !reps.isEmpty else { throw LinkOutboundError.noContent }
        return LinkItem(messageID: messageID, kind: kind, representations: reps,
                        suggestedName: nil, capturedAt: entry.capturedAt, origin: origin)
    }

    static func linkKind(for kind: ClipboardKind) -> LinkItemKind {
        switch kind {
        case .text:     return .text
        case .richText: return .richText
        case .image:    return .image
        case .color:    return .color
        case .url:      return .url
        case .file:     return .file
        }
    }
}

/// The outbound adapter's error taxonomy (mapped at the send boundary).
enum LinkOutboundError: Error, Equatable, LocalizedError {
    case noContent
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .noContent:     return "This item has no content to send."
        case .unreadableFile: return "The file could not be read to send."
        }
    }
}
