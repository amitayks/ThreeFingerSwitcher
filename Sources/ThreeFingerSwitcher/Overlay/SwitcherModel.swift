import AppKit
import CoreGraphics
import Combine

/// Drives the overlay view. The grid (`rows` of Space-rows, `currentRow`, `selectedColumn`) is
/// the source of truth; `windows`/`selectedIndex` are derived and published so the existing card
/// strip, adaptive width, thumbnails, and highlight keep working unchanged.
@MainActor
final class SwitcherModel: ObservableObject {
    // Grid source of truth.
    @Published private(set) var rows: [[WindowInfo]] = []
    @Published private(set) var rowLabels: [String] = []   // e.g. Space numbers, one per row
    @Published private(set) var currentRow: Int = 0
    /// +1 if the last row change moved to a later row, -1 earlier (drives the slide direction).
    @Published private(set) var lastRowDirection: Int = 1

    // Derived view state (kept in sync with the grid).
    @Published var windows: [WindowInfo] = []
    @Published var selectedIndex: Int = 0   // selected column within the current row
    @Published var thumbnails: [CGWindowID: NSImage] = [:]
    @Published var overflow: Bool = false
    /// True when Space-row switching is opted in but its gesture relocation still awaits the
    /// one-time re-login — the row indicator then shows a pending hint instead of a silently
    /// dead vertical axis.
    @Published var rowSwitchingPending: Bool = false

    var rowCount: Int { rows.count }

    func setRows(_ rows: [[WindowInfo]], labels: [String], startRow: Int, column: Int) {
        self.rows = rows
        self.rowLabels = labels
        self.currentRow = clamp(startRow, 0, max(rows.count - 1, 0))
        self.thumbnails = [:]
        applyCurrentRow(column: column)
    }

    /// Move to a Space-row (already clamped by caller is fine; we clamp again). Resets the column.
    func setRow(_ row: Int) {
        guard !rows.isEmpty else { return }
        let target = clamp(row, 0, rows.count - 1)
        if target != currentRow { lastRowDirection = target > currentRow ? 1 : -1 }
        currentRow = target
        applyCurrentRow(column: 0)
    }

    func setColumn(_ column: Int) {
        selectedIndex = clamp(column, 0, max(windows.count - 1, 0))
    }

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        thumbnails[id] = image
    }

    var selectedWindow: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    /// Window ids in the current row (for thumbnail prefetch).
    var currentRowIDs: [CGWindowID] { windows.map(\.id) }

    private func applyCurrentRow(column: Int) {
        windows = rows.indices.contains(currentRow) ? rows[currentRow] : []
        selectedIndex = clamp(column, 0, max(windows.count - 1, 0))
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
