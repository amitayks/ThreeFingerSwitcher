import Foundation
import CryptoKit

/// The cryptographic core of serverless, CA-free pairing, shared by the Mac and the iPhone. Each side
/// holds an ephemeral X25519 key pair. Given the peer's public key and the shared code, both derive the
/// SAME confirmation key — and only if they used the same code — by HKDF over the ECDH shared secret,
/// salted by the code and bound to both public keys. An active man-in-the-middle who substitutes keys but
/// does not know the code derives a different key and cannot forge a matching HMAC confirmation.
public struct PairingHandshake {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey
    public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.privateKey = privateKey
    }

    /// Derive the shared confirmation key. Role-independent: both sides sort the two public keys, so
    /// initiator and responder compute the identical key.
    public func confirmationKey(peerPublicKey: Curve25519.KeyAgreement.PublicKey, code: String) throws -> SymmetricKey {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let (low, high) = Self.ordered(publicKey.rawRepresentation, peerPublicKey.rawRepresentation)
        var info = Data("device-link-pairing-v1".utf8)
        info.append(low)
        info.append(high)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: Data(code.utf8),
                                              sharedInfo: info,
                                              outputByteCount: 32)
    }

    /// The confirmation MAC a side sends to prove it derived the same key.
    public func confirmation(_ key: SymmetricKey, label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key))
    }

    /// Constant-time verification of a received confirmation MAC.
    public func verify(_ mac: Data, key: SymmetricKey, label: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(label.utf8), using: key)
    }

    private static func ordered(_ a: Data, _ b: Data) -> (Data, Data) {
        a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
    }
}
