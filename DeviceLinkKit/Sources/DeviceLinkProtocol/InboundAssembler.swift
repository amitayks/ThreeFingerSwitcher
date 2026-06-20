import Foundation

/// Reassembles streamed frames into complete `LinkItem`s. Pure (no I/O); holds only the bytes of items
/// currently in flight. Feed it decoded `Frame`s in arrival order; it emits an item on `itemEnd`, passes
/// control frames through, and throws a typed `LinkProtocolError` on a protocol violation.
///
/// For very large files a transport MAY bypass this and stream chunks straight to disk (see the design's
/// D4 disk-streaming seam); this assembler is the simple, correct in-memory path used for control and
/// small/medium items.
public struct InboundAssembler {
    /// The result of consuming one frame.
    public enum Output: Equatable, Sendable {
        case item(LinkItem)      // a complete item was reassembled
        case control(Frame)      // a hello/ack/error passed through for the transport to handle
        case none                // progress was made; nothing to surface yet
    }

    private struct InFlight {
        var header: ItemHeader
        var buffers: [String: Data]    // uti -> accumulated bytes
        var nextSeq: [String: UInt32]  // uti -> expected next chunk index
    }

    private var inFlight: [UUID: InFlight] = [:]

    public init() {}

    /// Items currently being reassembled (diagnostics / tests).
    public var inFlightCount: Int { inFlight.count }

    public mutating func consume(_ frame: Frame) throws -> Output {
        switch frame {
        case .hello, .ack, .error, .authHello, .authConfirm:
            return .control(frame)

        case let .itemBegin(header):
            guard inFlight[header.messageID] == nil else {
                throw LinkProtocolError(.duplicateMessage)
            }
            inFlight[header.messageID] = InFlight(header: header, buffers: [:], nextSeq: [:])
            return .none

        case let .chunk(chunk):
            guard var flight = inFlight[chunk.messageID] else {
                throw LinkProtocolError(.unknownMessage)
            }
            guard let total = flight.header.manifest[chunk.uti] else {
                inFlight[chunk.messageID] = nil
                throw LinkProtocolError(.manifestMismatch)
            }
            let expected = flight.nextSeq[chunk.uti] ?? 0
            guard chunk.seq == expected else {
                inFlight[chunk.messageID] = nil
                throw LinkProtocolError(.badSequence)
            }
            var accumulated = flight.buffers[chunk.uti] ?? Data()
            accumulated.append(chunk.bytes)
            guard accumulated.count <= Int(total) else {
                inFlight[chunk.messageID] = nil
                throw LinkProtocolError(.manifestMismatch)
            }
            flight.buffers[chunk.uti] = accumulated
            flight.nextSeq[chunk.uti] = expected + 1
            inFlight[chunk.messageID] = flight
            return .none

        case let .itemEnd(id):
            guard let flight = inFlight[id] else {
                throw LinkProtocolError(.unknownMessage)
            }
            // Every declared representation must be exactly complete.
            for (uti, total) in flight.header.manifest {
                let have = flight.buffers[uti]?.count ?? 0
                guard have == Int(total) else {
                    inFlight[id] = nil
                    throw LinkProtocolError(.manifestMismatch)
                }
            }
            inFlight[id] = nil
            let item = LinkItem(messageID: id,
                                kind: flight.header.kind,
                                representations: flight.buffers,
                                suggestedName: flight.header.suggestedName,
                                capturedAt: flight.header.capturedAt,
                                origin: flight.header.origin)
            return .item(item)

        case let .cancel(id):
            inFlight[id] = nil // discard partial state; not an error
            return .none
        }
    }
}
