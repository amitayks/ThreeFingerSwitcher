import CoreGraphics

/// Pure edge-adjacency test for snap-to-bind window groups: two frames are "snapped" when a facing
/// pair of edges sits within `epsilon` AND the windows share at least `minSharedExtent` along that
/// edge (which excludes a mere corner touch by construction). All four orientations are checked.
/// Coordinate-space agnostic (pure rect math) — callers must simply pass both frames in ONE space
/// (the snap monitor uses CG top-left global for both).
///
/// `epsilon` covers both a perfectly flush snap (gap 0) and the small uniform gap the system's
/// "Tiled windows have margins" setting leaves (~8–10pt). Both constants are feel-only internals
/// (like layout metrics), not user settings.
enum SnapAdjacency {
    static let epsilon: CGFloat = 12
    static let minSharedExtent: CGFloat = 60

    /// The raw numbers behind `adjacent` for one pair, for diagnostics/logging: the nearest facing-edge
    /// distance on each axis and the shared extent that would gate it.
    struct Diagnostic {
        let horizontalGap: CGFloat      // nearest left/right facing-edge distance
        let verticalShared: CGFloat     // shared vertical extent gating a left/right bind
        let verticalGap: CGFloat        // nearest top/bottom facing-edge distance
        let horizontalShared: CGFloat   // shared horizontal extent gating a top/bottom bind
    }

    static func diagnostic(_ a: CGRect, _ b: CGRect) -> Diagnostic {
        Diagnostic(
            horizontalGap: min(abs(a.maxX - b.minX), abs(b.maxX - a.minX)),
            verticalShared: min(a.maxY, b.maxY) - max(a.minY, b.minY),
            verticalGap: min(abs(a.maxY - b.minY), abs(b.maxY - a.minY)),
            horizontalShared: min(a.maxX, b.maxX) - max(a.minX, b.minX)
        )
    }

    static func adjacent(
        _ a: CGRect, _ b: CGRect,
        epsilon: CGFloat = SnapAdjacency.epsilon,
        minSharedExtent: CGFloat = SnapAdjacency.minSharedExtent
    ) -> Bool {
        let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let hOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        // Left/right facing edges: a's right against b's left (or vice versa), sharing vertical extent.
        if vOverlap >= minSharedExtent,
           abs(a.maxX - b.minX) <= epsilon || abs(b.maxX - a.minX) <= epsilon {
            return true
        }
        // Top/bottom facing edges: a's bottom against b's top (or vice versa), sharing horizontal extent.
        if hOverlap >= minSharedExtent,
           abs(a.maxY - b.minY) <= epsilon || abs(b.maxY - a.minY) <= epsilon {
            return true
        }
        return false
    }

    /// Whether two frames are physically ATTACHED — the *stay-bound* test, deliberately looser than
    /// the *bind* test (`adjacent`): a bond is created only by a flush snap, but it persists while
    /// the windows touch OR OVERLAP. Pushing a member INTO its mate (or laying a small window on top
    /// of it) is still physical contact; only pulling them APART — a real gap — detaches. The overlap
    /// must be more than a corner brush (`epsilon` in both dimensions).
    static func attached(
        _ a: CGRect, _ b: CGRect,
        epsilon: CGFloat = SnapAdjacency.epsilon,
        minSharedExtent: CGFloat = SnapAdjacency.minSharedExtent
    ) -> Bool {
        if adjacent(a, b, epsilon: epsilon, minSharedExtent: minSharedExtent) { return true }
        let overlap = a.intersection(b)
        return overlap.width > epsilon && overlap.height > epsilon
    }
}
