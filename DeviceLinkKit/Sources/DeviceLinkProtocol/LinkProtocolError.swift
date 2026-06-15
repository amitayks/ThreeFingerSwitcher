import Foundation

/// The single error taxonomy for the protocol. Every decode/reassembly failure maps to one of these
/// cases — the package never surfaces a raw Foundation/decoding error to callers. Transports map these
/// at their boundary into their own presented errors. Mirrors the app's one-taxonomy convention.
public struct LinkProtocolError: Error, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case badMagic           // frame did not begin with the protocol magic
        case unsupportedVersion // wire-format version byte (or negotiated major) not understood
        case unknownFrameType   // frame type tag not recognized
        case oversizeLength     // declared frame length exceeds the configured cap
        case truncatedFrame     // stream ended mid-frame
        case malformedPayload   // a frame body failed to decode
        case manifestMismatch   // accumulated bytes do not match the header manifest
        case unknownMessage     // a chunk/end for a message with no live header
        case duplicateMessage   // a second itemBegin for a live message id
        case badSequence        // a chunk out of sequence
        case cancelled          // the message was cancelled mid-flight
    }

    public var code: Code

    public init(_ code: Code) {
        self.code = code
    }
}

extension LinkProtocolError: LocalizedError {
    public var errorDescription: String? {
        switch code {
        case .badMagic:           return "Not a device-link stream."
        case .unsupportedVersion: return "The other device speaks an incompatible link version."
        case .unknownFrameType:   return "Received an unrecognized message."
        case .oversizeLength:     return "A message exceeded the allowed size."
        case .truncatedFrame:     return "The connection ended mid-transfer."
        case .malformedPayload:   return "A message was malformed."
        case .manifestMismatch:   return "A transfer did not match its declared size."
        case .unknownMessage:     return "Received data for an unknown transfer."
        case .duplicateMessage:   return "Received a duplicate transfer."
        case .badSequence:        return "A transfer arrived out of order."
        case .cancelled:          return "The transfer was cancelled."
        }
    }
}
