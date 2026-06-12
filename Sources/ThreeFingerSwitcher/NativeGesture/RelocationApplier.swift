import Foundation

/// Seam over the trackpad `defaults` domains so plan application is unit-testable. The real
/// implementation shells out to `/usr/bin/defaults` (reliable for these system-managed domains);
/// tests inject an in-memory fake.
protocol TrackpadDefaultsAccess: AnyObject {
    func readRaw(domain: String, key: String) -> String?
    @discardableResult func writeInt(_ value: Int, domain: String, key: String) -> Bool
    @discardableResult func deleteKey(domain: String, key: String) -> Bool
}

/// `/usr/bin/defaults`-backed implementation (same approach as the config classes).
final class ShellTrackpadDefaults: TrackpadDefaultsAccess {
    func readRaw(domain: String, key: String) -> String? {
        runDefaults(["read", domain, key])
    }

    @discardableResult
    func writeInt(_ value: Int, domain: String, key: String) -> Bool {
        runDefaults(["write", domain, key, "-int", String(value)]) != nil
    }

    @discardableResult
    func deleteKey(domain: String, key: String) -> Bool {
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

/// The ONE write path for trackpad-gesture relocations. Applies a `RelocationPlan` for the
/// requested features, with the rest of the active features as *context* so the shared four-finger
/// keys resolve to their combined end-state values (the wizard requests everything at once; the
/// Hub's single-feature toggles request one feature with the already-on features as context).
///
/// Order is load-bearing: every requested feature's pristine backup is snapshotted BEFORE any key
/// is written, so a combined apply can never pollute one feature's backup with another feature's
/// intermediate value (the historic first-write-wins defect).
@MainActor
final class RelocationApplier {
    /// Per-feature outcome of one apply.
    struct Result: Equatable {
        /// Keys written successfully (relocation now awaiting its re-login).
        var applied: GestureFeatures = []
        /// A write failed (e.g. a managed preference). The system may be partially altered, so the
        /// feature is also marked pending — pending-side is the safe error direction.
        var failed: GestureFeatures = []
        /// Nothing to do (the feature's gesture already reads freed) — no write, no re-mark.
        var skipped: GestureFeatures = []
    }

    private let trackpad: TrackpadDefaultsAccess
    private let backups: UserDefaults
    private let markers: ReloginMarkers

    init(trackpad: TrackpadDefaultsAccess = ShellTrackpadDefaults(),
         backups: UserDefaults = .standard,
         markers: ReloginMarkers = ReloginMarkers()) {
        self.trackpad = trackpad
        self.backups = backups
        self.markers = markers
    }

    /// Apply the requested features' relocations. `context` is the set of OTHER features that are
    /// (or are being kept) active — they contribute to value resolution but their keys are never
    /// written and their backups never touched.
    func apply(requested: GestureFeatures, context: GestureFeatures) -> Result {
        let plan = RelocationPlan.assignments(for: requested.union(context))
        var result = Result()

        // Feature-level no-op guards, mirroring the config classes' historic semantics: a gesture
        // that already reads freed is skipped entirely (no write, no backup, no pending re-mark) —
        // this is what makes reapply-on-relaunch a true no-op so the relocation can become effective.
        let toApply = requested.individualFeatures.filter { needsApply($0) }
        for feature in requested.individualFeatures where !toApply.contains(feature) {
            result.skipped.insert(feature)
        }
        guard !toApply.isEmpty else { return result }

        // 1. Snapshot every pristine backup BEFORE any write (first-write-wins per slot is kept:
        //    an existing backup from an earlier session is older and therefore more pristine).
        for feature in toApply { snapshotBackupIfNeeded(feature) }

        // 2. Write the final values, each key once per domain (shared keys deduped).
        var keyOutcome: [String: Bool] = [:]
        let keys = toApply.flatMap { RelocationPlan.touchedKeys(for: $0) }
        for key in keys where keyOutcome[key] == nil {
            guard let value = plan[key] else { continue }
            var ok = true
            for domain in TrackpadKey.domains {
                ok = trackpad.writeInt(value, domain: domain, key: key) && ok
            }
            keyOutcome[key] = ok
        }

        // 3. Per-feature outcome + pending marker. The marker is set even on failure: a partial
        //    write still leaves the system altered and awaiting a re-login.
        for feature in toApply {
            markers.markPending(feature)
            let ok = RelocationPlan.touchedKeys(for: feature).allSatisfy { keyOutcome[$0] ?? true }
            if ok { result.applied.insert(feature) } else { result.failed.insert(feature) }
        }
        return result
    }

    // MARK: - Per-feature state

    /// Whether the feature's gesture still needs freeing, using the same raw-value mapping as the
    /// config classes' state reads.
    private func needsApply(_ feature: GestureFeatures) -> Bool {
        let domain = TrackpadKey.domains[0]
        switch feature {
        case .horizontal:
            let raw = trackpad.readRaw(domain: domain, key: TrackpadKey.threeFingerHoriz)
            return TrackpadGestureConfig.horizState(forRawValue: raw) == .claimedByThreeFinger
        case .spaceRows:
            let raw = trackpad.readRaw(domain: domain, key: TrackpadKey.threeFingerVert)
            return VerticalGestureConfig.threeFingerState(forRawValue: raw) != .free
        case .launcher:
            let raw = trackpad.readRaw(domain: domain, key: TrackpadKey.fourFingerHoriz)
            return FourFingerGestureConfig.horizState(forRawValue: raw) != .free
        default:
            return false
        }
    }

    // MARK: - Backup

    private func snapshotBackupIfNeeded(_ feature: GestureFeatures) {
        guard let slot = RelocationPlan.backupSlot(for: feature),
              backups.data(forKey: slot) == nil else { return }
        var backup: [String: [String: String]] = [:]
        for domain in TrackpadKey.domains {
            var tokens: [String: String] = [:]
            for key in RelocationPlan.touchedKeys(for: feature) {
                tokens[key] = RelocationBackup.token(forRawValue: trackpad.readRaw(domain: domain, key: key))
            }
            backup[domain] = tokens
        }
        if let data = try? JSONEncoder().encode(backup) {
            backups.set(data, forKey: slot)
        }
    }
}
