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

    /// The held Open-With picker's state (see `filesPicker`): the relevant-apps `candidates` for the
    /// highlighted file (already enumerated by `FileOpenService.openWithCandidates`, default app indicated)
    /// and the `highlightedIndex` the user scrubs to. A value type so the whole sub-state publishes as one
    /// `@Published` change; equality drives the view's diffing.
    struct FilesPickerState: Equatable {
        /// The applications that can open the file, in the system's order (the default is `isDefault`).
        var candidates: [OpenWithCandidate]
        /// The currently highlighted row (the app a lift would choose). Always a valid index while non-empty.
        var highlightedIndex: Int

        /// The highlighted candidate, or nil for an (defensively) empty list.
        var highlighted: OpenWithCandidate? {
            candidates.indices.contains(highlightedIndex) ? candidates[highlightedIndex] : nil
        }
    }

    /// A failed Files-band open, surfaced as observable bounded state (spec: "Failures are observable, never
    /// silent"). Carries the clean, bounded `headline` (the `FileActionError` sentence — never raw error
    /// text) and the opt-in copyable `details` (the raw OS/workspace text, surfaced only behind a "Show
    /// details / Copy" disclosure; `nil` when the headline already says everything). Mirrored from
    /// `FileOpenService.State.failed` by the coordinator's state sink; nil when there is no live failure. A
    /// value type so the whole sub-state publishes as one `@Published` change and equality drives diffing.
    struct FilesOpenFailure: Equatable {
        /// The clean, bounded, user-facing message (never raw error text).
        var headline: String
        /// The opt-in raw text for a "Show details / Copy" disclosure, or nil when there is nothing extra.
        var details: String?
    }

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

    /// Index of the synthetic Files band, when present (mirrors `clipboardBandIndex`). It navigates as a
    /// single-column **directory column**: horizontal drills (descend / ascend) instead of stepping a row,
    /// vertical moves the highlight, and the band's items are reprojected from the column on every move
    /// (see `stepHorizontal` / `stepVertical` and `FilesColumnController`).
    @Published private(set) var filesBandIndex: Int?

    /// Owns the Files band's column navigation + the async-listing cache bridge while a Files band is
    /// present (built in `setBands`). Nil when the Files band isn't injected. The view reads the highlighted
    /// entry / preview off this; the model routes drill / highlight steps into it and reprojects the band.
    @Published private(set) var filesColumn: FilesColumnController?

    /// One-shot **published focus-search signal** for the Files band: bumped when a top-of-column
    /// clamp-overflow up-step asks the view to focus the search field (the model surfaces the navigator's
    /// `focusSearchRequested` latch as a monotonically increasing token so a SwiftUI `.onChange` fires each
    /// time, then the latch is cleared). The view observes this; nothing reads its absolute value.
    @Published private(set) var filesFocusSearchToken: Int = 0

    /// Whether the Files band's **search field is the focused element** (refinement 5): a top-of-column
    /// clamp-overflow up-step (the same `filesFocusSearchToken` path) sets it TRUE, and a vertical DOWN step
    /// that moves the highlight back into the list sets it FALSE — so stepping down off the field un-focuses
    /// it (today both the field and the list stay highlighted). The controller flips the overlay panel
    /// **key-interactive** on this (so keystrokes land in the field, like the AI canvas), and the view binds
    /// its first-responder to it. Cleared on every band switch / `setBands` so a stale focus never carries
    /// across opens. A *level* signal (not a token) because the panel's key state must track it both ways.
    @Published private(set) var filesSearchFocused: Bool = false

    /// The held **Open-With picker** sub-state for the Files band: the relevant-apps list a relative
    /// +1-finger lift opened (`AppCoordinator.filesOpenWith` → `enterFilesPicker`), plus the highlighted
    /// row. Nil when not picking — the picker is a transient overlay budded over the column navigator,
    /// scrubbed vertically and resolved on the next lift (choose) / horizontal swipe (back to the list).
    /// `FilesBandView` observes this to render the popup; the recognizer's depth/highlight/open intents are
    /// routed to the picker (vs. the folder list) by the coordinator whenever it is non-nil.
    @Published var filesPicker: FilesPickerState?

    /// The current failed Files-band open, mirrored from `FileOpenService.State` by the coordinator's state
    /// sink (set on `.failed`, cleared to nil on `.idle`/`.opening`/`.opened`). When non-nil, `FilesBandView`
    /// renders a **bounded, non-blocking** failure row at the bottom of the navigator (headline + opt-in
    /// details + Retry/Dismiss) — never an app-modal alert (spec: bounded + non-blocking, never silent).
    @Published var filesOpenFailure: FilesOpenFailure?

    /// Whether the Files band is current AND the Open-With picker is open — the predicate the coordinator
    /// branches the recognizer's Files intents on (picker-mode = scrub the app list, not the folder list).
    var isPickingOpenWith: Bool { currentBandIsFiles && filesPicker != nil }

    /// Called when a Files-band depth change should persist the per-root remembered location (wired to
    /// `AppSettings.rememberLocation(_:forRoot:)` by the controller). Keyed/valued by standardized path.
    var onFilesRememberLocation: ((_ path: String, _ rootPath: String) -> Void)?

    /// Called when the Files-band failure row's **Retry** is tapped — re-fires the last open through the
    /// coordinator (which re-prepares/commits it on `FileOpenService`, so a transient failure can be
    /// retried without re-navigating). Wired by `AppCoordinator`; nil (no-op) when nothing can be retried.
    var onFilesRetryOpen: (() -> Void)?

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
    /// Whether the current band is the Files band (single column, horizontal drills the directory tree).
    var currentBandIsFiles: Bool { filesBandIndex == currentBand }

    /// Whether the Files **directory drill** is engaged: the Files band is current AND focus has crossed
    /// INTO the file column (`.grid`), not merely resting on the band-rail icon (`.bands`). The controller
    /// gates the recognizer's `filesDrillActive` on THIS (not on `currentBandIsFiles`), so while the
    /// highlight sits on the Files band icon the band behaves like any other — a horizontal step crosses
    /// into the column, a vertical step switches bands, and a lift DISMISSES the launcher (refinement 1).
    /// The drill/open behaviour (descend / ascend, a lift opens the highlighted entry) engages only once
    /// the cursor is in the column. `currentBandIsFiles == false` ⇒ this is `false` too.
    var filesDrillEngaged: Bool { currentBandIsFiles && focus == .grid }

    /// Columns for the current band: the Clipboard and Files bands are single-column lists; others use the
    /// grid. (The Files band's horizontal axis drills folders rather than stepping a row, but it is still a
    /// one-wide column so row math stays single-column.)
    private var currentColumns: Int {
        (currentBandIsClipboard || currentBandIsFiles) ? 1 : LauncherGridLayout.columns
    }

    func setBands(_ bands: [[LaunchItem]], names: [String], colors: [ItemColor],
                  icons: [ItemIcon] = [], startBand: Int, column: Int, clipboardBandIndex: Int? = nil,
                  filesBandIndex: Int? = nil, filesColumn: FilesColumnController? = nil) {
        self.bands = bands
        self.bandNames = names
        self.bandColors = colors
        self.bandIcons = icons
        self.clipboardBandIndex = clipboardBandIndex
        self.filesBandIndex = filesBandIndex
        self.filesColumn = filesColumn
        // Wire the controller's async-listing callback so a late listing landing reprojects the band's
        // items + republishes (the depth-change → remembered-location persistence is driven separately,
        // inline from the horizontal drill).
        bindFilesColumn(filesColumn)
        self.canvasCommand = nil
        self.filesPicker = nil
        self.filesOpenFailure = nil
        self.filesSearchFocused = false
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

    // MARK: - Files band (single-column directory drill)

    /// Wire a Files-band controller's async-listing callback to this model: when a late listing lands the
    /// controller fires `onColumnChanged`, which reprojects the band's items and republishes. (Remembered-
    /// location persistence is driven separately, inline from the horizontal drill.) Idempotent — called
    /// from `setBands` whenever the controller is (re)assigned.
    private func bindFilesColumn(_ controller: FilesColumnController?) {
        controller?.onColumnChanged = { [weak self] in self?.reprojectFilesBand() }
    }

    /// Reproject the Files band's items from the controller's current column (the navigator's
    /// `visibleEntries`) via `FilesBandBuilder`, and — when the Files band is the active band — refresh the
    /// live `items` + selection to the highlighted row. Called after every Files move and on an async
    /// listing landing. A no-op when there is no Files band / controller.
    private func reprojectFilesBand() {
        guard let index = filesBandIndex, let controller = filesColumn,
              bands.indices.contains(index) else { return }
        let rebuilt = FilesBandBuilder.build(currentColumn: controller.visibleEntries).items
        bands[index] = rebuilt
        guard currentBand == index else { return }       // only touch the live cursor if it's showing
        items = rebuilt
        // Keep the launcher selection locked to the navigator's highlight (the source of truth for the
        // Files band) rather than the grid's own index math.
        selectedIndex = clamp(controller.highlightedIndex, 0, max(items.count - 1, 0))
    }

    /// Drill horizontally in the Files band: a RIGHT step descends into the highlighted folder, a LEFT step
    /// ascends one level (or backs out to the roots list). `dir > 0` is descend regardless of the user's
    /// reverse-direction setting — that inversion is applied upstream (in the recognizer / coordinator)
    /// before the step reaches this model, exactly as it is for grid and clipboard horizontal travel. After
    /// the move the band is reprojected and any depth change persists the remembered location.
    private func stepFilesHorizontal(_ dir: Int) {
        guard let controller = filesColumn else { return }
        let before = controller.current
        if dir > 0 {
            controller.descend()
        } else {
            controller.ascend()
        }
        reprojectFilesBand()
        if controller.current != before { persistFilesRememberedLocations() }
    }

    /// Move the Files-band highlight vertically: `dir > 0` (up) moves toward the top, `dir < 0` (down) moves
    /// toward the bottom — matching the grid/clipboard vertical convention (the reverse-vertical setting is
    /// already applied upstream). An up-step at the top of the column overflows into a focus-search request,
    /// which this surfaces as the published `filesFocusSearchToken`. Reprojects the band so the view follows
    /// the new highlight.
    private func stepFilesVertical(_ dir: Int) {
        guard let controller = filesColumn else { return }
        if dir > 0 {
            controller.highlightUp()
            // A top-of-column overflow latches a focus-search request; surface it once (bump the one-shot
            // token the view focuses off) AND raise the level `filesSearchFocused` (the controller flips the
            // panel key-interactive on it, so typing lands in the field), then clear the latch.
            if controller.focusSearchRequested {
                filesFocusSearchToken &+= 1
                filesSearchFocused = true
                controller.clearFocusSearchRequest()
            }
        } else {
            // A DOWN step moves the highlight back into the list, so it un-focuses the search field — both
            // can no longer be highlighted at once (refinement 5). Harmless when search wasn't focused.
            filesSearchFocused = false
            controller.highlightDown()
        }
        reprojectFilesBand()
    }

    /// Persist the controller's per-root remembered locations through the injected sink (one call per root
    /// that has a remembered deepest location). Keyed/valued by standardized path — the sink writes them to
    /// `AppSettings`.
    private func persistFilesRememberedLocations() {
        guard let controller = filesColumn, let sink = onFilesRememberLocation else { return }
        for (root, location) in controller.rememberedLocations {
            sink(location.standardizedFileURL.path, root.standardizedFileURL.path)
        }
    }

    // MARK: - Files band Open-With picker (the held +1-finger app list)

    /// Enter the Open-With picker with the file's relevant apps (`FileOpenService.openWithCandidates`),
    /// landing the highlight on the **default** application (the one a plain open would launch) so the most
    /// likely choice is pre-selected; a fresh gesture then scrubs it. A no-op when `candidates` is empty
    /// (the coordinator surfaces a "no app" notice instead and never enters here).
    func enterFilesPicker(_ candidates: [OpenWithCandidate]) {
        guard !candidates.isEmpty else { return }
        let start = candidates.firstIndex(where: \.isDefault) ?? 0
        filesPicker = FilesPickerState(candidates: candidates, highlightedIndex: start)
    }

    /// Move the picker highlight vertically: `dir > 0` (up) toward the top of the list, `dir < 0` (down)
    /// toward the bottom — the same convention as the folder list's vertical highlight (the reverse-vertical
    /// setting is already applied upstream). Clamps at both ends (the picker is a short bounded list). A
    /// no-op when the picker isn't open.
    func filesPickerMove(_ dir: Int) {
        guard dir != 0, var picker = filesPicker else { return }
        let next = clamp(picker.highlightedIndex - dir, 0, max(picker.candidates.count - 1, 0))
        guard next != picker.highlightedIndex else { return }
        picker.highlightedIndex = next
        filesPicker = picker
    }

    /// The candidate a lift in picker mode would choose (the highlighted app), or nil when the picker
    /// isn't open / is (defensively) empty. The coordinator opens the file with this app's URL.
    func filesPickerSelected() -> OpenWithCandidate? {
        filesPicker?.highlighted
    }

    /// Leave the Open-With picker (a choice was made, or a discard backed out of it). Returns the navigator
    /// to the folder list — the column stays open (the coordinator does not dismiss on a picker discard).
    func exitFilesPicker() {
        filesPicker = nil
    }

    // MARK: - Navigation (pure)

    /// Horizontal step (`dir > 0` = right). On the band list (left), RIGHT crosses into the grid at
    /// its home/first item and LEFT clamps (nothing sits to the left of the list); in the grid,
    /// moves the cursor within the current row, and from column 0 a LEFT step crosses back to the
    /// band list (when there is more than one band).
    ///
    /// Files-band crossing (refinements 1 + 2): a RIGHT from the band rail (`.bands`) into the Files band
    /// CROSSES focus to `.grid` **without descending** — it lands on the column the navigator is *already
    /// displaying* (with restore-at-open, the last folder visited), at the TOP of that column. The drill
    /// (descend / ascend) only happens once focus is `.grid` (the `.grid` branch below). So crossing in is a
    /// pure focus change with no jump: the displayed state and the landing match.
    func stepHorizontal(_ dir: Int) {
        guard dir != 0 else { return }
        switch focus {
        case .bands:
            if dir > 0, !items.isEmpty {            // right → enter the grid at the first item
                focus = .grid
                // The Files band's selection follows the navigator's live highlight (its source of truth),
                // which restore-at-open already sits at the TOP of the displayed column — so crossing in
                // lands exactly there (no descend, no jump). Every other band lands on its first cell.
                selectedIndex = currentBandIsFiles ? (filesColumn?.highlightedIndex ?? 0) : 0
            }
            // left → already at the leftmost pane; nothing
        case .grid:
            // The Clipboard band has no horizontal cursor (single column): RIGHT pins the selected
            // entry (no move, deferred reorder), LEFT crosses back to the band list.
            if currentBandIsClipboard {
                stepClipboardHorizontal(dir)
                return
            }
            // The Files band repurposes horizontal as a directory drill: RIGHT descends into the
            // highlighted folder, LEFT ascends one level — and a LEFT while already at the roots list
            // (nothing left to ascend) crosses back to the band list, matching the grid's column-0 escape.
            if currentBandIsFiles {
                if dir < 0, filesColumn?.canAscend == false, bands.count > 1 {
                    focus = .bands
                    // Landing back on the band icon drops any search focus — the field belongs to the
                    // column, not the rail (refinement 5). The drill also disengages (`filesDrillEngaged`).
                    filesSearchFocused = false
                } else {
                    stepFilesHorizontal(dir)
                }
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
            // The Files band's vertical axis moves the navigator's highlight (and overflows into a
            // focus-search request at the top), not the grid's row math.
            if currentBandIsFiles {
                stepFilesVertical(dir)
                return
            }
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
        // Switching bands abandons any open Open-With picker — it belongs to the Files band's column, so
        // leaving (or re-entering) the band drops it rather than leaving a stale popup floating.
        if !currentBandIsFiles { filesPicker = nil }
        // A band switch also drops any Files search focus (it belongs to the Files column; the field can't
        // stay key once we've left the column / switched bands). The controller releases the panel's key
        // state when this clears (refinement 5).
        filesSearchFocused = false
        items = bands.indices.contains(currentBand) ? bands[currentBand] : []
        // The Files band's selection follows the navigator's live highlight (the source of truth for its
        // column), so switching back to it lands on the row the user left — not column 0.
        let landing = (currentBandIsFiles ? filesColumn?.highlightedIndex : nil) ?? column
        selectedIndex = clamp(landing, 0, max(items.count - 1, 0))
        resetClipboardHoriz()
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
