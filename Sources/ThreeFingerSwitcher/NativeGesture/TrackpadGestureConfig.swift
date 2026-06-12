import Foundation

/// Reads and restores the native "Swipe between full-screen applications" gesture state so the
/// horizontal three-finger swipe is unclaimed by the OS. Per spike 1.4 the relevant key is
/// `TrackpadThreeFingerHorizSwipeGesture` in two trackpad domains. Mission Control / App Exposé
/// live on the *Vert* keys, which this class never touches.
///
/// Mutation (freeing the gesture) goes through `RelocationApplier` — the one write path for all
/// relocations — so combined applies resolve the shared four-finger keys correctly and snapshot
/// pristine backups first. This class keeps the reads, the restore, and the status surface.
@MainActor
final class TrackpadGestureConfig {
    enum State: Equatable {
        case claimedByThreeFinger   // horizontal three-finger swipe is taken by the OS (conflict)
        case free                   // not claimed by three fingers (our gesture is unobstructed)
        case unknown
    }

    private let domains = TrackpadKey.domains
    private let horizKey = TrackpadKey.threeFingerHoriz

    private let backupKey = "trackpadGestureBackup"
    private let markers: ReloginMarkers

    init(markers: ReloginMarkers = ReloginMarkers()) {
        self.markers = markers
    }

    // MARK: - Read

    func currentState() -> State {
        Self.horizState(forRawValue: runDefaults(["read", domains[0], horizKey]))
    }

    var isClaimed: Bool { currentState() == .claimedByThreeFinger }

    /// The native horizontal gesture may still be effectively active until the next login.
    /// Persisted (audit-session) marker — survives app relaunches, clears after a real re-login.
    var needsReloginWarning: Bool { markers.isPending(.horizontal) }

    // MARK: - Restore

    /// Restore the system to exactly its prior state — absent-aware: a key that was unset before is
    /// deleted rather than written. Decodes both the current token-map backup format and the legacy
    /// `[domain: [key: Int]]` format (pre-absent-aware backups written by earlier versions).
    @discardableResult
    func restore() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: backupKey) else { return false }
        var ok = true
        if let tokens = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            for (domain, keys) in tokens {
                for (key, token) in keys {
                    switch Self.restoreAction(forToken: token) {
                    case .delete:       ok = deleteKey(domain: domain, key: key) && ok
                    case .write(let v): ok = writeInt(v, domain: domain, key: key) && ok
                    case .none:         break
                    }
                }
            }
        } else if let legacy = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            for (domain, keys) in legacy {
                for (key, value) in keys {
                    ok = writeInt(value, domain: domain, key: key) && ok
                }
            }
        } else {
            return false
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        markers.clear(.horizontal)
        return ok
    }

    var hasBackup: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }

    // MARK: - Pure decision logic (unit-tested; no system access)

    /// Map a raw `defaults read` of the three-finger horizontal key to a State:
    /// 1 ⇒ claimed by the OS ("swipe between full-screen apps"), any other number ⇒ free,
    /// absent/unrecognized ⇒ unknown.
    nonisolated static func horizState(forRawValue raw: String?) -> State {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let v = Int(raw) else { return .unknown }
        return v == 1 ? .claimedByThreeFinger : .free
    }

    enum RestoreAction: Equatable { case delete, write(Int), none }

    /// What restoring a given backup token should do ("absent" ⇒ delete the key).
    nonisolated static func restoreAction(forToken token: String?) -> RestoreAction {
        guard let token else { return .none }
        if token == "absent" { return .delete }
        if let v = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)) { return .write(v) }
        return .none
    }

    // MARK: - `defaults` shell helpers (reliable for these system-managed domains)

    @discardableResult
    private func writeInt(_ value: Int, domain: String, key: String) -> Bool {
        runDefaults(["write", domain, key, "-int", String(value)]) != nil
    }

    @discardableResult
    private func deleteKey(domain: String, key: String) -> Bool {
        runDefaults(["delete", domain, key]) != nil
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
