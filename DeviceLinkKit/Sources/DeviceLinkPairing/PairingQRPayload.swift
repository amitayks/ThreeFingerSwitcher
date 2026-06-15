import Foundation
import DeviceLinkProtocol

/// What a pairing QR encodes: the showing device's identity, a fresh high-entropy secret (the
/// out-of-band authenticator — far stronger than an 8-digit code), and the device's long-lived
/// public-key (SPKI) fingerprint so the scanner can pin its TLS identity. v2 additionally carries the
/// shower's reachable network address(es) + its listener port so the scanner can dial it **directly**
/// (unicast) without relying on mDNS/Bonjour discovery, which routers commonly filter between clients.
/// Encoded as a scheme-tagged, versioned base64url string.
public struct PairingQRPayload: Equatable, Sendable {
    /// Bumped to 2 for the optional `addresses` + `port` endpoint. v1 (no endpoint) still decodes.
    public static let currentVersion = 2
    public static let scheme = "tfslink:"

    public var version: Int
    public var device: DeviceIdentity
    public var secret: Data
    public var spkiFingerprint: Data
    /// The shower's reachable unicast address(es), most-likely-reachable first (Wi-Fi/Ethernet, IPv4 first).
    /// Empty for a v1 payload or when none could be enumerated → the scanner falls back to discovery.
    public var addresses: [String]
    /// The bound TCP port of the shower's pairing listener. `nil` for a v1 payload.
    public var port: UInt16?

    public init(device: DeviceIdentity,
                secret: Data,
                spkiFingerprint: Data,
                addresses: [String] = [],
                port: UInt16? = nil,
                version: Int = PairingQRPayload.currentVersion) {
        self.version = version
        self.device = device
        self.secret = secret
        self.spkiFingerprint = spkiFingerprint
        self.addresses = addresses
        self.port = port
    }

    /// True when the payload carries a directly-dialable endpoint (at least one address + a port).
    public var hasEndpoint: Bool { !addresses.isEmpty && port != nil }

    /// 32 cryptographically-random bytes (the global RNG is a CSPRNG).
    public static func makeSecret() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
    }

    public func encodedString() -> String {
        let wire = Wire(v: version, id: device.id, name: device.name, secret: secret, fp: spkiFingerprint,
                        addrs: addresses.isEmpty ? nil : addresses, port: port)
        let json = (try? JSONEncoder().encode(wire)) ?? Data()
        return Self.scheme + Self.base64url(json)
    }

    public init(string: String) throws {
        guard string.hasPrefix(Self.scheme) else { throw PairingQRError.badScheme }
        let body = String(string.dropFirst(Self.scheme.count))
        guard let json = Self.base64urlDecode(body) else { throw PairingQRError.malformed }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: json) else { throw PairingQRError.malformed }
        // Accept v1 (no endpoint) and the current version; reject anything else.
        guard wire.v == 1 || wire.v == Self.currentVersion else { throw PairingQRError.unsupportedVersion }
        self.init(device: DeviceIdentity(id: wire.id, name: wire.name),
                  secret: wire.secret, spkiFingerprint: wire.fp,
                  addresses: wire.addrs ?? [], port: wire.port, version: wire.v)
    }

    private struct Wire: Codable {
        var v: Int
        var id: String
        var name: String
        var secret: Data
        var fp: Data
        var addrs: [String]?   // v2+, optional — omitted on the wire when empty/v1
        var port: UInt16?      // v2+, optional
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

public enum PairingQRError: Error, Equatable {
    case badScheme
    case unsupportedVersion
    case malformed
}
