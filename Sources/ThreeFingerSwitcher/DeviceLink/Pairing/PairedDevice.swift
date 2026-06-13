import Foundation

/// A durable trust record created by a successful pairing: the peer's identity plus the pinned
/// public-key (SPKI) SHA-256 hash, so future sessions authenticate the peer by pin without the code.
struct PairedDevice: Codable, Equatable, Identifiable {
    var id: String          // the peer device id
    var name: String        // human-readable (shown in the Devices list)
    var pinnedSPKIHash: Data // SHA-256 of the peer's certificate SubjectPublicKeyInfo
    var pairedAt: Date

    init(id: String, name: String, pinnedSPKIHash: Data, pairedAt: Date) {
        self.id = id
        self.name = name
        self.pinnedSPKIHash = pinnedSPKIHash
        self.pairedAt = pairedAt
    }
}
