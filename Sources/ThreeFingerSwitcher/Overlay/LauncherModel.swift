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

    /// Index of the synthetic Clipboard band, when present (always the last band). It navigates as a
    /// single-column master-detail list and repurposes horizontal travel (see `stepHorizontal`).
    @Published private(set) var clipboardBandIndex: Int?
    /// Index of the synthetic AI-command band, when present. It navigates as a normal grid (icon +
    /// label cells); firing one of its items opens the streaming preview canvas instead of dismissing.
    @Published private(set) var aiCommandBandIndex: Int?

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
    /// Whether the current band is the AI-command band (a normal grid whose items open the canvas).
    var currentBandIsAICommand: Bool { aiCommandBandIndex == currentBand }

    /// The AI command of the currently selected item, when the selection is an AI-command item.
    var selectedAICommand: AICommand? {
        guard let item = selectedItem, case let .aiCommand(command) = item.kind else { return nil }
        return command
    }
    /// Columns for the current band: the Clipboard band is a single-column list; others use the grid.
    private var currentColumns: Int { currentBandIsClipboard ? 1 : LauncherGridLayout.columns }

    func setBands(_ bands: [[LaunchItem]], names: [String], colors: [ItemColor],
                  startBand: Int, column: Int, clipboardBandIndex: Int? = nil,
                  aiCommandBandIndex: Int? = nil) {
        self.bands = bands
        self.bandNames = names
        self.bandColors = colors
        self.clipboardBandIndex = clipboardBandIndex
        self.aiCommandBandIndex = aiCommandBandIndex
        self.canvasCommand = nil
        self.sessionPinToggles = []
        self.currentBand = clamp(startBand, 0, max(bands.count - 1, 0))
        self.focus = .grid                         // first trigger: first app of the first header
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
            // The Clipboard band has no horizontal cursor (single column): RIGHT pins the selected
            // entry (no move, deferred reorder), LEFT leaves to the previous band.
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
            }
        }
    }

    /// Clipboard-band horizontal: a *deliberate* excursion (≥ `clipboardPinStepThreshold` fine steps)
    /// fires once — RIGHT toggles the selected entry's pin (selection stays put), LEFT switches to the
    /// previous band (the Clipboard band is last). The action is latched until the accumulator returns
    /// to centre, so one flick = one action (no rapid re-toggling within a small movement).
    private func stepClipboardHorizontal(_ dir: Int) {
        clipHorizAccum += dir
        if clipHorizAccum == 0 { clipHorizLatched = false }   // returned to centre: ready for the next flick
        guard !clipHorizLatched, abs(clipHorizAccum) >= max(1, clipboardPinStepThreshold) else { return }
        clipHorizLatched = true
        if clipHorizAccum > 0 {
            guard let item = selectedItem else { return }
            sessionPinToggles.formSymmetricDifference([item.id])   // toggle (next flick = back to original)
            onPinToggle?(item)
        } else if currentBand > 0 {
            lastBandDirection = -1
            currentBand -= 1
            applyCurrentBand(column: 0)
        }
    }

    /// Reset the clipboard horizontal excursion state (on band entry / vertical scrub) so partial
    /// horizontal travel never lingers across a different action.
    private func resetClipboardHoriz() {
        clipHorizAccum = 0
        clipHorizLatched = false
    }

    /// Vertical step (`dir > 0` = up, toward the headers; `dir < 0` = down, into the grid). Up from
    /// the first app row lands on the headers; down from the headers enters the grid.
    func stepVertical(_ dir: Int) {
        guard dir != 0 else { return }
        if currentBandIsClipboard { resetClipboardHoriz() }   // vertical scrub clears horizontal intent
        switch focus {
        case .headers:
            if dir < 0, !items.isEmpty {           // down → enter the grid at the first app
                focus = .grid
                selectedIndex = 0
            }
            // up → already at the top; nothing
        case .grid:
            let cols = currentColumns
            let col = selectedIndex % cols
            let row = selectedIndex / cols
            if dir > 0 {                            // up
                if row == 0 {
                    focus = .headers                // rise out of the grid onto the headers
                } else {
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
