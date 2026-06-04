import Foundation

/// Pure grouping of a flat all-Spaces window snapshot into Space-rows. Extracted from
/// `AppCoordinator` so the ordering logic is unit-testable without any AppKit/CGS state.
enum SpaceGrouping {
    /// Group the flat all-Spaces snapshot into Space-rows: the current Space first, then the
    /// others (by Space id). Each window keeps its in-Space order from the snapshot.
    ///
    /// - Returns: `rows` (windows per Space-row, current row first), `labels` (1-based row
    ///   numbers as strings), and `startRow` (index of the first current-Space row, or 0).
    static func group(_ windows: [WindowInfo]) -> (rows: [[WindowInfo]], labels: [String], startRow: Int) {
        var buckets: [UInt64: [WindowInfo]] = [:]
        var order: [UInt64] = []
        var isCurrent: Set<UInt64> = []
        for w in windows {
            let key = w.spaceID ?? 0
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(w)
            if w.isOnCurrentSpace { isCurrent.insert(key) }
        }
        let keys = order.sorted { a, b in
            let ca = isCurrent.contains(a), cb = isCurrent.contains(b)
            if ca != cb { return ca }   // current Space row(s) first
            return a < b
        }
        let rows = keys.map { buckets[$0] ?? [] }
        let labels = keys.indices.map { "\($0 + 1)" }
        let startRow = keys.firstIndex { isCurrent.contains($0) } ?? 0
        return (rows, labels, startRow)
    }
}
