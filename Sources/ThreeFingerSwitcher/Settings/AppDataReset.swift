import Foundation

/// The Danger zone's deletion categories. Each is an explicit opt-in toggle; nothing is ever
/// implied by another (the one ordering rule — gestures restored before an App-data wipe — lives
/// in the coordinator, where the gesture configs are).
struct DangerZoneSelection: OptionSet, Equatable {
    let rawValue: Int

    /// Preferences domain + Application Support data (excluding the AI model weights) + saved
    /// window state. Includes the gesture backups — hence the restore-first rule.
    static let appData = DangerZoneSelection(rawValue: 1 << 0)
    /// ~/Library/Caches/<bid> and ~/Library/HTTPStorages/<bid>.
    static let caches = DangerZoneSelection(rawValue: 1 << 1)
    /// The multi-GB weights directory (the AI opt-in is turned off first by the coordinator).
    static let aiModels = DangerZoneSelection(rawValue: 1 << 2)
    /// `tccutil reset` for every service the app can hold.
    static let permissions = DangerZoneSelection(rawValue: 1 << 3)
}

/// Selective in-app reset: computes and performs the deletions for a `DangerZoneSelection`.
/// The filesystem-target computation is pure (unit-tested); the perform step sits behind seams
/// (FileManager, UserDefaults, an injectable command runner for `tccutil`).
@MainActor
final class AppDataReset {
    /// Every TCC service this app can hold a grant for, in `tccutil reset` spelling.
    static let tccServices = [
        "Accessibility",   // window enumeration / raising / selection I/O
        "ScreenCapture",   // thumbnails + vision input
        "ListenEvent",     // Input Monitoring (usually never granted)
        "AppleEvents",     // the per-site keyboard "allow browser control" reader
        "Calendar",        // AI tasks (lazy)
        "Reminders",
        "AddressBook"      // Contacts
    ]

    /// What to delete for a selection: directories removed whole, plus directories whose CONTENTS
    /// are removed except named survivors (the App-data/AI-models split: App data keeps `models/`
    /// unless AI models is also selected, in which case the whole root goes).
    struct FilesystemTargets: Equatable {
        var removeWhole: [URL] = []
        var removeContentsExcept: [(directory: URL, keep: Set<String>)] = []

        static func == (lhs: FilesystemTargets, rhs: FilesystemTargets) -> Bool {
            lhs.removeWhole == rhs.removeWhole
                && lhs.removeContentsExcept.map(\.directory) == rhs.removeContentsExcept.map(\.directory)
                && lhs.removeContentsExcept.map(\.keep) == rhs.removeContentsExcept.map(\.keep)
        }
    }

    /// Pure: the filesystem footprint for a selection. `library` is `~/Library`; the Application
    /// Support root is the app's `ThreeFingerSwitcher` directory (clipboard, projects, models).
    nonisolated static func filesystemTargets(for selection: DangerZoneSelection,
                                              library: URL,
                                              bundleID: String) -> FilesystemTargets {
        var targets = FilesystemTargets()
        let appSupportRoot = library.appendingPathComponent("Application Support/ThreeFingerSwitcher",
                                                            isDirectory: true)
        let modelsDir = appSupportRoot.appendingPathComponent("models", isDirectory: true)

        switch (selection.contains(.appData), selection.contains(.aiModels)) {
        case (true, true):
            targets.removeWhole.append(appSupportRoot)
        case (true, false):
            targets.removeContentsExcept.append((appSupportRoot, ["models"]))
        case (false, true):
            targets.removeWhole.append(modelsDir)
        case (false, false):
            break
        }
        if selection.contains(.appData) {
            targets.removeWhole.append(
                library.appendingPathComponent("Saved Application State/\(bundleID).savedState",
                                               isDirectory: true))
        }
        if selection.contains(.caches) {
            targets.removeWhole.append(library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true))
            targets.removeWhole.append(library.appendingPathComponent("HTTPStorages/\(bundleID)", isDirectory: true))
        }
        return targets
    }

    /// One reset's result, for the non-blocking summary. Failures are collected, never fatal.
    struct Outcome {
        var cleared: [String] = []
        var failures: [String] = []
    }

    private let bundleID: String
    private let defaults: UserDefaults
    private let fileManager: FileManager
    /// `~/Library` — the root all filesystem targets hang off. An injectable **seam** so tests can point
    /// the (real, destructive) deletions at a temp directory instead of the user's actual home: the
    /// Application Support root is hardcoded `Application Support/ThreeFingerSwitcher` (NOT keyed by
    /// `bundleID`), so a fake bundleID alone does NOT isolate the filesystem — only this does.
    private let library: URL
    /// Runs an external command, returning success. Real: Process; tests: a spy.
    private let runCommand: (_ launchPath: String, _ arguments: [String]) -> Bool

    init(bundleID: String = Bundle.main.bundleIdentifier ?? "com.threefingerswitcher.app",
         defaults: UserDefaults = .standard,
         fileManager: FileManager = .default,
         library: URL? = nil,
         runCommand: ((String, [String]) -> Bool)? = nil) {
        self.bundleID = bundleID
        self.defaults = defaults
        self.fileManager = fileManager
        self.library = library ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.runCommand = runCommand ?? { launchPath, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    /// Perform the selected deletions. Order matters: files first, the preferences domain LAST
    /// (the live process keeps writing settings through `didSet`; the caller relaunches right
    /// after an App-data clear so the wiped domain stays wiped).
    func clear(_ selection: DangerZoneSelection) -> Outcome {
        var outcome = Outcome()
        let targets = Self.filesystemTargets(for: selection, library: library, bundleID: bundleID)

        for url in targets.removeWhole where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                outcome.cleared.append(url.lastPathComponent)
            } catch {
                outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for (directory, keep) in targets.removeContentsExcept {
            guard let children = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for child in children where !keep.contains(child) {
                let url = directory.appendingPathComponent(child)
                do {
                    try fileManager.removeItem(at: url)
                    outcome.cleared.append(child)
                } catch {
                    outcome.failures.append("\(child): \(error.localizedDescription)")
                }
            }
        }

        if selection.contains(.permissions) {
            for service in Self.tccServices {
                if runCommand("/usr/bin/tccutil", ["reset", service, bundleID]) {
                    outcome.cleared.append("TCC \(service)")
                } else {
                    outcome.failures.append("TCC \(service) reset failed")
                }
            }
        }

        if selection.contains(.appData) {
            defaults.removePersistentDomain(forName: bundleID)
            outcome.cleared.append("preferences")
        }
        return outcome
    }
}
