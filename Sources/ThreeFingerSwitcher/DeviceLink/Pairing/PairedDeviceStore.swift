import Foundation

/// Persists the pinned-peer trust records. The pinned value is a public-key hash (a public value), so a
/// Codable file under Application Support is acceptable on the Mac; the device's own *private* long-lived
/// identity goes in the Keychain/Secure Enclave in the TLS follow-up. Injectable directory for tests.
final class PairedDeviceStore {
    private let fileURL: URL
    private var devices: [PairedDevice] = []

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("paired-devices.json")
        load()
    }

    /// `~/Library/Application Support/ThreeFingerSwitcher/devicelink`.
    static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ThreeFingerSwitcher/devicelink", isDirectory: true)
    }

    func all() -> [PairedDevice] { devices.sorted { $0.pairedAt > $1.pairedAt } }

    /// Add or replace the record for a peer id.
    func add(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        save()
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    /// True iff some paired peer pins this SPKI hash (the check the TLS verify block will use).
    func isPinned(spkiHash: Data) -> Bool {
        devices.contains { $0.pinnedSPKIHash == spkiHash }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) else { return }
        devices = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
