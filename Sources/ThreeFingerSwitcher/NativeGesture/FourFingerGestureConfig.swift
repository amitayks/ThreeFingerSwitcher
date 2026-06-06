import Foundation

/// Reads, frees, and restores the native **four-finger** trackpad swipe gestures so the four-finger
/// horizontal/vertical swipe is unclaimed by the OS and free for the launcher.
///
/// Sibling of `VerticalGestureConfig` (three-finger vertical) and `TrackpadGestureConfig`
/// (three-finger horizontal): same two trackpad domains and `/usr/bin/defaults` approach, with
/// `SpacesRearrangeConfig`'s absent-aware backup (a key may be unset, so a faithful restore deletes
/// it rather than writing an explicit value). Like the others the runtime effect needs a one-time
/// re-login, so callers must detect-and-warn and not enable launcher emission until effective.
///
/// Two keys, two encodings — confirmed from the existing configs:
/// - `TrackpadFourFingerHorizSwipeGesture` — "swipe between full-screen apps" on four fingers.
///   The HORIZONTAL keys use `1` == assigned to that finger count (claimed), and the gesture is
///   freed for that count by writing the *unassigned* value. `TrackpadGestureConfig` already
///   demonstrates `1` == assigned (it writes the four-finger horiz key to `1` to MOVE the
///   full-screen-app swipe there). The launcher needs that swipe OFF on four fingers, so we write
///   the unassigned value `2`.
///   ⚠️ ASSUMPTION (see tasks 3.0): that `2` fully disables four-finger horizontal (rather than
///   leaving it half-on) is reasoned from the existing encoding but NOT yet confirmed by an
///   authoritative before/after `defaults` diff like the vertical spike (D-OQ1). Confirm on-device.
/// - `TrackpadFourFingerVertSwipeGesture` — Mission Control / App Exposé on four fingers. The
///   VERTICAL keys use `2` == enabled, `0` == disabled (confirmed empirically by the vertical
///   change). We write `0` to free it; Mission Control remains available via the app's idle
///   three-finger synthesis, so nothing is lost.
@MainActor
final class FourFingerGestureConfig {
    enum State: Equatable {
        case claimedByFourFinger    // four-finger horizontal swipe is taken by the OS (full-screen apps)
        case free                   // not claimed (free for the launcher)
        case unknown
    }

    private let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    private let horizKey = "TrackpadFourFingerHorizSwipeGesture"
    private let vertKey = "TrackpadFourFingerVertSwipeGesture"

    /// HORIZONTAL: `1` == assigned to this finger count (claimed); `2` == not assigned (freed).
    private let horizClaimedValue = 1
    private let horizFreeValue = 2
    /// VERTICAL: `2` == enabled (Mission Control on four fingers); `0` == disabled (freed).
    private let vertFreeValue = 0

    private let backupKey = "fourFingerGestureBackup"
    /// Set when we change the setting this session; runtime effect generally needs re-login.
    private(set) var changedThisSession = false

    // MARK: - Read

    func currentState() -> State {
        Self.horizState(forRawValue: runDefaults(["read", domains[0], horizKey]))
    }

    /// True when the four-finger horizontal swipe is still owned by the OS (would steal the launcher).
    var isClaimed: Bool { currentState() == .claimedByFourFinger }

    /// True when the four-finger horizontal swipe has been freed (free for the launcher).
    var isFree: Bool { currentState() == .free }

    /// Effective (safe to enable launcher emission) only when the gesture currently reads free AND
    /// we did not change it this session — a change made this session needs a re-login to take effect.
    var isEffectivelyFree: Bool { isFree && !changedThisSession }

    /// The relocation may still be effectively inactive until the next login.
    var needsReloginWarning: Bool { changedThisSession }

    var hasBackup: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }

    // MARK: - Mutate

    /// Free the four-finger swipes (horizontal full-screen-app swipe OFF, vertical Mission Control
    /// OFF), backing up prior values absent-aware first. No-op (no write) when already free. Returns
    /// false if any write failed.
    @discardableResult
    func freeFourFingerSwipes() -> Bool {
        guard currentState() != .free else { return true }   // already free: nothing to do
        backupCurrentValues()
        var ok = true
        for domain in domains {
            ok = writeInt(horizFreeValue, domain: domain, key: horizKey) && ok  // full-screen swipe OFF
            ok = writeInt(vertFreeValue, domain: domain, key: vertKey) && ok    // four-finger MC OFF
        }
        changedThisSession = ok || changedThisSession
        return ok
    }

    /// Restore the system to exactly its prior state (delete keys that were absent, otherwise write
    /// back the backed-up value), and clear the backup. No-op without a backup. Restoring re-enables
    /// a prior four-finger Mission Control fallback if one was present.
    @discardableResult
    func restore() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let backup = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return false
        }
        var ok = true
        for (domain, keys) in backup {
            for (key, token) in keys {
                switch Self.restoreAction(forToken: token) {
                case .delete:       ok = deleteKey(domain: domain, key: key) && ok
                case .write(let v): ok = writeInt(v, domain: domain, key: key) && ok
                case .none:         break
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
        changedThisSession = false
        return ok
    }

    // MARK: - Backup

    private func backupCurrentValues() {
        guard !hasBackup else { return }   // don't overwrite an existing backup
        var backup: [String: [String: String]] = [:]
        for domain in domains {
            var keys: [String: String] = [:]
            keys[horizKey] = Self.backupToken(forRawValue: runDefaults(["read", domain, horizKey]))
            keys[vertKey] = Self.backupToken(forRawValue: runDefaults(["read", domain, vertKey]))
            backup[domain] = keys
        }
        if let data = try? JSONEncoder().encode(backup) {
            UserDefaults.standard.set(data, forKey: backupKey)
        }
    }

    // MARK: - Pure decision logic (unit-tested; no system access)

    /// Map a raw `defaults read` of the four-finger horizontal key to a State: `1` ⇒ claimed (OS owns
    /// the full-screen-app swipe), any other number ⇒ free, absent/unrecognized ⇒ unknown.
    nonisolated static func horizState(forRawValue raw: String?) -> State {
        guard let v = normalizedInt(raw) else { return .unknown }
        return v == 1 ? .claimedByFourFinger : .free
    }

    /// Token persisted as the backup for a key: "absent" when unset, otherwise the normalized
    /// integer string. Restoring "absent" deletes the key (faithful to a common default).
    nonisolated static func backupToken(forRawValue raw: String?) -> String {
        guard let v = normalizedInt(raw) else { return "absent" }
        return String(v)
    }

    enum RestoreAction: Equatable { case delete, write(Int), none }

    /// What restoring a given backup token should do.
    nonisolated static func restoreAction(forToken token: String?) -> RestoreAction {
        guard let token else { return .none }
        if token == "absent" { return .delete }
        if let v = Int(token.trimmingCharacters(in: .whitespacesAndNewlines)) { return .write(v) }
        return .none
    }

    /// Parse a raw `defaults read` result to an Int, treating empty/whitespace/non-numeric as nil.
    nonisolated private static func normalizedInt(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return Int(raw)
    }

    // MARK: - `defaults` shell helpers

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
