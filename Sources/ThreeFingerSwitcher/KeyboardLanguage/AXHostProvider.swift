import AppKit
import ApplicationServices

/// The default `HostProvider`: reads the frontmost browser window's address-bar text and parses it to a
/// host using the **Accessibility** API the app already holds — so the per-site feature works with **no
/// new permission** (design D3, the no-Automation default path). It is best-effort by nature: every
/// browser lays out its toolbar AX subtree differently and the address bar's exposed value shifts with
/// focus/edit state, so this code searches defensively and returns nil the moment anything is ambiguous
/// rather than risk learning under a wrong key (design D4 / the "never guess" rule).
///
/// **Guards (design D3 / spec):**
/// - *Focused / being edited* — when the address field is the window's `kAXFocusedUIElement`, its value
///   is the user's in-progress typed text, not a committed host, so we return nil (the typing scenario).
/// - *Private / incognito* — a best-effort window/title heuristic; when it even *might* be private we
///   return nil rather than record a private host (design D9 / "if unsure, don't read").
///
/// **Known limitation (design D7, expected — not a bug):** Safari's address bar shows only the
/// registrable domain (the subdomain is hidden in the UI), so on Safari this yields domain-level keys —
/// `keep.` and `mail.google.com` collapse to `google.com`. Chrome/Chromium expose the full host in the
/// omnibox, so they get host-level precision here. The `AppleEventsHostProvider` opt-in is the path to
/// exact per-host on Safari.
@MainActor
final class AXHostProvider: HostProvider {

    /// The frontmost app, injectable so the AX traversal is exercisable without a real running browser.
    private let frontmostApp: () -> NSRunningApplication?

    init(frontmostApp: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.frontmostApp = frontmostApp
    }

    /// Read `bundleID`'s active-tab host off the address bar via Accessibility, or nil when it can't be
    /// resolved cleanly (no front window, address bar not found, being typed in, private window, or the
    /// value doesn't normalize to a host). nil is the app-level-fallback signal, never an error.
    func host(forBrowser bundleID: String) -> String? {
        // Only read the browser we were asked about while it is genuinely frontmost — the caller resolves
        // off the frontmost app, so a mismatch means stale state; don't read someone else's window.
        guard let app = frontmostApp(),
              app.bundleIdentifier == bundleID,
              let window = focusedWindow(pid: app.processIdentifier)
        else { return nil }

        // Guard: never record a private/incognito window's host (best-effort; "if unsure, skip").
        guard !looksPrivate(window) else { return nil }

        guard let field = addressField(in: window) else { return nil }

        // Guard: if the address field is the focused element, its value is the user's typed text mid-edit,
        // not a committed host — treat as no-host so we never learn/apply from a half-typed URL.
        guard !isBeingEdited(field, in: window) else { return nil }

        guard let raw = axString(field, kAXValueAttribute as String) else { return nil }
        return HostNormalizer.normalize(raw)
    }

    // MARK: - Window resolution

    /// The browser's focused (else main) window AX element, or nil. Mirrors how the app's other AX
    /// readers reach the front window (`kAXFocusedWindow` first, `kAXMainWindow` as fallback).
    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        return axChild(appEl, kAXFocusedWindowAttribute as String)
            ?? axChild(appEl, kAXMainWindowAttribute as String)
    }

    /// Read an `AXUIElement`-valued attribute (a single child element such as the focused window or the
    /// focused UI element) off `element`, type-checked against `AXUIElementGetTypeID()`. The shared
    /// `axCopy` returns an untyped `CFTypeRef`; this is the single chokepoint for the element cast.
    private func axChild(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    // MARK: - Address-bar search

    /// Find the window's address-bar text field. Browser AX trees vary, so this is heuristic and
    /// defensive: we breadth-first walk the window subtree (depth-bounded so a deep toolbar can't stall
    /// us) and pick the first `AXTextField` that carries a URL-ish identifier/description. Returns nil
    /// when nothing convincingly looks like the address bar — the caller then falls back to app-level.
    private func addressField(in window: AXUIElement) -> AXUIElement? {
        var frontier: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        // Bound the walk: address bars sit near the top of the toolbar, so a shallow, capped search keeps
        // this to a few AX round-trips even on a busy page (no full-tree descent into web content).
        while !frontier.isEmpty, visited < maxElementsVisited {
            let (element, depth) = frontier.removeFirst()
            visited += 1

            if depth >= 1, axString(element, kAXRoleAttribute as String) == (kAXTextFieldRole as String),
               looksLikeAddressBar(element) {
                return element
            }

            guard depth < maxSearchDepth,
                  let children = axCopy(element, kAXChildrenAttribute as String) as? [AXUIElement]
            else { continue }
            for child in children { frontier.append((child, depth + 1)) }
        }
        return nil
    }

    /// Whether a text field is plausibly the address bar, by its AX identifier / role-description /
    /// placeholder. Chromium exposes `AXIdentifier == "address and search bar"`-style hints; Safari's
    /// field carries an address/URL-flavored description. We accept on any of these soft signals and
    /// otherwise reject — better to miss the bar (fall back to app-level) than to read the wrong field.
    private func looksLikeAddressBar(_ field: AXUIElement) -> Bool {
        let hints = [
            axString(field, kAXIdentifierAttribute as String),
            axString(field, kAXRoleDescriptionAttribute as String),
            axString(field, kAXDescriptionAttribute as String),
            axString(field, kAXPlaceholderValueAttribute as String),
        ]
        return hints.compactMap { $0?.lowercased() }.contains { hint in
            addressBarMarkers.contains { hint.contains($0) }
        }
    }

    // MARK: - Guards

    /// Whether the address field is currently focused / being edited: if the window's
    /// `kAXFocusedUIElement` *is* this field, the user is typing into it and its value is their
    /// in-progress text, not a host. We compare AX element identity via `CFEqual`.
    private func isBeingEdited(_ field: AXUIElement, in window: AXUIElement) -> Bool {
        guard let focused = axChild(window, kAXFocusedUIElementAttribute as String) else { return false }
        return CFEqual(focused, field)
    }

    /// Best-effort private/incognito detection from the window's AX title/subrole. Private and incognito
    /// windows mark themselves in their title ("Private", "Incognito", "InPrivate") across the supported
    /// families; this is intentionally conservative — any whiff of a private marker returns true so we
    /// skip the read entirely (design D9: never record a private host; prefer a false skip to a leak).
    private func looksPrivate(_ window: AXUIElement) -> Bool {
        guard let title = axString(window, kAXTitleAttribute as String)?.lowercased() else { return false }
        return privateMarkers.contains { title.contains($0) }
    }

    // MARK: - Tuning constants

    /// Cap on how deep we descend the window subtree hunting for the toolbar/address bar. The address
    /// bar lives in the toolbar a handful of levels under the window; this keeps us out of the web area.
    private let maxSearchDepth = 8
    /// Hard cap on AX elements inspected per read, so a pathological tree can't turn one poll tick into a
    /// long stall (the search is breadth-first, so the budget is spent nearest the window root first).
    private let maxElementsVisited = 400

    /// Soft lowercase substrings that mark a text field as the address/search bar across browser families.
    private let addressBarMarkers = ["address", "url", "location", "search or enter", "omnibox"]
    /// Lowercase title markers that flag a private/incognito window across the supported families.
    private let privateMarkers = ["private", "incognito", "inprivate"]
}
