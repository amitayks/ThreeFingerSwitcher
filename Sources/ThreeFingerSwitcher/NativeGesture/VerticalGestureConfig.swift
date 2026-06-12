import Foundation

/// Reads, relocates, and restores the native three-finger *vertical* trackpad gestures
/// (Mission Control = swipe up, App Exposé = swipe down) so the three-finger vertical swipe is
/// unclaimed by the OS and free for the switcher's Space-row stepping.
///
/// Sibling of `TrackpadGestureConfig` (which frees the *horizontal* swipe): same two trackpad
/// domains and `/usr/bin/defaults` approach. The difference is intent — relocating Mission
/// Control / App Exposé to four fingers is a heavier change, so it is strictly opt-in (gated by
/// `AppSettings.manageVerticalGesture`) and managed across the app lifecycle like
/// `SpacesRearrangeConfig` (apply-on-launch / restore-on-quit / reapply-on-relaunch) with an
/// *absent-aware* backup (the keys may be unset, i.e. the default, so a faithful restore deletes
/// them rather than writing an explicit value).
///
/// Value semantics (confirmed by an authoritative before/after `defaults` diff on a real Mac:
/// switching System Settings ▸ Trackpad ▸ More Gestures ▸ Mission Control from three to four
/// fingers changes exactly `TrackpadThreeFingerVertSwipeGesture: 2 → 0` in both trackpad domains
/// and nothing else): `2` == three-finger vertical enabled (OS owns it), `0` == disabled (freed).
/// This one key controls Mission Control (up) and App Exposé (down) together. To free three
/// fingers while keeping them on four fingers we set the three-finger key to `0` and ensure the
/// four-finger key is `2`. The `com.apple.dock` master enables (`showMissionControlGestureEnabled`
/// / `showAppExposeGestureEnabled`) are pure on/off booleans (they stayed `1` through the diff),
/// *not* finger count, and are never touched — the gestures stay enabled, just on four fingers.
/// As with the horizontal gesture, the change's runtime effect needs a re-login (the stored value
/// flips immediately but three-finger vertical keeps firing until logout), so callers must
/// detect-and-warn and must not enable row stepping until the relocation is effective.
@MainActor
final class VerticalGestureConfig {
    enum State: Equatable {
        case claimedByThreeFinger   // three-finger vertical swipe is taken by the OS (MC / Exposé)
        case free                   // not claimed by three fingers (free for Space-row stepping)
        case unknown
    }

    private let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    private let threeFingerKey = TrackpadKey.threeFingerVert

    private let backupKey = "verticalGestureBackup"
    private let markers: ReloginMarkers

    init(markers: ReloginMarkers = ReloginMarkers()) {
        self.markers = markers
    }

    // MARK: - Read

    func currentState() -> State {
        Self.threeFingerState(forRawValue: runDefaults(["read", domains[0], threeFingerKey]))
    }

    /// True when the three-finger vertical gesture is still owned by the OS (Mission Control /
    /// App Exposé on three fingers) — i.e. our row stepping would conflict with it.
    var isClaimed: Bool { currentState() == .claimedByThreeFinger }

    /// True when the three-finger vertical gesture has been relocated (free for row stepping).
    var isFree: Bool { currentState() == .free }

    /// The relocation is *effective* (safe to enable row stepping) only when the three-finger
    /// vertical gesture currently reads as free AND no re-login is still pending for it. The
    /// pending state is a persisted (audit-session) marker, so a mere app relaunch within the same
    /// login session no longer fakes effectiveness — only a real re-login clears it.
    var isEffectivelyFree: Bool { isFree && !markers.isPending(.spaceRows) }

    /// The relocation may still be effectively inactive until the next login.
    var needsReloginWarning: Bool { markers.isPending(.spaceRows) }

    var hasBackup: Bool { UserDefaults.standard.data(forKey: backupKey) != nil }

    // MARK: - Mutate

    // Relocation (freeing the gesture) goes through `RelocationApplier` — the one write path for
    // all relocations — which snapshots this class's backup slot pristine before any write and
    // marks the persisted pending-re-login state.

    /// Restore the system to exactly its prior state (delete keys that were absent, otherwise
    /// write back the backed-up value), and clear the backup. No-op without a backup.
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
        markers.clear(.spaceRows)
        return ok
    }

    // MARK: - Pure decision logic (unit-tested; no system access)

    /// Map a raw `defaults read` of the three-finger vertical key to a State: 2 ⇒ claimed (OS owns
    /// it), 0 ⇒ free, absent/unrecognized ⇒ unknown.
    nonisolated static func threeFingerState(forRawValue raw: String?) -> State {
        guard let v = normalizedInt(raw) else { return .unknown }
        switch v {
        case 0:  return .free
        case 2:  return .claimedByThreeFinger
        default: return .unknown
        }
    }

    /// Token persisted as the backup for a key: "absent" when unset, otherwise the normalized
    /// integer string. Restoring "absent" deletes the key (faithful to the common default).
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
