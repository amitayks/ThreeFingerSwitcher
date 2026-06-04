import AppKit
import ApplicationServices
import Carbon

/// In-memory ring buffer of focus-commit / watchdog events, plus a one-tap text dump.
///
/// Every `raise()` commit and every watchdog verify/recover step appends one allocation-light
/// `Entry` (no string building until `dump()`). The newest 64 entries are kept; the oldest is
/// overwritten. The dump is appended to the existing "Write Diagnostics → /tmp" file so the user
/// can share a complete per-switch timeline after a freeze, telling apart the ranked causes
/// (secure-input vs genuine vacuum vs activate-no-op).
@MainActor
final class FocusLog {
    static let shared = FocusLog()

    /// What stage of the commit/watchdog pipeline an entry was recorded at.
    enum Phase: String {
        case commit       = "commit"
        case verify       = "verify"
        case recover1     = "recover-1"
        case recover2     = "recover-2"
        case gaveUp       = "gave-up"
        /// Off-Space hold-guard marker: re-fronted the target (or stopped on secure input) after
        /// WindowManager stole frontmost ~300ms past the Space switch.
        case trace        = "trace"
    }

    struct Entry {
        let timestamp: Date
        let phase: Phase
        let pid: pid_t
        let appName: String
        let wid: CGWindowID
        let isOnCurrentSpace: Bool
        /// Whether the captured focus state passed the watchdog check (nil for `commit`).
        let passed: Bool?
        let frontmostPID: pid_t
        let frontmostMatchesTarget: Bool
        let frontmostHasKeyWindow: Bool
        let secureInputEnabled: Bool
        let note: String
    }

    private let capacity = 64
    private var entries: [Entry] = []

    private init() {
        entries.reserveCapacity(capacity)
    }

    /// Append one entry, overwriting the oldest once at capacity.
    func record(_ entry: Entry) {
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries.removeFirst()
            entries.append(entry)
        }
    }

    // MARK: - Focus-state probe

    /// A cheap (sub-millisecond) snapshot of the current focus state, using only public APIs the
    /// app already holds permission for. This is the same probe the watchdog uses to decide
    /// pass/fail, so logging it means the next freeze report names the exact cause.
    struct FocusState {
        let frontmostPID: pid_t
        let frontmostMatchesTarget: Bool
        /// The frontmost app exposes a key/focused window (kAXFocusedWindow, kAXMainWindow fallback).
        let frontmostHasKeyWindow: Bool
        let secureInputEnabled: Bool
    }

    static func probe(targetPID: pid_t) -> FocusState {
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier ?? -1
        let matches = (frontPID == targetPID)
        var hasKey = false
        if let frontPID = front?.processIdentifier {
            let appEl = AXUIElementCreateApplication(frontPID)
            if axCopy(appEl, kAXFocusedWindowAttribute as String) != nil {
                hasKey = true
            } else if axCopy(appEl, kAXMainWindowAttribute as String) != nil {
                hasKey = true
            }
        }
        let secure = IsSecureEventInputEnabled()
        return FocusState(
            frontmostPID: frontPID,
            frontmostMatchesTarget: matches,
            frontmostHasKeyWindow: hasKey,
            secureInputEnabled: secure
        )
    }

    // MARK: - Dump

    /// Render the ring buffer as a text section. Secure-input + frontmost-has-key-window are
    /// surfaced at the TOP so the very next report immediately tells us which ranked cause it was.
    func dump() -> String {
        var out = ["=== focus log ==="]
        let now = FocusLog.probe(targetPID: -1)
        out.append("IsSecureEventInputEnabled (now): \(now.secureInputEnabled)")
        out.append("frontmost pid (now): \(now.frontmostPID)  hasKeyWindow: \(now.frontmostHasKeyWindow)")
        out.append("entries: \(entries.count)/\(capacity)")
        out.append("")

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        for e in entries {
            let pass = e.passed.map { $0 ? "PASS" : "FAIL" } ?? "-"
            var line = "[\(fmt.string(from: e.timestamp))] \(e.phase.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) "
            line += "\(pass.padding(toLength: 4, withPad: " ", startingAt: 0)) "
            line += "pid=\(e.pid) wid=\(e.wid) cur=\(e.isOnCurrentSpace ? 1 : 0) '\(e.appName)' "
            line += "| frontPID=\(e.frontmostPID) match=\(e.frontmostMatchesTarget ? 1 : 0) "
            line += "key=\(e.frontmostHasKeyWindow ? 1 : 0) secure=\(e.secureInputEnabled ? 1 : 0)"
            if !e.note.isEmpty { line += " \(e.note)" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Plain-text dump for the pasteboard (same body as `dump()`).
    func pasteboardString() -> String { dump() }
}
