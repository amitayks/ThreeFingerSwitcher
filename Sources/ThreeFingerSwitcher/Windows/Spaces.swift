import Foundation
import CoreGraphics

/// Space (virtual desktop) model built from private CGS APIs. All access goes through the
/// dlsym-resolved `cgs`; callers must first check `cgs.offSpaceSupported`.
struct SpaceModel {
    /// All Space ids in display/Mission-Control order.
    let orderedSpaceIDs: [CGSSpaceID]
    /// Space ids that are currently active (one per display).
    let currentSpaceIDs: Set<CGSSpaceID>
    /// spaceID → order index (for cross-Space ordering tiebreaks).
    let indexBySpace: [CGSSpaceID: Int]
}

enum SpaceService {
    /// Build the ordered Space list + current Spaces from `CGSCopyManagedDisplaySpaces`.
    static func currentModel() -> SpaceModel? {
        guard let mainConn = cgs.mainConnectionID,
              let copySpaces = cgs.copyManagedDisplaySpaces else { return nil }
        let cid = mainConn()
        guard let displays = copySpaces(cid) as? [[String: Any]] else { return nil }

        var ordered: [CGSSpaceID] = []
        var index: [CGSSpaceID: Int] = [:]
        var current: Set<CGSSpaceID> = []

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
            if let cur = display["Current Space"] as? [String: Any],
               let id = (cur["id64"] as? NSNumber)?.uint64Value {
                current.insert(id)
            }
            if let identifier = display["Display Identifier"] as? String,
               identifier != "Main",
               let getCurrent = cgs.managedDisplayGetCurrentSpace {
                let apiCur = getCurrent(cid, identifier as CFString)
                if apiCur != 0 { current.insert(apiCur) }
            }
        }

        guard !ordered.isEmpty else { return nil }
        return SpaceModel(orderedSpaceIDs: ordered, currentSpaceIDs: current, indexBySpace: index)
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
        guard let wins = copyWindows(cid, 0, spaces, 7, &setTags, &clearTags) as? [NSNumber] else { return [] }
        return wins.map { $0.uint32Value }
    }
}
