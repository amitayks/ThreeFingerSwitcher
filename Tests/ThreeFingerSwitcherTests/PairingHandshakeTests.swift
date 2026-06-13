import XCTest
import CryptoKit
@testable import ThreeFingerSwitcherCore

/// The Mac-side pinned-peer store. (The pairing crypto — code + handshake, incl. MITM resistance — moved
/// to the shared `DeviceLinkPairing` package; its tests live in `DeviceLinkPairingTests`.)
final class PairedDeviceStoreTests: XCTestCase {

    func testStorePinReloadAndRemove() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tfs-pair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spki = Data(SHA256.hash(data: Data("peer-spki".utf8)))

        let store = PairedDeviceStore(directory: dir)
        XCTAssertFalse(store.isPinned(spkiHash: spki))
        store.add(PairedDevice(id: "phone-1", name: "iPhone", pinnedSPKIHash: spki, pairedAt: Date()))

        // Reload from disk → pin persists.
        let reloaded = PairedDeviceStore(directory: dir)
        XCTAssertTrue(reloaded.isPinned(spkiHash: spki))
        XCTAssertEqual(reloaded.all().map(\.id), ["phone-1"])
        XCTAssertFalse(reloaded.isPinned(spkiHash: Data(SHA256.hash(data: Data("unknown".utf8)))))

        reloaded.remove(id: "phone-1")
        XCTAssertFalse(reloaded.isPinned(spkiHash: spki))
        XCTAssertTrue(reloaded.all().isEmpty)
    }
}
