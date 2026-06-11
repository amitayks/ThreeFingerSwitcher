import Foundation

/// The single source of truth for the shape of the engine's context key (design D1). The per-app and
/// per-site features share one `[contextKey: InputSourceID]` map: a normal app is keyed by its bundle id
/// (`com.telegram`), a browser context by `bundleID|host` (`com.google.Chrome|keep.google.com`). Every
/// place that builds a key — the resolver, and through it the learn/apply paths — funnels through
/// `make` so the format can never drift between writers and readers.
///
/// Pure (no AppKit/Carbon/AX), so it compiles and unit-tests under `swift build` / `swift test`.
enum ContextKey {
    /// The separator between bundle id and host. `|` cannot appear in a reverse-DNS bundle id (or a
    /// hostname), so the key parses unambiguously and a per-app key can never collide with a per-site one.
    static let separator = "|"

    /// Build the context key for `bundleID` optionally scoped to `host`. With no host (a normal app, or
    /// a browser whose host didn't resolve cleanly — D2/D4) the key is the bare bundle id, so the
    /// per-app behavior is byte-for-byte identical. An empty host is treated as no host (never produces a
    /// trailing-separator key). Otherwise the key is `"\(bundleID)\(separator)\(host)"`.
    static func make(bundleID: String, host: String?) -> String {
        guard let host, !host.isEmpty else { return bundleID }
        return "\(bundleID)\(separator)\(host)"
    }

    /// Whether `key` is a per-site (browser host) key rather than a bare per-app bundle id — i.e. it
    /// carries a host segment. The engine and the Hub's saved-sites list use this to tell the two kinds
    /// of entry apart in the one shared map.
    static func isSiteKey(_ key: String) -> Bool {
        key.contains(separator)
    }

    /// The host segment of a per-site key (`"com.google.Chrome|keep.google.com"` → `"keep.google.com"`),
    /// or nil for a bare per-app key. Splits on the first separator only (hosts/bundle ids contain none).
    static func host(from key: String) -> String? {
        guard let range = key.range(of: separator) else { return nil }
        let host = String(key[range.upperBound...])
        return host.isEmpty ? nil : host
    }

    /// The bundle-id segment of a key (`"com.google.Chrome|keep.google.com"` → `"com.google.Chrome"`),
    /// or the whole key for a bare per-app key.
    static func bundleID(from key: String) -> String {
        guard let range = key.range(of: separator) else { return key }
        return String(key[..<range.lowerBound])
    }
}
