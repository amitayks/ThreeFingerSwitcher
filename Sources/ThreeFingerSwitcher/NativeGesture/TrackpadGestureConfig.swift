import Foundation

/// Reads, disables, and restores the native "Swipe between full-screen applications" gesture
/// so the horizontal three-finger swipe is unclaimed by the OS. Per spike 1.4 the relevant
/// key is `TrackpadThreeFingerHorizSwipeGesture` in two trackpad domains. Mission Control /
/// App Exposé live on the *Vert* keys, which we never touch.
@MainActor
final class TrackpadGestureConfig {
    enum State {
        case claimedByThreeFinger   // horizontal three-finger swipe is taken by the OS (conflict)
        case free                   // not claimed by three fingers (our gesture is unobstructed)
        case unknown
    }

    private let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    private let horizKey = "TrackpadThreeFingerHorizSwipeGesture"
    private let fourFingerHorizKey = "TrackpadFourFingerHorizSwipeGesture"

    private let backupKey = "trackpadGestureBackup"
    /// Set when we change the setting this session; runtime effect generally needs re-login.
    private(set) var changedThisSession = false

    // MARK: - Read

    func currentState() -> State {
        guard let value = readInt(domain: domains[0], key: horizKey) else { return .unknown }
        // 1 == three-finger horizontal swipe assigned to "swipe between full-screen apps".
        return value == 1 ? .claimedByThreeFinger : .free
    }

    var isClaimed: Bool { currentState() == .claimedByThreeFinger }

    /// The native horizontal gesture may still be effectively active until the next login.
    var needsReloginWarning: Bool { changedThisSession }

    // MARK: - Mutate

    /// Move "swipe between full-screen apps" to four fingers, freeing three-finger horizontal.
    /// Backs up prior values first. Returns false if any write failed.
    @discardableResult
    func disableThreeFingerHorizontal() -> Bool {
        backupCurrentValues()
        var ok = true
        for domain in domains {
            ok = writeInt(2, domain: domain, key: horizKey) && ok          // three-finger horiz OFF
            ok = writeInt(1, domain: domain, key: fourFingerHorizKey) && ok // four-finger horiz ON
        }
        changedThisSession = ok || changedThisSession
        return ok
    }

    /// Restore whatever values were present before we changed them.
    @discardableResult
    func restore() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let backup = try? JSONDecoder().decode([String: [String: Int]].self, from: data) else {
            return false
        }
        var ok = true
        for (domain, keys) in backup {
            for (key, value) in keys {
                ok = writeInt(value, domain: domain, key: key) && ok
            }
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        changedThisSession = false
        return ok
    }

    var hasBackup: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }

    // MARK: - Backup

    private func backupCurrentValues() {
        guard !hasBackup else { return } // don't overwrite an existing backup
        var backup: [String: [String: Int]] = [:]
        for domain in domains {
            var keys: [String: Int] = [:]
            if let v = readInt(domain: domain, key: horizKey) { keys[horizKey] = v }
            if let v = readInt(domain: domain, key: fourFingerHorizKey) { keys[fourFingerHorizKey] = v }
            if !keys.isEmpty { backup[domain] = keys }
        }
        if let data = try? JSONEncoder().encode(backup) {
            UserDefaults.standard.set(data, forKey: backupKey)
        }
    }

    // MARK: - `defaults` shell helpers (reliable for these system-managed domains)

    private func readInt(domain: String, key: String) -> Int? {
        let out = runDefaults(["read", domain, key])
        guard let out, let value = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return value
    }

    @discardableResult
    private func writeInt(_ value: Int, domain: String, key: String) -> Bool {
        runDefaults(["write", domain, key, "-int", String(value)]) != nil
    }

    private func runDefaults(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
