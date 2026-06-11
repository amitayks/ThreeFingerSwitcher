import Foundation

/// Canonicalizes a raw host string (from the AX address bar or an Apple Events URL) into the stable
/// host segment the engine keys on (design D2). The goal is that two spellings of the same site — with
/// or without `www.`, in different case, with a trailing dot — collapse to one key, so a learned source
/// isn't split across near-duplicate hosts.
///
/// Host-level, **not** registrable-domain (design D2): this does no public-suffix / eTLD+1 computation,
/// so `keep.google.com` and `mail.google.com` stay distinct. A registrable-domain-only string (what
/// Safari's address bar yields under the AX reader, D7) is passed through with the same lightweight
/// cleanup and used as-is. Pure (no I/O), so it compiles and unit-tests under `swift build` / `swift test`.
enum HostNormalizer {
    /// Normalize `raw` to a canonical host, or nil if it isn't usably a host. `raw` may be a bare host
    /// (`web.whatsapp.com`), a host with a path (`claude.ai/chat/1552f48` — what an omnibox shows on a
    /// sub-page), or a full URL (`https://claude.ai/chat/1552f48`). Steps:
    /// 1. trim; reject our own key separator `|` outright (never learn under a key-shaped value);
    /// 2. **extract just the host** — scheme, path, query and fragment are stripped, so a sub-page keys on
    ///    its root host exactly like the root page does (this is the whole point: the language is set on,
    ///    and matched against, the host root — not the URL);
    /// 3. lowercase (hosts are case-insensitive), drop a trailing `.` (fully-qualified DNS form), strip one
    ///    leading `www.` (`www.google.com` and `google.com` are the same site);
    /// 4. require a dotted host — this rejects internal pages and the new-tab page (`chrome://newtab` →
    ///    `newtab`, no dot) and stray search words, so the caller falls back to the app-level context
    ///    rather than learn under a bad key (design D4 guard).
    static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(ContextKey.separator) else { return nil }

        guard var host = extractHost(from: trimmed)?.lowercased() else { return nil }

        if host.hasSuffix(".") { host.removeLast() }        // fully-qualified DNS form
        if host.hasPrefix("www.") { host.removeFirst(4) }   // www alias == bare site

        // A real site host is dotted; this filters chrome://newtab → "newtab", search terms, etc. Path/
        // whitespace can't survive host extraction, but guard anyway so a bad value never becomes a key.
        guard host.contains("."),
              !host.contains(where: \.isWhitespace),
              !host.contains("/")
        else { return nil }

        return host
    }

    /// Pull the host out of a bare host / host+path / full-URL string. Tries to parse it as a URL; when
    /// there is no scheme (a bare host or `host/path`) it prepends `https://` so `URLComponents` can find
    /// the host. Returns nil for anything `URLComponents` can't resolve a host from.
    private static func extractHost(from s: String) -> String? {
        if let host = URLComponents(string: s)?.host, !host.isEmpty { return host }
        if let host = URLComponents(string: "https://\(s)")?.host, !host.isEmpty { return host }
        return nil
    }
}
