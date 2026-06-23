import Foundation

/// The user-visible, user-editable trust boundary (`ai-background-autonomy`, design Decision 3). A pure
/// value type + pure matching rules, persisted in `AppSettings`. Default-empty for arbitrary entries — a
/// fresh install trusts nothing on the wider filesystem; the app's own memory + project stores are
/// CONTAINED (`BlastRadius`), so they are auto WITHOUT any whitelist row. MLX-free Core.
public struct Whitelist: Codable, Equatable, Sendable {
    /// Standardized absolute path prefixes the user trusts for writes (component-boundary match).
    public var trustedPathPrefixes: [String]
    /// Glob patterns (`*`/`?`, anchored full-string) matched against a command / tool / Shortcut name or
    /// a shell command's `argv[0]`.
    public var trustedCommandPatterns: [String]

    public init(trustedPathPrefixes: [String] = [], trustedCommandPatterns: [String] = []) {
        self.trustedPathPrefixes = trustedPathPrefixes
        self.trustedCommandPatterns = trustedCommandPatterns
    }

    /// The default: trusts nothing arbitrary.
    public static let empty = Whitelist(trustedPathPrefixes: [], trustedCommandPatterns: [])

    // MARK: - Matching (pure, unit-tested)

    /// A **path target** matches iff its standardized absolute path has one of `trustedPathPrefixes` as a
    /// **path-component prefix** (design Decision 3): `/Users/me/Notes` matches `/Users/me/Notes/x.md`
    /// but NOT `/Users/me/Notes2` (component boundary, never a bare string prefix). `..`/symlinks are
    /// resolved (`standardizedFileURL`/`resolvingSymlinksInPath`) BEFORE matching, so
    /// `/trusted/../etc/passwd` cannot sneak past `/trusted`.
    public func matchesPath(_ rawPath: String) -> Bool {
        let target = Whitelist.standardize(rawPath)
        guard !target.isEmpty else { return false }
        for prefix in trustedPathPrefixes {
            let std = Whitelist.standardize(prefix)
            guard !std.isEmpty else { continue }
            if Whitelist.isComponentPrefix(std, of: target) { return true }
        }
        return false
    }

    /// A **command target** matches iff it matches one of `trustedCommandPatterns` as an anchored
    /// `fnmatch`-style glob (`*`/`?`), full-string (design Decision 3): `git*` matches `git`, not
    /// `forgit`.
    public func matchesCommand(_ command: String) -> Bool {
        trustedCommandPatterns.contains { Whitelist.globMatch(pattern: $0, name: command) }
    }

    /// The **both-rule** (design Decision 3): a target that is BOTH a command and a path must match a
    /// command pattern AND a path prefix — the stricter wins. A whitelisted command aimed at an off-list
    /// path does NOT match.
    public func matchesBoth(command: String, path: String) -> Bool {
        matchesCommand(command) && matchesPath(path)
    }

    // MARK: - Pure helpers

    /// Standardize a path: expand `~`, resolve symlinks + `..`, and drop a trailing slash. An absolute
    /// path standardizes in place; a relative one resolves against the working dir (rare for a write
    /// target, but never crashes).
    static func standardize(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var path = url.path
        // `resolvingSymlinksInPath` on macOS prefixes `/private` for some temp dirs; keep it — both the
        // prefix and the target standardize the same way, so a consistent representation is what matters.
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// True iff `prefix` is `target` or an ancestor directory of `target` at a path-component boundary.
    static func isComponentPrefix(_ prefix: String, of target: String) -> Bool {
        if prefix == target { return true }
        // Component boundary: `target` must continue with a `/` right after the full prefix.
        let boundary = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return target.hasPrefix(boundary)
    }

    /// Anchored `fnmatch`-style glob (`*` = any run, `?` = one char), full-string. A small pure matcher
    /// (no `fnmatch(3)` dependency / locale surprises) so it is deterministic and testable.
    static func globMatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let s = Array(name)
        // Classic DP / two-pointer glob with backtracking.
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = si; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
