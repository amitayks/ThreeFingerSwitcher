import AppKit
import Combine

/// Drives the launcher overlay. The grid is a 2D cursor: horizontal moves across a row, vertical
/// moves between rows. The **headers row sits above the grid** — moving up from the first app row
/// lands focus on the headers, where horizontal switches the batch (band) and down re-enters its
/// grid. Mirrors a Launchpad-style layout; carries the dwell-arm state the switcher has no analogue
/// for. Navigation logic lives here (pure, knows item counts + columns); the controller drives the
/// dwell timer and panel sizing off it.
@MainActor
final class LauncherModel: ObservableObject {
    enum Focus: Equatable { case headers, grid }

    // Grid source of truth.
    @Published private(set) var bands: [[LaunchItem]] = []
    @Published private(set) var bandNames: [String] = []
    @Published private(set) var bandColors: [ItemColor] = []
    @Published private(set) var currentBand: Int = 0
    @Published private(set) var lastBandDirection: Int = 1

    /// Whether the cursor is on the headers row or inside the app grid.
    @Published private(set) var focus: Focus = .grid

    // Derived view state.
    @Published var items: [LaunchItem] = []
    @Published private(set) var selectedIndex: Int = 0

    // Dwell-to-arm state.
    @Published var arming: Bool = false
    @Published var armed: Bool = false
    /// Bumped every time arming (re)starts, so the highlight re-animates per item selection.
    @Published private(set) var armingToken: Int = 0
    @Published var dwell: Double = 0.5

    var bandCount: Int { bands.count }
    private var columns: Int { LauncherGridLayout.columns }

    func setBands(_ bands: [[LaunchItem]], names: [String], colors: [ItemColor], startBand: Int, column: Int) {
        self.bands = bands
        self.bandNames = names
        self.bandColors = colors
        self.currentBand = clamp(startBand, 0, max(bands.count - 1, 0))
        self.focus = .grid                         // first trigger: first app of the first header
        applyCurrentBand(column: column)
        disarm()
    }

    // MARK: - Navigation (pure)

    /// Horizontal step (`dir > 0` = right). In the headers row, switches the batch; in the grid,
    /// moves the cursor within the current row (clamped at row ends).
    func stepHorizontal(_ dir: Int) {
        guard dir != 0 else { return }
        switch focus {
        case .headers:
            let target = clamp(currentBand + dir, 0, max(bands.count - 1, 0))
            guard target != currentBand else { return }
            lastBandDirection = target > currentBand ? 1 : -1
            currentBand = target
            applyCurrentBand(column: 0)
        case .grid:
            guard !items.isEmpty else { return }
            let col = selectedIndex % columns
            let row = selectedIndex / columns
            let itemsInRow = min(columns, items.count - row * columns)
            let newCol = col + dir
            if newCol >= 0 && newCol < itemsInRow {
                selectedIndex = row * columns + newCol
            }
        }
    }

    /// Vertical step (`dir > 0` = up, toward the headers; `dir < 0` = down, into the grid). Up from
    /// the first app row lands on the headers; down from the headers enters the grid.
    func stepVertical(_ dir: Int) {
        guard dir != 0 else { return }
        switch focus {
        case .headers:
            if dir < 0, !items.isEmpty {           // down → enter the grid at the first app
                focus = .grid
                selectedIndex = 0
            }
            // up → already at the top; nothing
        case .grid:
            let col = selectedIndex % columns
            let row = selectedIndex / columns
            if dir > 0 {                            // up
                if row == 0 {
                    focus = .headers                // rise out of the grid onto the headers
                } else {
                    selectedIndex = (row - 1) * columns + col
                }
            } else {                                // down
                let lastRow = max(0, (items.count - 1) / columns)
                if row < lastRow {
                    selectedIndex = min((row + 1) * columns + col, items.count - 1)
                }
            }
        }
    }

    var selectedItem: LaunchItem? {
        guard focus == .grid, items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    var currentBandColor: ItemColor {
        bandColors.indices.contains(currentBand) ? bandColors[currentBand] : ItemColor(red: 0.4, green: 0.5, blue: 0.9)
    }

    // MARK: - Dwell

    func beginArming() { armingToken &+= 1; arming = true; armed = false }
    func setArmed() { armed = true; arming = false }
    func disarm() { arming = false; armed = false }

    private func applyCurrentBand(column: Int) {
        items = bands.indices.contains(currentBand) ? bands[currentBand] : []
        selectedIndex = clamp(column, 0, max(items.count - 1, 0))
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
