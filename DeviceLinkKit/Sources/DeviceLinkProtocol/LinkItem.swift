import Foundation

/// What kind of content a moved item holds — mirrors the Mac clipboard's `ClipboardKind` shape so the
/// inbound adapter can map 1:1, but defined here independently (the wire never couples to storage).
public enum LinkItemKind: String, Codable, Equatable, Sendable, CaseIterable {
    case text
    case richText
    case image
    case color
    case url
    case file
}

/// The transport DTO for one moved item: a kind plus its representations keyed by UTI string, with
/// optional metadata. Pure value type, `Sendable`, no AppKit/UIKit. The Mac side maps `LinkItem ⇄
/// ClipboardEntry` at its boundary; the iOS side stores it directly. `representations` holds the
/// **materialized** bytes of an assembled item (the assembler bounds this to items in flight).
public struct LinkItem: Equatable, Sendable {
    public var messageID: UUID
    public var kind: LinkItemKind
    /// UTI string → representation bytes. The same UTIs that appear in the item's `ItemHeader.manifest`.
    public var representations: [String: Data]
    public var suggestedName: String?
    public var capturedAt: Date?
    /// The device that originated the item (set by the sender; used for a "from iPhone/Mac" chip).
    public var origin: DeviceIdentity?

    public init(messageID: UUID,
                kind: LinkItemKind,
                representations: [String: Data],
                suggestedName: String? = nil,
                capturedAt: Date? = nil,
                origin: DeviceIdentity? = nil) {
        self.messageID = messageID
        self.kind = kind
        self.representations = representations
        self.suggestedName = suggestedName
        self.capturedAt = capturedAt
        self.origin = origin
    }
}
