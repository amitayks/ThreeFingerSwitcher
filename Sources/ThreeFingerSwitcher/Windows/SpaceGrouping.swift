import Foundation

/// Pure grouping of a flat all-Spaces window snapshot into Space-rows. Extracted from
/// `AppCoordinator` so the ordering logic is unit-testable without any AppKit/CGS state.
enum SpaceGrouping {
    /// Group the flat all-Spaces snapshot into Space-rows in true Mission Control order, so a
    /// given Space keeps the same row position across reopens. The current Space is highlighted
    /// in place (via `startRow`) rather than reordered to the front. Each window keeps its
    /// in-Space order from the snapshot. Empty Spaces never appear (only Spaces with switchable
    /// windows produce a row).
    ///
    /// - Returns: `rows` (windows per Space-row, ordered by Mission Control index), `labels`
    ///   (each row's true 1-based Space number), and `startRow` (index of the current Space's
    ///   row, or 0 if none is current).
    static func group(_ windows: [WindowInfo]) -> (rows: [[WindowInfo]], labels: [String], startRow: Int) {
        var buckets: [UInt64: [WindowInfo]] = [:]
        var order: [UInt64] = []
        var isCurrent: Set<UInt64> = []
        var spaceIndexByKey: [UInt64: Int] = [:]
        for w in windows {
            let key = w.spaceID ?? 0
            if buckets[key] == nil {
                order.append(key)
                spaceIndexByKey[key] = w.spaceIndex   // all windows in a bucket share a Space
            }
            buckets[key, default: []].append(w)
            if w.isOnCurrentSpace { isCurrent.insert(key) }
        }
        // Order rows by Mission Control index; tiebreak on the raw key for determinism.
        let keys = order.sorted { a, b in
            let ia = spaceIndexByKey[a] ?? Int.max
            let ib = spaceIndexByKey[b] ?? Int.max
            if ia != ib { return ia < ib }
            return a < b
        }
        let rows = keys.map { buckets[$0] ?? [] }
        // Label each row with its true Space number (1-based Mission Control position), so a
        // label stays meaningful even when an earlier Space is empty and omitted.
        let labels = keys.map { "\((spaceIndexByKey[$0] ?? 0) + 1)" }
        // Highlight the current Space at its own position (not forced to row 0).
        let startRow = keys.firstIndex { isCurrent.contains($0) } ?? 0
        return (rows, labels, startRow)
    }
}
