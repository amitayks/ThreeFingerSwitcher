import CoreGraphics

/// Runtime-only store of snapped-together window groups (the window-groups capability). A group is a
/// set of `CGWindowID`s meaning "these windows are physically attached": membership is created only
/// by a drag ending edge-flush (`dragSettled`), and ends when the attachment does — dragged apart, or
/// (validated lazily at every consumption point) closed / minimized / moved off the group's Space.
/// Never persisted: `CGWindowID`s are session-scoped, so a restored group could bind the wrong
/// windows. Pure state machine — no AX/CGS — so it is fully unit-testable (the `MRUTracker` shape).
final class WindowGroupStore {
    private(set) var groups: [Set<CGWindowID>] = []

    /// The validated-groups input: the live facts validation needs about one window. `frame` (the
    /// window's current global frame) enables GEOMETRIC validation — members that no longer touch
    /// have detached; `.zero` means "unknown", which skips the geometric check for that group.
    struct Candidate {
        let id: CGWindowID
        let isMinimized: Bool
        let spaceID: CGSSpaceID?
        let frame: CGRect

        init(id: CGWindowID, isMinimized: Bool = false, spaceID: CGSSpaceID? = nil, frame: CGRect = .zero) {
            self.id = id
            self.isMinimized = isMinimized
            self.spaceID = spaceID
            self.frame = frame
        }
    }

    /// The group containing `id`, or nil.
    func group(for id: CGWindowID) -> Set<CGWindowID>? {
        groups.first { $0.contains(id) }
    }

    /// A window's drag has settled. `snapped` is the set of windows its edges now sit FLUSH against
    /// (the strict bind test). A drag is an EXPLICIT re-arrangement of the dragged window, so its
    /// bonds re-evaluate STRICTLY: it keeps/creates bonds only to what it ends flush against —
    /// landing with a gap OR on TOP of a mate both break the old bond (on a laptop screen a
    /// dragged-out window almost always lands overlapping some group member; if overlap kept the
    /// bond here, breaking a group by dragging would be nearly impossible). The looser
    /// overlap-preserving contact rule applies only to PASSIVE geometry checks (`pruneDetached` /
    /// `validatedGroups`), where nobody expressed intent about the member. Intent-driven: only the
    /// DRAGGED window's contacts bind — two windows that merely happen to rest adjacent are never
    /// bound by a third window's drag.
    ///   1. If the window was grouped and no group-mate is among its flush contacts, it leaves that
    ///      group (a group below two members dissolves).
    ///   2. Every freshly SNAPPED window's group (or the lone window) is merged with the dragged
    ///      window's into ONE group — transitive: A onto B while B is grouped with C yields {A, B, C}.
    func dragSettled(window id: CGWindowID, snapped: Set<CGWindowID>) {
        // 1. Not flush against any mate: leave the old group.
        if let idx = groups.firstIndex(where: { $0.contains(id) }) {
            if snapped.isDisjoint(with: groups[idx].subtracting([id])) {
                groups[idx].remove(id)
                if groups[idx].count < 2 { groups.remove(at: idx) }
            }
        }
        // 2. Merge with every fresh snap's group.
        guard !snapped.isEmpty else { return }
        var merged: Set<CGWindowID> = [id]
        merged.formUnion(snapped)
        for member in merged {
            if let idx = groups.firstIndex(where: { $0.contains(member) }) {
                merged.formUnion(groups[idx])
                groups.remove(at: idx)
            }
        }
        groups.append(merged)
    }

    /// Validate every group against live window state and return the surviving groups. A member is
    /// kept only if it appears among `candidates`, is not minimized, and sits on the Space shared by
    /// the group's majority (attachment implies one Space; a member moved elsewhere has detached).
    /// When every kept member's current frame is known, the group is additionally split into its
    /// edge-adjacency components (members that no longer TOUCH have detached — this catches resizes
    /// and moves the snap monitor never saw, e.g. keyboard-driven ones). Groups below two members
    /// dissolve. MUTATES the store (stale members are gone for good) — call at every consumption
    /// point (switcher snapshot assembly, commit) so a stale member can neither render nor be raised.
    @discardableResult
    func validatedGroups(against candidates: [Candidate]) -> [Set<CGWindowID>] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var surviving: [Set<CGWindowID>] = []
        for group in groups {
            let live = group.compactMap { byID[$0] }.filter { !$0.isMinimized }
            guard live.count >= 2 else { continue }
            // Keep the largest same-Space subset (ties: the subset holding the lowest member id, for
            // determinism). Members elsewhere have physically detached.
            let bySpace = Dictionary(grouping: live, by: \.spaceID)
            let best = bySpace.values.max { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return (lhs.map(\.id).min() ?? 0) > (rhs.map(\.id).min() ?? 0)
            }
            guard let kept = best, kept.count >= 2 else { continue }
            // Geometric split, only when every member's frame is usable (unknown frames skip it).
            let framed = kept.compactMap { c in
                c.frame.width > 1 && c.frame.height > 1 ? (id: c.id, frame: c.frame) : nil
            }
            if framed.count == kept.count {
                surviving.append(contentsOf: Self.adjacencyComponents(of: framed).filter { $0.count >= 2 })
            } else {
                surviving.append(Set(kept.map(\.id)))
            }
        }
        groups = surviving
        return surviving
    }

    /// GEOMETRIC re-validation: split every group into its edge-adjacency connected components under
    /// the given current frames and keep only components of two or more members. This is what makes
    /// detachment robust to mis-attributed input — a border-grab resize starts in the few-pixel grab
    /// zone OUTSIDE the window (or inside its neighbor), so the drag can't be credited to the right
    /// window; the geometry, however, doesn't lie. A group containing any member WITHOUT a known
    /// frame is left untouched (a transiently un-enumerable window must not read as "detached" — the
    /// alive/minimized/Space validation owns those cases). Returns whether anything changed.
    @discardableResult
    func pruneDetached(frames: [CGWindowID: CGRect]) -> Bool {
        var changed = false
        var result: [Set<CGWindowID>] = []
        for group in groups {
            let framed = group.compactMap { id in frames[id].map { (id: id, frame: $0) } }
            guard framed.count == group.count else {
                result.append(group)
                continue
            }
            let kept = Self.adjacencyComponents(of: framed).filter { $0.count >= 2 }
            if kept != [group] { changed = true }
            result.append(contentsOf: kept)
        }
        groups = result
        return changed
    }

    /// Connected components of the members under the STAY-BOUND contact test (`SnapAdjacency.attached`:
    /// flush-touching OR overlapping = same component) — bonds persist through overlap; only a gap splits.
    static func adjacencyComponents(of members: [(id: CGWindowID, frame: CGRect)]) -> [Set<CGWindowID>] {
        var unvisited = Array(members.indices)
        var components: [Set<CGWindowID>] = []
        while let seed = unvisited.popLast() {
            var component: Set<Int> = [seed]
            var frontier = [seed]
            while let current = frontier.popLast() {
                let neighbors = unvisited.filter {
                    SnapAdjacency.attached(members[current].frame, members[$0].frame)
                }
                for n in neighbors {
                    component.insert(n)
                    frontier.append(n)
                }
                unvisited.removeAll { neighbors.contains($0) }
            }
            components.append(Set(component.map { members[$0].id }))
        }
        return components
    }

    /// Drop every group (the opt-in was turned off — re-enabling must never resurrect stale state).
    func clear() {
        groups.removeAll()
    }
}
