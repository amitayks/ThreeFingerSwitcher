import AppKit
import CoreGraphics

/// Builds the **synthetic** switcher entry for the app's own configuration Hub window, and answers the
/// "is this window the Hub?" commit decision. Factored out of `AppCoordinator` so the inclusion rule
/// and Space placement are unit-testable without any AppKit window/CGS state.
///
/// Why synthetic: `WindowService.snapshot()` deliberately filters out our own PID (so the overlay
/// panels never leak into the switcher). The Hub is the one exception — when it is open we add it back
/// on purpose, icon-only, on the Space it was opened on, so it is reachable from the switcher while the
/// app stays in accessory mode (no activation-policy change).
enum HubSwitcherEntry {
    /// Build the synthetic Hub `WindowInfo` to inject into a snapshot, or `nil` when the Hub should not
    /// appear (it is not open). The entry carries no AX element (`nil`) and no thumbnail; the switcher
    /// renders the app icon as the fallback card image.
    ///
    /// Space placement: the Hub stays on the Space it was opened on (it does NOT join all Spaces), so
    /// the card must land in that Space's row. We copy the `spaceID`/`spaceIndex`/`isOnCurrentSpace` of
    /// any snapshot window already on `hubSpaceID` (the most reliable match for the row's index); if no
    /// snapshot window shares that Space, we fall back to the current Space (`currentSpaceID` /
    /// `currentSpaceIndex`) so the card is at least on a valid row.
    ///
    /// - Parameters:
    ///   - isVisible: whether the Hub window is currently visible (the inclusion gate).
    ///   - windowNumber: the Hub `NSWindow.windowNumber` — a usable `CGWindowID` and the stable id the
    ///     commit branch recognizes.
    ///   - appName: the app name for the card title (`"<appName> Hub"`).
    ///   - icon: the app icon shown on the card (the switcher's no-thumbnail fallback).
    ///   - hubSpaceID: the Space the Hub was opened on (captured when it was presented), or `nil`.
    ///   - snapshot: the current all-Spaces window snapshot (to copy a matching Space-row's index).
    ///   - currentSpaceID: the active Space id (fallback when the Hub's Space has no other window).
    ///   - currentSpaceIndex: the active Space's Mission Control index (fallback).
    static func make(
        isVisible: Bool,
        windowNumber: Int,
        appName: String,
        icon: NSImage?,
        hubSpaceID: CGSSpaceID?,
        snapshot: [WindowInfo],
        currentSpaceID: CGSSpaceID?,
        currentSpaceIndex: Int
    ) -> WindowInfo? {
        guard isVisible else { return nil }

        // Prefer a snapshot window already on the Hub's Space — it gives us the exact row index and
        // the authoritative isOnCurrentSpace flag for that Space.
        let sibling = hubSpaceID.flatMap { hubSpace in
            snapshot.first { $0.spaceID == hubSpace }
        }

        let spaceID: CGSSpaceID?
        let spaceIndex: Int
        let isOnCurrentSpace: Bool
        if let sibling {
            spaceID = sibling.spaceID
            spaceIndex = sibling.spaceIndex
            isOnCurrentSpace = sibling.isOnCurrentSpace
        } else if let hubSpaceID {
            // No co-resident window: use the Hub's captured Space. It is the current Space iff it
            // equals the active Space id.
            spaceID = hubSpaceID
            isOnCurrentSpace = (currentSpaceID != nil && hubSpaceID == currentSpaceID)
            spaceIndex = isOnCurrentSpace ? currentSpaceIndex : currentSpaceIndex
        } else {
            // No captured Space at all (legacy / off-Space support unavailable): land on the current
            // Space so the card is reachable rather than dropped.
            spaceID = currentSpaceID
            spaceIndex = currentSpaceIndex
            isOnCurrentSpace = true
        }

        return WindowInfo(
            id: CGWindowID(windowNumber),
            pid: getpid(),
            appName: appName,
            title: "\(appName) Hub",
            appIcon: icon,
            frame: .zero,
            realFrame: .zero,
            axElement: nil,
            isOnCurrentSpace: isOnCurrentSpace,
            spaceID: spaceID,
            spaceIndex: spaceIndex
        )
    }

    /// Whether the given selected-window id is the Hub's window (so the commit branch focuses our own
    /// window via `present` instead of the cross-Space SkyLight raise). A `nil` `windowNumber` (the Hub
    /// was never created) never matches.
    static func isHub(selectedID: CGWindowID, hubWindowNumber: Int?) -> Bool {
        guard let hubWindowNumber else { return false }
        return selectedID == CGWindowID(hubWindowNumber)
    }
}
