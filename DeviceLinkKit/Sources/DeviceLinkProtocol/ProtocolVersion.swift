import Foundation

/// The negotiated protocol version (carried in `hello`). Major bumps are breaking — a peer with a
/// different major is refused at the handshake rather than mis-parsed. A newer minor is accepted
/// (additive, optional fields default).
public struct ProtocolVersion: Equatable, Sendable, Codable {
    public var major: UInt16
    public var minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    /// Compatible iff the major versions match. The receiver tolerates a peer on any minor.
    public func isCompatible(with other: ProtocolVersion) -> Bool {
        major == other.major
    }
}

/// A device's identity on the link: a stable id plus a human-readable name (shown in pairing UI).
public struct DeviceIdentity: Equatable, Sendable, Codable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Protocol-wide constants. Distinct from `ProtocolVersion` (the negotiated semantic version): these
/// are the wire-format/codec knobs.
public enum LinkProtocol {
    /// The semantic protocol version this build speaks.
    public static let version = ProtocolVersion(major: 1, minor: 0)

    /// Default upper bound on a single `chunk` frame's representation bytes. Senders SHOULD split a
    /// representation larger than this into multiple chunks. (Tunable; not part of the wire contract.)
    public static let defaultChunkByteBound = 256 * 1024

    /// Default hard cap on a single decoded frame's declared length — a guard against an oversize-length
    /// stream consuming unbounded memory. Large representations are *many* chunks, so no single frame is
    /// huge. (Tunable; not part of the wire contract.)
    public static let defaultMaxFrameLength = 8 * 1024 * 1024
}
