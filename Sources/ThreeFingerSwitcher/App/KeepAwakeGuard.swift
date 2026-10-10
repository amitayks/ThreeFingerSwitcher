import AppKit
import Darwin
import LocalAuthentication

// The live side effects behind Keep Awake's guard (`keep-awake-agent-curtain`): the owner check,
// the crash watchdog, the intrusion hook and the guard log. The controller reaches them only through
// its `Effects` seam, so its lifecycle is unit-tested with fakes.

/// How a guard owner-check ended.
enum GuardAuthResult: Equatable {
    case success
    /// Wrong finger, cancelled, Touch ID locked out, or the auth window timed out.
    case failure
}

/// The VISIBLE owner check (the silent `SilentOwnerListener` is the first line).
/// - `allowPassword == false` (Lock mode): **Touch ID only**, no password button; the real lock screen
///   handles passwords.
/// - `allowPassword == true` (Curtain mode, after an unrecognized finger or without Touch ID): the
///   system prompt with Touch ID AND "Use Password…" (`needsPassThrough == true`: the curtain lets
///   keys and clicks inside the prompt through while it is open).
@MainActor
final class GuardAuthenticator {
    private var context: LAContext?
    private var timeout: DispatchWorkItem?

    /// True when Touch ID can answer now (no input needed).
    static func biometricsAvailable() -> Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// Start one owner check. `allowPassword` permits the password fallback when biometrics are
    /// unavailable; the returned flag says whether that path (which needs keyboard input) is in use.
    /// The completion runs once on the main thread.
    func authenticate(allowPassword: Bool, timeoutSec: TimeInterval,
                      completion: @escaping (GuardAuthResult) -> Void) -> (started: Bool, needsPassThrough: Bool) {
        cancel()
        let ctx = LAContext()
        if !allowPassword { ctx.localizedFallbackTitle = "" }   // Lock mode: no "Use Password…"
        ctx.localizedCancelTitle = "Stay locked"
        let biometric = Self.biometricsAvailable()
        guard biometric || allowPassword else { return (false, false) }
        let policy: LAPolicy = allowPassword ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        context = ctx
        var finished = false
        let finish: (GuardAuthResult) -> Void = { [weak self] r in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                self?.timeout?.cancel()
                self?.timeout = nil
                self?.context = nil
                completion(r)
            }
        }
        let t = DispatchWorkItem { ctx.invalidate(); finish(.failure) }
        timeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSec, execute: t)
        ctx.evaluatePolicy(policy, localizedReason: "end Keep Awake and show your screen") { ok, _ in
            finish(ok ? .success : .failure)
        }
        return (true, allowPassword)
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        context?.invalidate()
        context = nil
    }
}

/// A tiny second process that locks the Mac if the curtain's owner dies while the curtain is up
/// (crash, force-quit): an active event tap vanishes with its process, which would otherwise leave
/// the Mac open. It is this same executable started as `--curtain-watchdog <pid> <marker>`; it exits
/// quietly when the marker file is removed (a clean stop), and locks when the PID is gone but the
/// marker remains.
enum CurtainWatchdog {
    static let flag = "--curtain-watchdog"

    /// The marker file: present exactly while a curtain is up.
    static var markerURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThreeFingerSwitcher", isDirectory: true)
        return dir.appendingPathComponent("curtain.active")
    }

    /// Parse `--curtain-watchdog <pid> <marker>`; nil when the args don't request the watchdog.
    static func parse(_ args: [String]) -> (pid: pid_t, marker: String)? {
        guard let i = args.firstIndex(of: flag), args.count > i + 2,
              let pid = pid_t(args[i + 1]), pid > 1, !args[i + 2].isEmpty else { return nil }
        return (pid, args[i + 2])
    }

    /// What the watchdog should do on one tick.
    enum Verdict: Equatable { case keepWatching, exitQuietly, lockAndExit }
    static func verdict(ownerAlive: Bool, markerPresent: Bool) -> Verdict {
        if !markerPresent { return .exitQuietly }
        return ownerAlive ? .keepWatching : .lockAndExit
    }

    /// Entry from `runThreeFingerSwitcher()`: runs the watch loop and never returns when requested.
    static func runIfRequested(_ args: [String] = CommandLine.arguments) {
        guard let (pid, marker) = parse(args) else { return }
        while true {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            switch verdict(ownerAlive: alive, markerPresent: FileManager.default.fileExists(atPath: marker)) {
            case .keepWatching: usleep(500_000)
            case .exitQuietly: exit(0)
            case .lockAndExit:
                ScreenLocker.lock()
                try? FileManager.default.removeItem(atPath: marker)
                exit(0)
            }
        }
    }

    /// Write the marker and start the watchdog for this process. Returns false if it could not start.
    static func start() -> Bool {
        let marker = markerURL
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data("\(getpid())".utf8)),
              let exe = Bundle.main.executableURL else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = [flag, String(getpid()), marker.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try? FileManager.default.removeItem(at: marker); return false }
        return true
    }

    /// Clean stop: removing the marker makes the watchdog exit without locking.
    static func stop() { try? FileManager.default.removeItem(at: markerURL) }
}

/// Runs the user's intrusion hook (a shell command) with the event in the environment:
/// `TFS_GUARD_EVENT` = `intrusion` | `auth-ok` | `auth-failed`, `TFS_GUARD_DETAIL` = what tripped it.
/// Fire-and-forget, never blocks the main thread, a hung hook is killed after 20 s.
enum GuardHook {
    static func run(command: String, event: String, detail: String) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", cmd]
            var env = ProcessInfo.processInfo.environment
            env["TFS_GUARD_EVENT"] = event
            env["TFS_GUARD_DETAIL"] = detail
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
            p.waitUntilExit()
            killer.cancel()
        }
    }
}

/// Append-only guard log (`~/Library/Logs/ThreeFingerSwitcher/keep-awake-guard.log`, capped at
/// ~256 KB): what tripped the guard and how the owner check ended — the evidence for tuning it.
enum GuardLog {
    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ThreeFingerSwitcher/keep-awake-guard.log")
    }

    /// One serial queue: concurrent appends overwrote each other (truncated "ouch id" lines).
    private static let queue = DispatchQueue(label: "tfs.guard-log", qos: .utility)
    nonisolated(unsafe) private static let stampFormatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        let u = url
        let date = Date()
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: u.path))?[.size] as? Int, size > 256_000 {
                try? fm.removeItem(at: u)
            }
            let stamp = stampFormatter.string(from: date)
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: u) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                fm.createFile(atPath: u.path, contents: data)
            }
        }
    }
}
