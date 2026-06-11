import AppKit
import Combine

/// Drives the launcher overlay. The bands render as a **vertical title list on the LEFT** (focus
/// `.bands`) and the active band's content as a **grid on the RIGHT** (focus `.grid`). The two axes
/// are transposed from a 2D cursor: on the band list, **vertical** switches the active band; crossing
/// between the band list and the grid is **horizontal** (right from the list enters the grid, left
/// from the grid's first column returns to the list). Inside the grid, horizontal moves across a row
/// and vertical moves between rows (clamped at the top — it no longer rises to a header strip).
/// Mirrors a Launchpad-style layout; carries the dwell-arm state the switcher has no analogue for.
/// Navigation logic lives here (pure, knows item counts + columns); the controller drives the dwell
/// timer and panel sizing off it.
@MainActor
final class LauncherModel: ObservableObject {
    enum Focus: Equatable { case bands, grid }

    // Grid source of truth.
    @Published private(set) var bands: [[LaunchItem]] = []
    @Published private(set) var bandNames: [String] = []
    @Published private(set) var bandColors: [ItemColor] = []
    /// Per-band launcher icons (the band list renders icons, not titles), aligned 1:1 with the bands.
    @Published private(set) var bandIcons: [ItemIcon] = []
    @Published private(set) var currentBand: Int = 0
    @Published private(set) var lastBandDirection: Int = 1

    /// Whether the cursor is on the band-title list (left) or inside the app grid (right).
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

    /// Index of the synthetic Clipboard band, when present (always the last band). It navigates as a
    /// single-column master-detail list and repurposes horizontal travel (see `stepHorizontal`).
    @Published private(set) var clipboardBandIndex: Int?

    /// When non-nil, the launcher is showing the AI streaming preview canvas for the fired command
    /// (the grid is replaced by the canvas; the overlay stays visible, non-activating). Cleared when
    /// the canvas is dismissed (commit / discard). This is the only state the canvas-mode UI binds to;
    /// the live model/streaming state lives in the injected `AICommandExecutor` the view observes.
    @Published private(set) var canvasCommand: AICommand?
    /// True while the AI preview canvas is on screen.
    var canvasActive: Bool { canvasCommand != nil }
    /// Session-only set of clipboard entry ids whose pin was toggled this session — drives the pin
    /// marker without reordering the live list (the reorder is deferred to the next band build).
    @Published private(set) var sessionPinToggles: Set<UUID> = []
    /// Called when a RIGHT step pins/unpins the selected clipboard entry (wired to the store).
    var onPinToggle: ((LaunchItem) -> Void)?

    /// How many fine horizontal steps must accumulate before a clipboard pin / previous-band action
    /// fires — so pinning needs a *deliberate* horizontal excursion, not the fine item step. Set from
    /// settings on `show`; defaults to a deliberate few.
    var clipboardPinStepThreshold: Int = 3
    /// Signed accumulator of fine horizontal steps within the current clipboard excursion.
    private var clipHorizAccum = 0
    /// True once an action fired this excursion; cleared only when the accumulator returns to centre,
    /// so one horizontal flick = one action (no rapid re-toggling while the fingers stay offset).
    private var clipHorizLatched = false

    var bandCount: Int { bands.count }
    /// Whether the current band is the Clipboard band (single column, repurposed horizontal).
    var currentBandIsClipboard: Bool { clipboardBandIndex == currentBand }

    /// Columns for the current band: the Clipboard band is a single-column list; others use the grid.
    private var currentColumns: Int { currentBandIsClipboard ? 1 : LauncherGridLayout.columns }

    func setBands(_ bands: [[LaunchItem]], names: [String], colors: [ItemColor],
                  icons: [ItemIcon] = [], startBand: Int, column: Int, clipboardBandIndex: Int? = nil) {
        self.bands = bands
        self.bandNames = names
        self.bandColors = colors
        self.bandIcons = icons
        self.clipboardBandIndex = clipboardBandIndex
        self.canvasCommand = nil
        self.sessionPinToggles = []
        self.currentBand = clamp(startBand, 0, max(bands.count - 1, 0))
        // Multi-band lands on the band list at the home band (nothing armed); a single band has no
        // list to show, so it lands directly on the home cell of that band.
        self.focus = bands.count > 1 ? .bands : .grid
        applyCurrentBand(column: column)
        disarm()
    }

    // MARK: - AI preview canvas

    /// Enter the AI streaming preview canvas for `command` (fired from an armed AI item). The grid is
    /// replaced by the canvas; the panel stays visible and never becomes key.
    func enterCanvas(_ command: AICommand) {
        canvasCommand = command
        disarm()
    }

    /// Leave the AI preview canvas (commit / discard). Restores the normal grid presentation.
    func exitCanvas() {
        canvasCommand = nil
    }

    /// Visual pin state for a clipboard item: the entry's stored pin XOR a session toggle.
    func isPinned(_ item: LaunchItem) -> Bool {
        guard case let .clipboardEntry(entry) = item.kind else { return false }
        return entry.pinned != sessionPinToggles.contains(item.id)
    }

    // MARK: - Navigation (pure)

    /// Horizontal step (`dir > 0` = right). On the band list (left), RIGHT crosses into the grid at
    /// its home/first item and LEFT clamps (nothing sits to the left of the list); in the grid,
    /// moves the cursor within the current row, and from column 0 a LEFT step crosses back to the
    /// band list (when there is more than one band).
    func stepHorizontal(_ dir: Int) {
        guard dir != 0 else { return }
        switch focus {
        case .bands:
            if dir > 0, !items.isEmpty {            // right → enter the grid at the first item
                focus = .grid
                selectedIndex = 0
            }
            // left → already at the leftmost pane; nothing
        case .grid:
            // The Clipboard band has no horizontal cursor (single column): RIGHT pins the selected
            // entry (no move, deferred reorder), LEFT crosses back to the band list.
            if currentBandIsClipboard {
                stepClipboardHorizontal(dir)
                return
            }
            guard !items.isEmpty else { return }
            let cols = currentColumns
            let col = selectedIndex % cols
            let row = selectedIndex / cols
            let itemsInRow = min(cols, items.count - row * cols)
            let newCol = col + dir
            if newCol >= 0 && newCol < itemsInRow {
                selectedIndex = row * cols + newCol
            } else if newCol < 0 && bands.count > 1 {
                focus = .bands                      // left from column 0 → back to the band list
            }
        }
    }

    /// Clipboard-band horizontal: a *deliberate* excursion (≥ `clipboardPinStepThreshold` fine steps)
    /// fires once — RIGHT toggles the selected entry's pin (selection stays put), LEFT crosses back to
    /// the band list (the Clipboard band stays active, so vertical from there reaches the previous
    /// band). The action is latched until the accumulator returns to centre, so one flick = one action
    /// (no rapid re-toggling within a small movement).
    private func stepClipboardHorizontal(_ dir: Int) {
        clipHorizAccum += dir
        if clipHorizAccum == 0 { clipHorizLatched = false }   // returned to centre: ready for the next flick
        guard !clipHorizLatched, abs(clipHorizAccum) >= max(1, clipboardPinStepThreshold) else { return }
        clipHorizLatched = true
        if clipHorizAccum > 0 {
            guard let item = selectedItem else { return }
            sessionPinToggles.formSymmetricDifference([item.id])   // toggle (next flick = back to original)
            onPinToggle?(item)
        } else if bands.count > 1 {
            focus = .bands                          // left → back to the band list (Clipboard stays active)
            resetClipboardHoriz()
        }
    }

    /// Reset the clipboard horizontal excursion state (on band entry / vertical scrub) so partial
    /// horizontal travel never lingers across a different action.
    private func resetClipboardHoriz() {
        clipHorizAccum = 0
        clipHorizLatched = false
    }

    /// Vertical step (`dir > 0` = up; `dir < 0` = down). On the band list, vertical switches the
    /// active band (up the list = previous band); in the grid, vertical steps between rows and clamps
    /// at the first row (it no longer rises onto a header strip — the band list is reached
    /// horizontally now).
    func stepVertical(_ dir: Int) {
        guard dir != 0 else { return }
        if currentBandIsClipboard { resetClipboardHoriz() }   // vertical scrub clears horizontal intent
        switch focus {
        case .bands:
            // up (dir > 0) = previous band, down = next band; clamp at the ends.
            let target = clamp(currentBand - dir, 0, max(bands.count - 1, 0))
            guard target != currentBand else { return }
            lastBandDirection = target > currentBand ? 1 : -1
            currentBand = target
            applyCurrentBand(column: 0)
        case .grid:
            let cols = currentColumns
            let col = selectedIndex % cols
            let row = selectedIndex / cols
            if dir > 0 {                            // up
                if row > 0 {                        // clamp at the first row (no rise to the band list)
                    selectedIndex = (row - 1) * cols + col
                }
            } else {                                // down
                let lastRow = max(0, (items.count - 1) / cols)
                if row < lastRow {
                    selectedIndex = min((row + 1) * cols + col, items.count - 1)
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
        resetClipboardHoriz()
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
