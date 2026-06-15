import Foundation
import DeviceLinkProtocol

/// The three messages of the QR pairing exchange. X25519 public keys are carried as their raw
/// representation; confirmations are HMAC tags. `Codable` so a transport can ferry them.
public enum PairingMessage: Codable, Equatable, Sendable {
    /// Joiner (scanned the QR) opens with its ephemeral public key, identity, and long-lived fingerprint.
    case joinerHello(ephemeral: Data, identity: DeviceIdentity, spki: Data)
    /// Host (showed the QR) replies with its own + a confirmation it knew the secret.
    case hostHello(ephemeral: Data, identity: DeviceIdentity, spki: Data, confirm: Data)
    /// Joiner confirms it, too, knew the secret.
    case joinerConfirm(confirm: Data)
}
