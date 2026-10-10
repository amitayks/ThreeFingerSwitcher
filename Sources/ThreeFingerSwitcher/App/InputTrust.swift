import AppKit
import Darwin

/// Who produced an input event, as Keep Awake's guard sees it (`keep-awake-agent-curtain` D1).
///
/// A CGEvent carries `eventSourceUnixProcessID`: **0 for real hardware** (trackpad, keyboard, mouse,
/// Touch ID button) and the poster's PID for a synthesized event. A synthesized event is trusted only
/// when the posting process belongs to a **trusted app** — this app itself, or one on the user's
/// trusted-apps list (default: Vex). "Belongs to" means the posting process's *responsible* app: an
/// agent's helper binary (e.g. `vexcu`, spawned by Vex's runtime) is attributed to Vex.
enum InputOrigin: Equatable {
    /// Real hardware input — a person at the Mac.
    case hardware
    /// Synthesized by a trusted app (bundle id) — an agent at work; never trips the guard.
    case trusted(String)
    /// Synthesized by a process that is not trusted (bundle id when known) — treated like a person.
    case untrusted(String?)

    var isTrusted: Bool { if case .trusted = self { return true } else { return false } }
}

/// Pure classification rule, with the PID → bundle-id resolution injected (tests use a table).
struct InputTrustPolicy {
    /// Bundle ids whose synthesized input passes the guard.
    var trustedBundleIDs: Set<String>
    /// This process (always trusted: the app's own synthesized events, e.g. the ⌃⌘Q lock fallback).
    var selfPID: Int64 = Int64(getpid())
    /// Bundle id of the app responsible for a PID (nil = unknown / no app).
    var resolveBundleID: (pid_t) -> String?

    func classify(sourcePID: Int64) -> InputOrigin {
        if sourcePID <= 0 { return .hardware }
        if sourcePID == selfPID { return .trusted(Bundle.main.bundleIdentifier ?? "self") }
        guard let bundleID = resolveBundleID(pid_t(truncatingIfNeeded: sourcePID)) else { return .untrusted(nil) }
        return trustedBundleIDs.contains(bundleID) ? .trusted(bundleID) : .untrusted(bundleID)
    }
}

/// Resolves a PID to the bundle id of the app responsible for it. Primary path: the private
/// `responsibility_get_pid_responsible_for_pid` (libquarantine via libSystem, dlsym — crash-safe,
/// the `ScreenLocker` pattern). Fallback: walk the parent chain (sysctl) up to the first process
/// that is a running application. Results are cached briefly (PIDs are recycled).
final class ResponsibleAppResolver {
    static let shared = ResponsibleAppResolver()

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? =
        dlopen(nil, RTLD_NOW)
            .flatMap { dlsym($0, "responsibility_get_pid_responsible_for_pid") }
            .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    private var cache: [pid_t: (bundleID: String?, at: TimeInterval)] = [:]
    private let ttl: TimeInterval = 30
    private let lock = NSLock()

    func bundleID(for pid: pid_t) -> String? {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        if let hit = cache[pid], now - hit.at < ttl { lock.unlock(); return hit.bundleID }
        lock.unlock()
        let resolved = resolve(pid)
        lock.lock()
        if cache.count > 256 { cache.removeAll(keepingCapacity: true) }
        cache[pid] = (resolved, now)
        lock.unlock()
        return resolved
    }

    private func resolve(_ pid: pid_t) -> String? {
        if let fn = Self.responsibleFn {
            let owner = fn(pid)
            if owner > 0, let id = Self.appBundleID(owner) { return id }
        }
        var current = pid
        for _ in 0..<16 {
            if let id = Self.appBundleID(current) { return id }
            guard let parent = Self.parentPID(current), parent > 1, parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// Bundle id when the PID is a running application (or an executable inside an .app bundle).
    private static func appBundleID(_ pid: pid_t) -> String? {
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier { return id }
        // A helper inside an app bundle (…/X.app/Contents/…): read that bundle's identifier.
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        guard let r = path.range(of: ".app/Contents/", options: .backwards) else { return nil }
        let appPath = String(path[..<r.lowerBound]) + ".app"
        return Bundle(path: appPath)?.bundleIdentifier
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

extension InputTrustPolicy {
    /// The live policy over the current trusted-apps list (read at call time, so edits apply at once).
    static func live(trustedBundleIDs: @escaping () -> [String]) -> () -> InputTrustPolicy {
        { InputTrustPolicy(trustedBundleIDs: Set(trustedBundleIDs()),
                           resolveBundleID: { ResponsibleAppResolver.shared.bundleID(for: $0) }) }
    }
}
