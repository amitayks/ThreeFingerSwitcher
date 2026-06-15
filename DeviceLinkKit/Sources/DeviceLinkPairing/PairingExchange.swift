import Foundation
import CryptoKit
import DeviceLinkProtocol

/// The pure, authenticated QR pairing exchange. The **joiner** (scanned the QR) and the **host** (showed
/// it) exchange ephemeral X25519 keys and HMAC confirmations keyed by `HKDF(ECDH, salt: the QR secret)`.
/// Both end pinned to the other's long-lived fingerprint + identity, and only if they used the same
/// secret — a man-in-the-middle who couldn't read the QR derives a different key and fails confirmation.
/// No I/O: a transport ferries the `PairingMessage`s.
public struct PairingExchange {
    public enum Role: Sendable { case host, joiner }

    public enum Result: Equatable, Sendable {
        /// Pinned the peer: its identity + long-lived SPKI fingerprint.
        case pinned(DeviceIdentity, Data)
        case failed
    }

    public let role: Role

    private let secret: Data
    private let identity: DeviceIdentity
    private let spki: Data
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey

    // Host-side state carried between its two `consume` calls.
    private var sharedKey: SymmetricKey?
    private var peerIdentity: DeviceIdentity?
    private var peerSPKI: Data?

    public init(role: Role, secret: Data, identity: DeviceIdentity, spkiFingerprint: Data,
                ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.role = role
        self.secret = secret
        self.identity = identity
        self.spki = spkiFingerprint
        self.ephemeral = ephemeral
    }

    /// Joiner only: the opening message.
    public func start() -> PairingMessage? {
        guard role == .joiner else { return nil }
        return .joinerHello(ephemeral: ephemeral.publicKey.rawRepresentation, identity: identity, spki: spki)
    }

    /// Consume a message; return the reply to send (if any) and a terminal result (if reached).
    public mutating func consume(_ message: PairingMessage) throws -> (reply: PairingMessage?, result: Result?) {
        switch (role, message) {
        case let (.host, .joinerHello(ephData, joinerID, joinerSPKI)):
            let key = try deriveKey(peerEphemeral: ephData)
            sharedKey = key
            peerIdentity = joinerID
            peerSPKI = joinerSPKI
            let confirm = mac(key, label: "host")
            return (.hostHello(ephemeral: ephemeral.publicKey.rawRepresentation, identity: identity, spki: spki, confirm: confirm), nil)

        case let (.joiner, .hostHello(ephData, hostID, hostSPKI, hostConfirm)):
            let key = try deriveKey(peerEphemeral: ephData)
            guard verify(hostConfirm, key: key, label: "host") else { return (nil, .failed) }
            return (.joinerConfirm(confirm: mac(key, label: "joiner")), .pinned(hostID, hostSPKI))

        case let (.host, .joinerConfirm(joinerConfirm)):
            guard let key = sharedKey, let pid = peerIdentity, let psp = peerSPKI,
                  verify(joinerConfirm, key: key, label: "joiner") else { return (nil, .failed) }
            return (nil, .pinned(pid, psp))

        default:
            return (nil, .failed)
        }
    }

    // MARK: - Crypto

    private func deriveKey(peerEphemeral: Data) throws -> SymmetricKey {
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral) else {
            throw PairingExchangeError.badKey
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: peerPub)
        let (low, high) = ordered(ephemeral.publicKey.rawRepresentation, peerEphemeral)
        var info = Data("device-link-qr-v1".utf8)
        info.append(low)
        info.append(high)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret, sharedInfo: info, outputByteCount: 32)
    }

    private func mac(_ key: SymmetricKey, label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key))
    }

    private func verify(_ tag: Data, key: SymmetricKey, label: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data(label.utf8), using: key)
    }

    private func ordered(_ a: Data, _ b: Data) -> (Data, Data) {
        a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
    }
}

public enum PairingExchangeError: Error, Equatable {
    case badKey
}
