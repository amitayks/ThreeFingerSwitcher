import Foundation
import CryptoKit
import DeviceLinkProtocol

/// The authenticated link handshake (a Noise-KK-shaped exchange), reusing the proven `DeviceLinkPairing`
/// primitives: X25519 ECDH, role-independent HKDF-SHA256 derivation (sorted public keys + info), and
/// constant-time HMAC-SHA256 confirmations.
///
/// Both ends already pinned the other's long-lived X25519 public key during pairing (by
/// `SHA256(rawRepresentation)`). Each side generates a fresh per-connection **ephemeral** key and sends
/// `authHello(staticPub, ephemeralPub, identity)`. On the peer's `authHello` the receiver:
///   (a) **rejects (fail closed)** if `SHA256(peer staticPub)` is not in the supplied pinned fingerprint set,
///   (b) derives a **role-independent** session `SymmetricKey` mixing the static–static term `ss` (which
///       authenticates: only the pinned-key holders can compute it) with the ephemeral term `ee` and the
///       two cross terms `se`/`es` (per-session freshness / forward secrecy),
///   (c) produces / constant-time-verifies an `authConfirm` HMAC under that key.
///
/// A peer that presents a pinned public key but does **not** hold its private key cannot compute `ss`,
/// derives a different key, and fails the confirmation → the caller drops the connection.
///
/// No I/O: a transport ferries the `Frame.authHello` / `Frame.authConfirm` control frames.
public struct LinkSession {
    /// Why a handshake failed (rejected before / at confirmation). All are fail-closed: no session key.
    public enum Failure: Error, Equatable {
        /// The peer's presented long-lived key is malformed, or its ephemeral key is malformed.
        case badKey
        /// `SHA256(peer staticPub)` is not in the pinned fingerprint set.
        case unpinned
        /// The peer's `authConfirm` did not verify under the derived key (forged identity / wrong key).
        case confirmationFailed
    }

    private static let infoPrefix = "device-link-session-v1"

    public let identity: DeviceIdentity
    public let staticKey: Curve25519.KeyAgreement.PrivateKey
    public let ephemeralKey: Curve25519.KeyAgreement.PrivateKey

    /// - Parameters:
    ///   - identity: this device's identity, carried in `authHello`.
    ///   - staticKey: the local long-lived (pinned) X25519 key agreement private key.
    ///   - ephemeralKey: a fresh per-connection ephemeral; defaults to a new random key.
    public init(identity: DeviceIdentity,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                ephemeralKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.identity = identity
        self.staticKey = staticKey
        self.ephemeralKey = ephemeralKey
    }

    /// This side's opening handshake frame: its pinned static public key, fresh ephemeral, and identity.
    public func hello() -> Frame {
        .authHello(staticPub: staticKey.publicKey.rawRepresentation,
                   ephemeralPub: ephemeralKey.publicKey.rawRepresentation,
                   identity: identity)
    }

    /// `true` iff `SHA256(peerStaticRaw)` is a pinned fingerprint (fail closed when absent).
    public static func isPinned(peerStaticRaw: Data, pinnedFingerprints: Set<Data>) -> Bool {
        pinnedFingerprints.contains(Data(SHA256.hash(data: peerStaticRaw)))
    }

    /// Consume the peer's `authHello`. Verifies the peer's static key is pinned (else `.unpinned`),
    /// then derives the role-independent session key. On success returns the established session.
    ///
    /// - Throws: `Failure.badKey` (malformed peer key), `Failure.unpinned` (not in `pinnedFingerprints`).
    public func accept(peerHello frame: Frame,
                       pinnedFingerprints: Set<Data>) throws -> Established {
        guard case let .authHello(peerStaticRaw, peerEphemeralRaw, peerIdentity) = frame else {
            throw Failure.badKey
        }
        // Reject a peer presenting OUR own static key (a reflection): it would collapse the role-label
        // tie-break to an acceptable self-confirm. Unreachable in practice (we never pin our own key),
        // but a cheap, decisive guard.
        guard peerStaticRaw != staticKey.publicKey.rawRepresentation else {
            throw Failure.badKey
        }
        guard Self.isPinned(peerStaticRaw: peerStaticRaw, pinnedFingerprints: pinnedFingerprints) else {
            throw Failure.unpinned
        }
        guard let peerStatic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerStaticRaw),
              let peerEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralRaw) else {
            throw Failure.badKey
        }
        let key = try deriveSessionKey(peerStatic: peerStatic, peerEphemeral: peerEphemeral)
        // Role-independent confirm labels: the side whose static key sorts lower sends the "low" label
        // and verifies the peer's "high" label (and vice versa). Both sides agree on the assignment from
        // the sorted statics, so each can produce its own confirm and verify the peer's distinct one.
        let localIsLow = staticKey.publicKey.rawRepresentation.lexicographicallyPrecedes(peerStaticRaw)
        return Established(sessionKey: key,
                          peerIdentity: peerIdentity,
                          peerStaticFingerprint: Data(SHA256.hash(data: peerStaticRaw)),
                          localIsLow: localIsLow)
    }

    // MARK: - Key derivation

    /// Role-independent session key: `HKDF-SHA256` over `ss ‖ ee ‖ se‖es` (cross terms ordered
    /// role-independently) with `info = "device-link-session-v1" ‖ sorted(statics) ‖ sorted(ephemerals)`.
    /// Mirrors `PairingHandshake.confirmationKey`'s sorted-public-key construction.
    func deriveSessionKey(peerStatic: Curve25519.KeyAgreement.PublicKey,
                          peerEphemeral: Curve25519.KeyAgreement.PublicKey) throws -> SymmetricKey {
        let localStaticRaw = staticKey.publicKey.rawRepresentation
        let localEphemeralRaw = ephemeralKey.publicKey.rawRepresentation
        let peerStaticRaw = peerStatic.rawRepresentation
        let peerEphemeralRaw = peerEphemeral.rawRepresentation

        let ss = try staticKey.sharedSecretFromKeyAgreement(with: peerStatic)
        let ee = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerEphemeral)
        // Cross terms: ECDH(localStatic, peerEphemeral) and ECDH(localEphemeral, peerStatic). The two ends
        // compute the SAME two physical DH values but with the roles of "local"/"peer" swapped, so each
        // cross term must be ordered by a key that is symmetric in its two participating public keys —
        // `sorted(staticRaw, ephemeralRaw)` of that DH pair — which both ends see identically.
        let crossA = try staticKey.sharedSecretFromKeyAgreement(with: peerEphemeral)   // localStatic · peerEph
        let crossB = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerStatic)   // localEph · peerStatic
        let crossAKey = Self.symmetricKeyBytes(localStaticRaw, peerEphemeralRaw)
        let crossBKey = Self.symmetricKeyBytes(localEphemeralRaw, peerStaticRaw)
        let (firstCross, secondCross) = crossAKey.lexicographicallyPrecedes(crossBKey)
            ? (crossA, crossB) : (crossB, crossA)

        var ikm = Data()
        ikm.append(rawBytes(ss))
        ikm.append(rawBytes(ee))
        ikm.append(rawBytes(firstCross))
        ikm.append(rawBytes(secondCross))

        let (lowStatic, highStatic) = Self.ordered(localStaticRaw, peerStaticRaw)
        let (lowEph, highEph) = Self.ordered(localEphemeralRaw, peerEphemeralRaw)
        var info = Data(Self.infoPrefix.utf8)
        info.append(lowStatic)
        info.append(highStatic)
        info.append(lowEph)
        info.append(highEph)

        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                      info: info,
                                      outputByteCount: 32)
    }

    private func rawBytes(_ secret: SharedSecret) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }

    private static func ordered(_ a: Data, _ b: Data) -> (Data, Data) {
        a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
    }

    /// A role-independent ordering key for a DH pair: `sorted(a, b)` concatenated. Both ends produce the
    /// identical bytes regardless of which key they call "local".
    private static func symmetricKeyBytes(_ a: Data, _ b: Data) -> Data {
        let (low, high) = ordered(a, b)
        return low + high
    }

    /// An authenticated session: the derived key plus the verified peer identity. The confirm helpers
    /// reuse the constant-time HMAC-SHA256 confirmations from `PairingHandshake`, with distinct role
    /// labels so a confirmation can't be reflected back.
    public struct Established: Sendable {
        public let sessionKey: SymmetricKey
        public let peerIdentity: DeviceIdentity
        /// `SHA256(peer staticPub)` — the pinned fingerprint the peer authenticated as.
        public let peerStaticFingerprint: Data
        /// Whether this side's static key sorts before the peer's — selects the confirm role labels.
        let localIsLow: Bool

        private static let labelLow = "device-link-confirm-low"
        private static let labelHigh = "device-link-confirm-high"

        /// The label this side sends; the peer verifies it with the same string.
        private var sendLabel: String { localIsLow ? Self.labelLow : Self.labelHigh }
        /// The label the peer sends; this side verifies the peer's confirm with it.
        private var peerLabel: String { localIsLow ? Self.labelHigh : Self.labelLow }

        // MARK: Directional record keys
        //
        // The session key is role-INDEPENDENT (both ends derive the identical key), so sealing BOTH stream
        // directions under it would reuse `(key, counter-nonce)` between the two `Sealer`s — a catastrophic
        // AEAD nonce reuse. Instead each direction gets its OWN key, derived from the session key by an
        // HKDF label that names the DIRECTION (low→high vs high→low), not the local role. Both ends agree on
        // the assignment from the sorted statics, so this side's `sealKey` equals the peer's `openKey`.
        private static let labelLowToHigh = "device-link-record-low-to-high"
        private static let labelHighToLow = "device-link-record-high-to-low"

        private static func directionKey(_ session: SymmetricKey, _ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: session, info: Data(label.utf8), outputByteCount: 32)
        }

        /// The key for records THIS side SEALS (its transmit direction).
        public var sealKey: SymmetricKey {
            Self.directionKey(sessionKey, localIsLow ? Self.labelLowToHigh : Self.labelHighToLow)
        }
        /// The key for records THIS side OPENS (its receive direction) — equals the peer's `sealKey`.
        public var openKey: SymmetricKey {
            Self.directionKey(sessionKey, localIsLow ? Self.labelHighToLow : Self.labelLowToHigh)
        }

        /// The `authConfirm` frame this side sends — HMAC over its role label under the session key.
        public func confirm() -> Frame {
            .authConfirm(mac: Data(HMAC<SHA256>.authenticationCode(for: Data(sendLabel.utf8), using: sessionKey)))
        }

        /// Constant-time verify the peer's received `authConfirm`. A peer that derived a different key
        /// (e.g. it doesn't hold the pinned private key) produces a non-matching MAC → `false`.
        public func verify(peerConfirm frame: Frame) -> Bool {
            guard case let .authConfirm(mac) = frame else { return false }
            return HMAC<SHA256>.isValidAuthenticationCode(mac,
                                                          authenticating: Data(peerLabel.utf8),
                                                          using: sessionKey)
        }
    }
}
