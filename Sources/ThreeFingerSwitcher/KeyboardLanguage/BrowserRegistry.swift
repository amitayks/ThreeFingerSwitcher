import Foundation

/// The two scripting families a supported browser belongs to (design D5). Within a family the
/// Apple Events vocabulary and AX address-bar layout are uniform, so the host readers branch on the
/// `BrowserFamily` rather than on each bundle id: Safari speaks "current tab of front window", the
/// Chromium forks speak "active tab of front window".
enum BrowserFamily {
    /// Apple's Safari — registrable-domain only in its address bar under the AX reader (design D7).
    case safari
    /// The Chromium forks (Chrome, Brave, Edge, Arc, Vivaldi) — full host in the omnibox under AX.
    case chromium
}

/// The fixed, pure table of browsers the per-site feature recognizes (design D5). It maps a bundle id
/// to its `BrowserFamily`; an app absent from the table is not a supported browser and so uses per-app
/// behavior unchanged (Firefox has no scriptable URL and is deliberately omitted — best-effort/unsupported).
///
/// This is intentionally a small static table with no AppKit/Carbon/AX dependency, so it compiles and
/// unit-tests under `swift build` / `swift test` in the MLX-free Core. `ContextResolver` consults it to
/// decide whether to resolve a host at all; the host readers consult `family(for:)` to pick the right
/// AX layout / Apple Events vocabulary.
enum BrowserRegistry {
    /// Bundle id → scripting family for every supported browser. Anything not present is unsupported.
    static let families: [String: BrowserFamily] = [
        "com.apple.Safari": .safari,
        "com.google.Chrome": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "company.thebrowser.Browser": .chromium,   // Arc
        "com.vivaldi.Vivaldi": .chromium,
    ]

    /// Whether `bundleID` is a supported browser the per-site feature applies to. Firefox and every
    /// non-browser app are unsupported (false), so the caller keeps per-app, bundle-id-only behavior.
    static func isSupported(_ bundleID: String) -> Bool {
        families[bundleID] != nil
    }

    /// The scripting family for `bundleID`, or nil when it is not a supported browser. Lets the host
    /// readers branch on `.safari` vs `.chromium` without re-checking each individual bundle id.
    static func family(for bundleID: String) -> BrowserFamily? {
        families[bundleID]
    }

    /// A short, human-friendly name for a supported browser bundle id, for the Hub's saved-sites list
    /// (so a row reads "keep.google.com · Chrome", not a reverse-DNS id). Falls back to the bundle id
    /// for anything not in the table.
    static let displayNames: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "company.thebrowser.Browser": "Arc",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// The friendly browser name for `bundleID`, or the bundle id itself when it isn't a known browser.
    static func displayName(for bundleID: String) -> String {
        displayNames[bundleID] ?? bundleID
    }
}
