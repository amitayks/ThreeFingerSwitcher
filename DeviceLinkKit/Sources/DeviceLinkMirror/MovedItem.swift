import Foundation
import DeviceLinkProtocol

/// Which way a thing moved between the iPhone and the Mac.
public enum MoveDirection: String, Codable, Sendable, Equatable {
    case sent       // the phone sent it to the Mac
    case received   // the phone received it from the Mac
}

/// One record in the iPhone app's "what moved" list. Carries enough to show the row and to re-share a
/// received item (its representation bytes). Pure value type; no UIKit.
public struct MovedItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var direction: MoveDirection
    public var kind: LinkItemKind
    /// A single-line label for the row.
    public var title: String
    /// The other device's name, when known.
    public var peerName: String?
    public var movedAt: Date
    /// Materialized representation bytes keyed by UTI (loaded from blobs by the store).
    public var representations: [String: Data]

    public init(id: UUID, direction: MoveDirection, kind: LinkItemKind, title: String,
                peerName: String?, movedAt: Date, representations: [String: Data]) {
        self.id = id
        self.direction = direction
        self.kind = kind
        self.title = title
        self.peerName = peerName
        self.movedAt = movedAt
        self.representations = representations
    }

    /// Build a moved-item record from a wire `LinkItem`.
    public static func from(_ item: LinkItem, direction: MoveDirection, at date: Date) -> MovedItem {
        MovedItem(id: item.messageID, direction: direction, kind: item.kind,
                  title: title(for: item), peerName: item.origin?.name, movedAt: date,
                  representations: item.representations)
    }

    /// A single-line title: first line of text/url, the file's suggested name, or a fixed label.
    static func title(for item: LinkItem) -> String {
        switch item.kind {
        case .text, .url, .richText:
            let data = item.representations[LinkUTI.plainText]
                ?? item.representations[LinkUTI.url]
                ?? item.representations.values.first
                ?? Data()
            return firstLine(String(decoding: data, as: UTF8.self))
        case .image: return "Image"
        case .color: return "Color"
        case .file:  return item.suggestedName ?? "File"
        }
    }

    static func firstLine(_ text: String, max: Int = 80) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= max ? trimmed : String(trimmed.prefix(max)) + "…"
    }
}
