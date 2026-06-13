import Foundation
import AppKit
import DeviceLinkProtocol

/// Converts a received `LinkItem` (the device-link wire DTO) into a `ClipboardEntry`, mirroring
/// `ClipboardMonitor.makeEntry`'s per-kind representation building so a peer item and a local copy of
/// the same content derive the **same fingerprint** (and therefore de-duplicate). Received files are
/// persisted to a dedicated `inbox/` directory and referenced as a `.file` entry. The adapter does NOT
/// insert — the caller (the transport, on `@MainActor`) inserts via `ClipboardStore.insert`, keeping
/// this type free of store/actor coupling and trivially unit-testable.
struct LinkInboundAdapter {
    /// Where received file bytes are written (a sibling of the store's `blobs/`; injectable for tests).
    let inboxDirectory: URL

    init(inboxDirectory: URL) {
        self.inboxDirectory = inboxDirectory
    }

    func entry(from item: LinkItem) throws -> ClipboardEntry {
        let origin = ClipboardOrigin.peer(deviceName: item.origin?.name)
        let capturedAt = item.capturedAt ?? Date()
        var reps: [String: ClipboardPayload] = [:]
        let key: String
        let fingerprint: String
        let kind: ClipboardKind

        switch item.kind {
        case .text:
            guard let data = item.representations[LinkUTI.plainText],
                  let str = String(data: data, encoding: .utf8) else {
                throw LinkInboundError.missingRepresentation(.text)
            }
            reps[ClipboardUTI.plainText] = .inline(data)
            key = ClipboardKey.fromText(str)
            fingerprint = "text:\(str)"
            kind = .text

        case .richText:
            guard let rtf = item.representations[LinkUTI.rtf] else {
                throw LinkInboundError.missingRepresentation(.richText)
            }
            reps[ClipboardUTI.rtf] = .inline(rtf)
            let plain = item.representations[LinkUTI.plainText].flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let pdata = plain.data(using: .utf8) { reps[ClipboardUTI.plainText] = .inline(pdata) }
            key = ClipboardKey.fromText(plain.isEmpty ? "Rich text" : plain)
            fingerprint = "rich:\(Self.hash(rtf))"
            kind = .richText

        case .url:
            guard let data = item.representations[LinkUTI.url] ?? item.representations[LinkUTI.plainText],
                  let str = String(data: data, encoding: .utf8), !str.isEmpty else {
                throw LinkInboundError.missingRepresentation(.url)
            }
            let d = Data(str.utf8)
            reps[ClipboardUTI.url] = .inline(d)
            reps[ClipboardUTI.plainText] = .inline(d)
            key = ClipboardKey.fromText(str)
            fingerprint = "url:\(str)"
            kind = .url

        case .color:
            guard let data = item.representations[LinkUTI.color] else {
                throw LinkInboundError.missingRepresentation(.color)
            }
            reps[ClipboardUTI.color] = .inline(data)
            key = "Color"
            fingerprint = "color:\(Self.hash(data))"
            kind = .color

        case .image:
            guard let data = item.representations[LinkUTI.png] ?? item.representations[LinkUTI.tiff] else {
                throw LinkInboundError.missingRepresentation(.image)
            }
            let uti = item.representations[LinkUTI.png] != nil ? ClipboardUTI.png : ClipboardUTI.tiff
            reps[uti] = .inline(data)
            let rep = NSBitmapImageRep(data: data)
            key = ClipboardKey.fromImage(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
            fingerprint = "image:\(Self.hash(data))"
            kind = .image

        case .file:
            // The file's bytes are carried under whatever UTI key the sender chose; take the first
            // non-empty representation. The filename comes from `suggestedName`.
            guard let data = (item.representations.first(where: { !$0.value.isEmpty }) ?? item.representations.first)?.value else {
                throw LinkInboundError.missingRepresentation(.file)
            }
            let name = Self.sanitizedFileName(item.suggestedName) ?? "received-file"
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
            let dest = inboxDirectory.appendingPathComponent("received-\(item.messageID.uuidString)-\(name)")
            try data.write(to: dest, options: .atomic)
            reps[ClipboardUTI.fileURL] = .inline(Data(dest.absoluteString.utf8))
            key = name
            fingerprint = "file:\(dest.path)"
            kind = .file
        }

        return ClipboardEntry(capturedAt: capturedAt, kind: kind, key: key,
                              sourceApp: nil, representations: reps, fingerprint: fingerprint,
                              origin: origin)
    }

    /// Strip path separators so a hostile/odd suggested name can't escape the inbox directory.
    static func sanitizedFileName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// FNV-1a 64-bit — identical to `ClipboardMonitor.hash` so peer and local fingerprints match.
    static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// The inbound adapter's error taxonomy (mapped at the network boundary by the transport).
enum LinkInboundError: Error, Equatable, LocalizedError {
    case missingRepresentation(ClipboardKind)

    var errorDescription: String? {
        switch self {
        case .missingRepresentation(let kind):
            return "The received \(kind.rawValue) item had no usable content."
        }
    }
}
