import AppKit
import CoreGraphics

/// Classifies where an app's window(s) live relative to the current Space, so `LaunchService` can
/// pick a teleport-safe action for a single-window app.
///
/// Important macOS constraint (verified on-device): an app **without** SIP partially disabled cannot
/// move another process's window between Spaces. `SLSMoveWindowsToManagedSpace`, `CGSAddWindowsToSpaces`,
/// and even an AX minimize on an off-Space window all return success yet have no effect. So "bring the
/// window to you" is not achievable for foreign windows; the best we can do is *detect* the situation
/// precisely and let the caller decide (focus it in place by switching Spaces, or quit+reopen here).
///
/// Enumeration uses the private per-Space CGS API (`SpaceService`) — unlike `CGWindowListCopyWindowInfo`
/// it reliably sees windows on *other* Spaces, which is what lets us tell `.broughtHere` (a window is
/// already here) from `.failed` (it exists only off-Space) from `.noWindows`.
@MainActor
struct SpaceWindowMover: WindowRelocating {
    func relocate(pid: pid_t) -> RelocateResult {
        guard let model = SpaceService.currentModel() else { return .failed }
        let owned = ownedWindows(pid: pid, model: model)
        if owned.isEmpty { return .noWindows }
        // A window is already on the current Space → the caller can focus it locally (no teleport).
        if owned.contains(where: { model.currentSpaceIDs.contains($0.space) }) { return .broughtHere }
        // Window(s) exist only off-Space. macOS won't let us move a foreign window here, so report
        // failure; the caller falls back to a deliberate "go to the window" (or quit+reopen).
        return .failed
    }

    /// `(wid, space)` for `pid`'s normal (layer-0, non-tiny) windows across all Spaces, via the
    /// per-Space CGS enumeration the rest of the app trusts — `CGWindowListCopyWindowInfo` can miss
    /// off-Space windows.
    private func ownedWindows(pid: pid_t, model: SpaceModel) -> [(wid: CGWindowID, space: CGSSpaceID)] {
        var spaceForWid: [CGWindowID: CGSSpaceID] = [:]
        for space in model.orderedSpaceIDs {
            for wid in SpaceService.windowsInSpace(space) where spaceForWid[wid] == nil {
                spaceForWid[wid] = space
            }
        }
        guard !spaceForWid.isEmpty else { return [] }
        let meta = metadata(for: Array(spaceForWid.keys))
        return spaceForWid.compactMap { wid, space in
            guard let m = meta[wid], m.pid == pid, m.layer == 0, m.height >= 80 else { return nil }
            return (wid, space)
        }
    }

    private struct Meta { let pid: pid_t; let layer: Int; let height: Double }

    /// Batched CGWindowList metadata (owner pid / layer / height) for the given ids. A description
    /// lookup works for windows on any Space (it is not Space-scoped like the on-screen list).
    private func metadata(for wids: [CGWindowID]) -> [CGWindowID: Meta] {
        var pointers: [UnsafeRawPointer?] = wids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !pointers.isEmpty,
              let arr = CFArrayCreate(kCFAllocatorDefault, &pointers, pointers.count, nil),
              let raw = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [:] }
        var map: [CGWindowID: Meta] = [:]
        for d in raw {
            guard let wid = (d[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let pid = pid_t((d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            let layer = (d[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            var height = 0.0
            if let b = d[kCGWindowBounds as String] as? NSDictionary,
               let h = (b["Height"] as? NSNumber)?.doubleValue { height = h }
            map[wid] = Meta(pid: pid, layer: layer, height: height)
        }
        return map
    }
}
