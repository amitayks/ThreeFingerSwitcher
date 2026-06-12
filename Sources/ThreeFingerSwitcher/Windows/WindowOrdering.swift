import Foundation

/// Pure, AppKit/AX-free ordering of a Space-row's windows by per-window focus recency, with the
/// today's-behavior fallback for never-focused windows. Extracted from `WindowService` so the sort
/// key is unit-testable without any AppKit/Accessibility/CGS state (mirrors `SpaceGrouping`).
///
/// Each row carries the four values that decide order:
///   - `winRank`  — per-window focus recency (`WindowFocusTracker.rank`); lower = more recent,
///                   `Int.max` = never focused. This is the NEW primary key.
///   - `onCurrent` — 0 for a current-Space window, 1 otherwise (current Space first).
///   - `spaceIdx` — the window's Mission Control Space index (lower = earlier).
///   - `z`        — on-screen stacking order within the Space (lower = nearer front).
///
/// `appRank` is the FINAL tiebreak. Because `z` is unique per window in a snapshot, it is
/// effectively unreachable — it keeps app-MRU (`MRUTracker`) referenced without changing behavior.
enum WindowOrdering {
    /// Sort fields for one window. Generic over a payload so the comparator is testable on plain
    /// rows and reusable for the real `WindowInfo` rows in `WindowService`.
    struct Key {
        let winRank: Int
        let onCurrent: Bool
        let spaceIdx: Int
        let z: Int
        let appRank: Int
    }

    /// True when `a` should sort before `b`. Primary `winRank` ascending (most-recent first), then
    /// current-Space first, then Space index, then z-order, with `appRank` as the final tiebreak.
    static func before(_ a: Key, _ b: Key) -> Bool {
        if a.winRank != b.winRank { return a.winRank < b.winRank }       // most-recently-focused first
        if a.onCurrent != b.onCurrent { return a.onCurrent && !b.onCurrent } // current Space first
        if a.spaceIdx != b.spaceIdx { return a.spaceIdx < b.spaceIdx }   // Mission Control order
        if a.z != b.z { return a.z < b.z }                              // z-order within Space
        return a.appRank < b.appRank                                     // final tiebreak (effectively unreachable)
    }

    /// Sort `rows` in place by their derived `Key`. The caller supplies the projection so this stays
    /// free of any concrete row type.
    static func sort<Row>(_ rows: inout [Row], key: (Row) -> Key) {
        rows.sort { before(key($0), key($1)) }
    }
}
