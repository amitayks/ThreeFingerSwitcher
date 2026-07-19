import Foundation
import ApplicationServices

/// The observable facts about one window candidate, gathered at the AX boundary by `WindowService`
/// so every listing decision below is pure and unit-testable without Accessibility.
struct WindowCandidate: Equatable {
    var role: String?
    var subrole: String?        // nil when the app reports none
    var title: String?          // AX title; nil or empty ⇒ untitled
    var size: CGSize            // the Accessibility (real) size, not the CGWindowList bounds
    var hasCloseButton: Bool    // window chrome — a real window has a close button, helper frames don't
    var isMinimized: Bool
}

/// Per-app override of the global filtering policy, keyed by bundle identifier (falling back to
/// executable name — Qt/CLI-hosted apps like the Android emulator can lack a bundle ID). Absence of
/// a rule means the app follows the global strict/relaxed policy.
enum WindowAppRule: String, Codable, CaseIterable, Identifiable {
    /// List every window-role element of the app — bypasses the junk heuristics AND duplicate
    /// suppression (only the degenerate-size floor still applies). The escape hatch when the
    /// heuristics are wrong for an app.
    case include
    /// Standard-subrole windows only, regardless of the global relaxed toggle.
    case strict
    /// List no windows of this app.
    case exclude

    var id: String { rawValue }
}

/// The policy a verdict is computed under: the two global toggles plus the app's rule (if any).
struct WindowFilterPolicy: Equatable {
    var relaxed: Bool               // includeNonStandardWindows
    var includeMinimized: Bool      // includeMinimizedWindows
    var appRule: WindowAppRule?

    init(relaxed: Bool, includeMinimized: Bool, appRule: WindowAppRule? = nil) {
        self.relaxed = relaxed
        self.includeMinimized = includeMinimized
        self.appRule = appRule
    }
}

/// Why a candidate was not listed — the shared vocabulary of the filter and the Window Inspector,
/// so the two can never disagree about the reason a window is absent.
enum WindowDropReason: String, Equatable {
    case appExcluded          // per-app `exclude` rule
    case minimized            // minimized without the include-minimized opt-in
    case notAWindow           // AX role is not a window
    case degenerateSize       // sliver/zero frame (relaxed mode / include rule)
    case junkSubrole          // known floating-palette subrole (relaxed mode)
    case phantom              // unknown subrole, untitled, chromeless, small — a frame, not a window
    case nonStandardSubrole   // strict mode: subrole is not the standard window subrole
}

enum WindowFilterVerdict: Equatable {
    case listed
    case dropped(WindowDropReason)
}

/// The switchability decision (see design D1/D2): strict mode is byte-identical to the historical
/// gate; relaxed mode is three-tier — a known-real subrole allowlist, a known-junk denylist, and
/// real-window discriminators for the unknown middle — and is monotonic over strict (relaxation can
/// only ever ADD windows, never drop one strict would list; the old `both dims ≥ 100` gate broke
/// exactly that for small standard windows like Finder's copy-progress).
enum WindowFilter {

    /// Below this minimum side a frame is degenerate (a sliver/zero frame) — dropped in relaxed
    /// mode and under the `include` rule before anything else. Well below any real window, including
    /// compact progress windows.
    static let degenerateFloor: CGFloat = 40

    /// Subroles macOS itself uses for real user-facing windows — trusted outright in relaxed mode.
    static let realSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String,
        kAXSystemDialogSubrole as String,
    ]

    /// True palette/HUD subroles — never switch targets. The layer-0 gate catches most; this
    /// catches layer-0 oddballs.
    static let junkSubroles: Set<String> = [
        kAXFloatingWindowSubrole as String,
        kAXSystemFloatingWindowSubrole as String,
    ]

    static func verdict(_ c: WindowCandidate, policy: WindowFilterPolicy) -> WindowFilterVerdict {
        if policy.appRule == .exclude { return .dropped(.appExcluded) }
        if c.isMinimized && !policy.includeMinimized { return .dropped(.minimized) }
        guard c.role == (kAXWindowRole as String) else { return .dropped(.notAWindow) }

        let minSide = min(c.size.width, c.size.height)

        if policy.appRule == .include {
            return minSide < degenerateFloor ? .dropped(.degenerateSize) : .listed
        }

        let strict = policy.appRule == .strict || !policy.relaxed
        if strict {
            // The historical gate, unchanged: standard subrole (or none reported) lists.
            guard let subrole = c.subrole else { return .listed }
            return subrole == (kAXStandardWindowSubrole as String) ? .listed : .dropped(.nonStandardSubrole)
        }

        // Relaxed: three tiers over a degenerate floor.
        if minSide < degenerateFloor { return .dropped(.degenerateSize) }
        if let subrole = c.subrole {
            if realSubroles.contains(subrole) { return .listed }
            if junkSubroles.contains(subrole) { return .dropped(.junkSubrole) }
            // Known-nothing subrole (AXUnknown, novel toolkit values): a real window shows identity —
            // a title or chrome. Size proves NOTHING: the AirDrop share popover births untitled,
            // chromeless clones of the host window at its exact 316×601 frame (three per attempt,
            // Finder-owned, lingering after dismissal — live-probed 2026-07-19), so any "big enough
            // to be real" bar admits them forever. A titleless-but-real oddball is recovered via the
            // per-app `include` rule, visibly, in the inspector — not by a heuristic that guesses.
            let titled = !(c.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return titled || c.hasCloseButton ? .listed : .dropped(.phantom)
        }
        // No subrole reported at all: strict mode lists these, so relaxed must too (monotonicity).
        return .listed
    }

    // MARK: - Phantom-duplicate suppression (design D3)

    /// The identity key: phantom clones (the AirDrop send popup's 4-per-window frames) are EXACT
    /// duplicates — same app, same title, same integral real frame, same minimized state. Exactness
    /// keeps false positives implausible; fuzzy containment was rejected (kills real PiP layouts).
    struct DedupeKey: Hashable {
        let pid: pid_t
        let title: String
        let x: Int, y: Int, w: Int, h: Int
        let isMinimized: Bool

        init(pid: pid_t, title: String?, frame: CGRect, isMinimized: Bool) {
            self.pid = pid
            self.title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.x = Int(frame.origin.x.rounded())
            self.y = Int(frame.origin.y.rounded())
            self.w = Int(frame.width.rounded())
            self.h = Int(frame.height.rounded())
            self.isMinimized = isMinimized
        }
    }

    /// Collapse each identity group to its front-most member (lowest `rank`: z-order where known,
    /// stable window id where not). Order-preserving for the survivors. `exemptPids` (apps with the
    /// `include` rule) bypass suppression entirely, and so does a zero-area frame — a frame that
    /// did not resolve (an off-Space AX read failure) carries no geometric identity, so two unrelated
    /// windows with unreadable frames must never collapse into one.
    static func dedupe<T>(_ rows: [T],
                          exemptPids: Set<pid_t> = [],
                          key: (T) -> DedupeKey,
                          rank: (T) -> Int) -> [T] {
        var bestRank: [DedupeKey: Int] = [:]
        for row in rows {
            let k = key(row)
            guard !exemptPids.contains(k.pid), k.w > 0, k.h > 0 else { continue }
            let r = rank(row)
            if let existing = bestRank[k], existing <= r { continue }
            bestRank[k] = r
        }
        return rows.filter { row in
            let k = key(row)
            if exemptPids.contains(k.pid) || k.w <= 0 || k.h <= 0 { return true }
            return bestRank[k] == rank(row)
        }
    }
}
