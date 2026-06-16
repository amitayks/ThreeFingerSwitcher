import Foundation
import CryptoKit
import DeviceLinkProtocol
import DeviceLinkPairing

/// The Mac's long-lived Curve25519 key in the Keychain + its public-key fingerprint — mirrors the iOS
/// `LocalIdentity`. Goes in the Mac's pairing QR and (later) is what a peer pins for the encrypted link.
enum MacLocalIdentity {
    private static let service = "com.threefingerswitcher.identity"
    private static let account = "macLongLivedKey"

    static var privateKey: Curve25519.KeyAgreement.PrivateKey {
        if let data = load(), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        save(key.rawRepresentation)
        return key
    }

    static var fingerprint: Data {
        Data(SHA256.hash(data: privateKey.publicKey.rawRepresentation))
    }

    static func payload(device: DeviceIdentity, secret: Data,
                        addresses: [String] = [], port: UInt16? = nil) -> PairingQRPayload {
        PairingQRPayload(device: device, secret: secret, spkiFingerprint: fingerprint,
                         addresses: addresses, port: port)
    }

    // MARK: Keychain

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func load() -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func save(_ data: Data) {
        SecItemDelete(baseQuery() as CFDictionary)
        var q = baseQuery()
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
}
