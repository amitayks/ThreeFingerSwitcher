import Foundation

/// Reads, disables, and restores the macOS "Automatically rearrange Spaces based on most recent
/// use" setting (`com.apple.dock` key `mru-spaces`). When that setting is ON (the default),
/// macOS reorders the Mission Control Space sequence by recency, which the switcher mirrors —
/// so disabling it is what makes the switcher's Space-row order truly stable.
///
/// Sibling of `TrackpadGestureConfig`: same `/usr/bin/defaults` shell approach and `UserDefaults`
/// backup, with two differences — the change needs a Dock restart (`killall Dock`) to take effect,
/// and the backup is *absent-aware* (the key is usually unset, i.e. the default), so a faithful
/// restore deletes the key rather than writing an explicit value.
@MainActor
final class SpacesRearrangeConfig {
    enum State: Equatable {
        case rearranging   // mru-spaces ON / absent (default): macOS reorders Spaces by recency
        case fixed         // mru-spaces OFF: Mission Control keeps a fixed Space order
        case unknown       // couldn't read / unrecognized value
    }

    private let domain = "com.apple.dock"
    private let key = "mru-spaces"
    private let backupKey = "spacesRearrangeBackup"

    /// Set when we changed the setting this session (drives quit-time restore).
    private(set) var changedThisSession = false

    // MARK: - Read

    func currentState() -> State {
        Self.state(forRawValue: runDefaults(["read", domain, key]))
    }

    /// True when Spaces auto-rearrange is on (or unreadable — we err toward "on" so we still offer
    /// to fix it rather than claim it's already handled).
    var isAutoRearrangeOn: Bool { currentState() != .fixed }

    var hasBackup: Bool { UserDefaults.standard.string(forKey: backupKey) != nil }

    // MARK: - Mutate

    /// Disable auto-rearrange (back up the prior state, write `mru-spaces=false`, restart the Dock).
    /// No-op (no write, no Dock restart) when the setting is already fixed. Returns false if the
    /// write or the Dock restart failed (e.g. a managed preference).
    @discardableResult
    func disableAutoRearrange() -> Bool {
        guard currentState() != .fixed else { return true }   // already fixed: nothing to do
        backupCurrentValueIfNeeded()
        let wrote = writeBool(false)
        let restarted = killallDock()
        if wrote && restarted { changedThisSession = true }
        return wrote && restarted
    }

    /// Restore the system to exactly its prior state (delete the key if it was absent, otherwise
    /// write the backed-up value), restart the Dock, and clear the backup. No-op without a backup.
    @discardableResult
    func restore() -> Bool {
        let token = UserDefaults.standard.string(forKey: backupKey)
        guard token != nil else { return false }
        let ok: Bool
        switch Self.restoreAction(forToken: token) {
        case .delete:        ok = deleteKey()
        case .write(let v):  ok = writeBool(v)
        case .none:          ok = true
        }
        let restarted = killallDock()
        UserDefaults.standard.removeObject(forKey: backupKey)
        changedThisSession = false
        return ok && restarted
    }

    // MARK: - Backup

    private func backupCurrentValueIfNeeded() {
        guard !hasBackup else { return }   // don't overwrite an existing backup
        let token = Self.backupToken(forRawValue: runDefaults(["read", domain, key]))
        UserDefaults.standard.set(token, forKey: backupKey)
    }

    // MARK: - Pure decision logic (unit-tested; no system access)

    /// Map a raw `defaults read` result (or nil when the key is absent) to a State.
    nonisolated static func state(forRawValue raw: String?) -> State {
        guard let v = normalized(raw) else { return .rearranging }   // absent ⇒ default ON
        switch v {
        case "0", "false": return .fixed
        case "1", "true":  return .rearranging
        default:           return .unknown
        }
    }

    /// Token persisted as the backup: "absent", or the normalized prior value ("0"/"1").
    nonisolated static func backupToken(forRawValue raw: String?) -> String {
        guard let v = normalized(raw) else { return "absent" }
        switch v {
        case "true":  return "1"
        case "false": return "0"
        default:      return v
        }
    }

    enum RestoreAction: Equatable { case delete, write(Bool), none }

    /// What restoring a given backup token should do.
    nonisolated static func restoreAction(forToken token: String?) -> RestoreAction {
        guard let token else { return .none }
        switch token {
        case "absent": return .delete
        case "0":      return .write(false)
        case "1":      return .write(true)
        default:       return .write(true)   // any other truthy backup ⇒ restore "on"
        }
    }

    nonisolated private static func normalized(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    // MARK: - Shell helpers

    private func writeBool(_ value: Bool) -> Bool {
        runDefaults(["write", domain, key, "-bool", value ? "true" : "false"]) != nil
    }

    private func deleteKey() -> Bool {
        runDefaults(["delete", domain, key]) != nil
    }

    @discardableResult
    private func killallDock() -> Bool {
        runProcess("/usr/bin/killall", ["Dock"])?.status == 0
    }

    private func runDefaults(_ args: [String]) -> String? {
        guard let r = runProcess("/usr/bin/defaults", args), r.status == 0 else { return nil }
        return r.output
    }

    private func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return nil
        }
    }
}
