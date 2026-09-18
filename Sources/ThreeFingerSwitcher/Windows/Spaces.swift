import Foundation
import CoreGraphics

/// Space (virtual desktop) model built from private CGS APIs. All access goes through the
/// dlsym-resolved `cgs`; callers must first check `cgs.offSpaceSupported`.
struct SpaceModel {
    /// All Space ids in display/Mission-Control order.
    let orderedSpaceIDs: [CGSSpaceID]
    /// Space ids that are currently active (one per display). For MEMBERSHIP tests only — it is a Set,
    /// so `.first` is hash-order arbitrary on a multi-display Mac; when one Space must stand for "the"
    /// current Space, use `primaryCurrentSpaceID`.
    let currentSpaceIDs: Set<CGSSpaceID>
    /// The current Space of the FIRST display in the `CGSCopyManagedDisplaySpaces` array (the "Main"
    /// display comes first), so it is deterministic across calls and displays. `nil` only when no display
    /// reported a current Space (then `currentSpaceIDs` is empty too).
    let primaryCurrentSpaceID: CGSSpaceID?
    /// spaceID → order index (for cross-Space ordering tiebreaks).
    let indexBySpace: [CGSSpaceID: Int]
}

enum SpaceService {
    /// Build the ordered Space list + current Spaces from `CGSCopyManagedDisplaySpaces`.
    static func currentModel() -> SpaceModel? {
        guard let mainConn = cgs.mainConnectionID,
              let copySpaces = cgs.copyManagedDisplaySpaces else { return nil }
        let cid = mainConn()
        // `Copy` = +1: take the retained value, or the array leaks on every call (see CGSPrivate.swift).
        guard let displays = copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        return model(fromDisplays: displays) { identifier in
            guard let getCurrent = cgs.managedDisplayGetCurrentSpace else { return nil }
            let id = getCurrent(cid, identifier as CFString)
            return id != 0 ? id : nil
        }
    }

    /// Pure model builder over the `CGSCopyManagedDisplaySpaces` dictionary array — one dict per display,
    /// in display order, each with `Spaces: [{id64}]`, `Current Space: {id64}` and a `Display Identifier` —
    /// so the selection rules are unit-testable without the private API. `apiCurrentSpace` refines the
    /// current Space of a REAL display UUID via `CGSManagedDisplayGetCurrentSpace` (return `nil` when the
    /// API is unavailable or answers 0); it is never asked about the "Main" sentinel.
    static func model(
        fromDisplays displays: [[String: Any]],
        apiCurrentSpace: (String) -> CGSSpaceID? = { _ in nil }
    ) -> SpaceModel? {
        var ordered: [CGSSpaceID] = []
        var index: [CGSSpaceID: Int] = [:]
        var current: Set<CGSSpaceID> = []
        var primary: CGSSpaceID?

        for display in displays {
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    if let id = (space["id64"] as? NSNumber)?.uint64Value, index[id] == nil {
                        index[id] = ordered.count
                        ordered.append(id)
                    }
                }
            }
            // Current Space: the dict is authoritative (always read it); refine via the API for
            // real display UUIDs. The "Main" sentinel is not a valid UUID for the API (returns 0),
            // so skip the API for it — the dict already provided the current Space.
            var displayCurrent: CGSSpaceID?
            if let cur = display["Current Space"] as? [String: Any],
               let id = (cur["id64"] as? NSNumber)?.uint64Value {
                current.insert(id)
                displayCurrent = id
            }
            if let identifier = display["Display Identifier"] as? String,
               identifier != "Main",
               let apiCur = apiCurrentSpace(identifier) {
                current.insert(apiCur)
                if displayCurrent == nil { displayCurrent = apiCur }
            }
            // The primary is the FIRST display's current Space (its dict value, the API as fallback);
            // a display that reports none is skipped so a later one can still supply it.
            if primary == nil { primary = displayCurrent }
        }

        guard !ordered.isEmpty else { return nil }
        return SpaceModel(orderedSpaceIDs: ordered, currentSpaceIDs: current,
                          primaryCurrentSpaceID: primary, indexBySpace: index)
    }

    /// Ordered window ids on a given Space (front-to-back), via `CGSCopyWindowsWithOptionsAndTags`.
    static func windowsInSpace(_ spaceID: CGSSpaceID) -> [CGWindowID] {
        guard let mainConn = cgs.mainConnectionID,
              let copyWindows = cgs.copyWindowsWithOptionsAndTags else { return [] }
        let cid = mainConn()
        var setTags = 0
        var clearTags = 0
        let spaces = [spaceID] as CFArray
        // options 7 = screenSaverLevel1000 | invisible1 | invisible2 (AltTab includeInvisible=true):
        // includes minimized/hidden/invisible windows on off-Spaces, not just visible ones.
        // `Copy` = +1: take the retained value, or the array leaks on every call (see CGSPrivate.swift).
        guard let wins = copyWindows(cid, 0, spaces, 7, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return wins.map { $0.uint32Value }
    }
}
