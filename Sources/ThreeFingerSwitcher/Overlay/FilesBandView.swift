import SwiftUI
import AppKit
import Foundation

/// The Files band's body: a **bounded column navigator** (design D6), rendered instead of the icon grid
/// when `model.currentBandIsFiles`. Three regions, left to right:
///
/// 1. a thin **ancestor icon rail** — one collapsed folder icon per ancestor of the current column
///    (`model.filesColumn.navigation.ancestors`), deepest nearest the current list, so the path is
///    legible without ever widening the overlay;
/// 2. the **current-folder list** — the full vertical list of `model.filesColumn.visibleEntries`, each
///    row a kind glyph + name + the metadata `AppSettings.filesRowMetadata` selects, with a search field
///    pinned at the top; and
/// 3. a **live preview** pane — a QuickLook content preview for a highlighted file (reusing the Clipboard
///    band's `FilePreview`) or a peek of a highlighted folder's contents.
///
/// At any depth exactly one current list + one preview are full-size; the rail stays a fixed width, so the
/// visible width is **bounded regardless of depth** (the whole point of D6). All sizes come from
/// `FilesBandLayout`, the single source `LauncherOverlayController` also reads to size the panel, so the
/// rendered surface and the `NSWindow` frame can never drift.
///
/// **Motion (design D8).** Containers / rows / preview / the rail bud in with `BubbleMorph`; a **depth**
/// change scales the current list down into its new ancestor icon while the incoming list buds in (the
/// `SwitcherView` `.id`/`.transition` idiom, but *scaling, not sliding*). The selection highlight is a
/// **single sliding element** (cloned from `ClipboardBandView.RowHighlight`) tracking
/// `highlightedIndex` — never re-created per row (that would reintroduce the documented scrub strobe), and
/// never bubble-morphed.
///
/// The overlay panel is **non-activating** (it never becomes key/main on its own); these animations are
/// display-only. The search field uses SwiftUI first-responder (`@FocusState`) the same way the AI canvas
/// flips the panel key-interactive for its controls — keyboard focus only resolves once the panel is made
/// key (a `LauncherOverlayController` concern), but the view-side focus wiring lives here.
struct FilesBandView: View {
    @ObservedObject var model: LauncherModel
    /// Live appearance/behaviour tunables (column width, density, tint, row metadata, icon style). The
    /// overlay layer reads the shared singleton (matching `LauncherOverlayController`'s panel sizer and the
    /// AI canvas's `@ObservedObject` settings), so a tweak in the Hub re-renders the open navigator.
    @ObservedObject var settings: AppSettings = .shared

    /// Mirror of the search field's text so the `TextField` is editable and so each keystroke re-evaluates
    /// `body` — which re-reads `controller.visibleEntries` after `setSearchQuery` has filtered it. The
    /// controller (a plain class, not an `ObservableObject`) doesn't republish on its own, so this `@State`
    /// is what drives the live-filter re-render.
    @State private var query: String = ""
    /// First-responder for the search field. Driven ONE-WAY from the model's `filesSearchFocused` (refinement
    /// 5) — set true on a top-of-column clamp-overflow up-step and false when a step-down moves the highlight
    /// back into the list — so it can never drift from the model the way a locally-toggled flag would. It only
    /// flips the `TextField`'s first-responder (so the made-key panel routes keystrokes here); the field's
    /// *highlighted appearance* reads `model.filesSearchFocused` directly, never this.
    @FocusState private var searchFocused: Bool

    /// Whether the failure row's raw "Show details" disclosure is expanded (collapsed by default — detail is
    /// opt-in, never shown inline; mirrors `ModelDetailView.showingDetails`). The raw OS/workspace text lives
    /// ONLY behind this disclosure, never in the headline.
    @State private var showingFailureDetails = false

    private var controller: FilesColumnController? { model.filesColumn }

    var body: some View {
        Group {
            if let controller {
                navigator(controller)
            } else {
                // Defensive: the Files band is only the current band when a controller is injected; an empty
                // surface keeps the view total without ever crashing on a missing controller.
                Color.clear
            }
        }
        .background(glassFill)
        // The Open-With picker buds in over the navigator when a relative +1-finger lift opens it, and
        // recedes the same way on exit (choose / discard) — a bounded popup centered on the band. It is an
        // overlay (not a replacement) so the column stays visible behind it, matching the user's "a popup
        // list opened over what I was looking at" vision.
        .overlay { openWithPicker }
        // A failed open surfaces as a BOUNDED, non-blocking row pinned to the bottom of the navigator —
        // never an app-modal alert (spec: failures are observable, never silent; bounded + non-blocking). It
        // buds in over the column (the navigator stays usable behind it) and recedes on Dismiss / a fresh open.
        .overlay(alignment: .bottom) { failureRow }
        // Mirror the field's first-responder onto the MODEL's `filesSearchFocused` (refinement 5), not a
        // local token that can drift: the model sets it TRUE on a top-of-column clamp-overflow and FALSE when
        // a step-down moves the highlight back into the list, and the controller flips the panel key-interactive
        // on the same signal — so the field first-responds while focused and resigns (un-highlighting) on the
        // step-down. The appearance reads `filesSearchFocused` directly (see `searchField`); this only keeps the
        // `@FocusState` in lockstep so the made-key panel actually routes keystrokes here.
        .onChange(of: model.filesSearchFocused) { _, focused in
            if searchFocused != focused { searchFocused = focused }
        }
        // Keep the field's text mirror in sync with the controller's own query (refinement 5a): the per-visit
        // clear — `searchQuery` is reset to "" on every descend/ascend in `FilesNavigationModel` — flows back
        // here, so returning to a folder (even immediately) shows an EMPTY field, never a stale query. A
        // gesture-driven clear or a fresh launcher open lands here the same way.
        .onChange(of: controller?.navigation.searchQuery ?? "") { _, q in
            if q != query { query = q }
        }
    }

    // MARK: - Layout: (rail | current list | preview) over a full-width breadcrumb bar

    /// The navigator is the three columns stacked OVER a full-width breadcrumb bar (refinement 4): the
    /// `HStack` of rail | current list | preview, then a bottom strip spanning all three columns rendering
    /// the path to the highlighted item. The whole thing is pinned to `FilesBandLayout`'s FIXED container
    /// size (= the Clipboard band's exact dimensions, refinement 3) so crossing in / changing depth never
    /// resizes or moves the panel; a folder taller than the fixed row area scrolls inside `currentList`.
    @ViewBuilder
    private func navigator(_ controller: FilesColumnController) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ancestorRail(controller)
                    .frame(width: FilesBandLayout.ancestorRailWidth)

                Divider().opacity(0.25)

                currentList(controller)
                    .frame(width: FilesBandLayout.currentColumnWidth)
                    // A depth change scales the whole current list down toward its ancestor icon / buds the
                    // incoming list in — the `SwitcherView` `.id`/`.transition` idiom, scaling not sliding
                    // (design D8). The depth token is the current location, so descend/ascend swap the subtree;
                    // the driving `.animation(value:)` sits on the enclosing HStack (the `SwitcherView` shape).
                    .id(depthID(controller))
                    .transition(.bubbleMorph(anchor: .leading))

                Divider().opacity(0.25)

                preview(controller)
                    .frame(width: FilesBandLayout.previewWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .animation(BubbleMorph.spring, value: depthID(controller))

            Divider().opacity(0.25)

            breadcrumbBar(controller)
                .frame(height: FilesBandLayout.breadcrumbBarHeight)
        }
        // FILL the FIXED panel (refinement 3) — exactly like `ClipboardBandView` fills its container — rather
        // than imposing an outer frame here. `LauncherOverlayController` already sizes the panel to the
        // CONSTANT `FilesBandLayout` dims (Clipboard-equal, no per-depth / per-density variation) and
        // `LauncherView` insets it by the shared container padding; the three fixed-width columns
        // (rail + current + preview + dividers) and the search/row-area/breadcrumb heights are computed from
        // those same constants to sum to the available area, so the surface and the window frame can't drift.
        // The container never resizes on crossing in or changing depth — the current list scrolls inside.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Ancestor icon rail (left)

    /// The collapsed path: one folder icon per ancestor, oldest at the top and the **deepest nearest the
    /// current list** (the rail reads downward toward where you are). Leaf glyphs, so the *icons* are not
    /// bubble-morphed; the rail container buds in once. Empty (but still reserved-width) at the roots list,
    /// so the current column never jumps sideways on the first descend.
    @ViewBuilder
    private func ancestorRail(_ controller: FilesColumnController) -> some View {
        let ancestors = controller.navigation.ancestors
        VStack(spacing: FilesBandLayout.ancestorRowSpacing) {
            ForEach(ancestors, id: \.self) { url in
                ancestorIcon(url)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 6)
        .bubbleMorph(anchor: .leading)
    }

    @ViewBuilder
    private func ancestorIcon(_ url: URL) -> some View {
        Image(systemName: "folder.fill")
            .font(.system(size: FilesBandLayout.ancestorIconSize * 0.62))
            .foregroundStyle(tint.opacity(0.85))
            .frame(width: FilesBandLayout.ancestorIconSize, height: FilesBandLayout.ancestorIconSize)
            .help(url.lastPathComponent)
    }

    // MARK: - Current folder list (centre)

    @ViewBuilder
    private func currentList(_ controller: FilesColumnController) -> some View {
        let entries = controller.visibleEntries
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            // The current-folder rows SCROLL inside the fixed container (refinement 3): a `ScrollViewReader`
            // + a vertical `ScrollView` (cloned from `ClipboardBandView.keyList`) so a folder taller than the
            // fixed row area scrolls to keep the highlight visible, driven by the same vertical edge-auto-
            // repeat that moves `highlightedIndex`. The single sliding highlight lives in the scrolled content
            // (so it tracks its row through the scroll), drawn BEHIND the rows exactly like the Clipboard list's
            // `.background(alignment: .top) { highlight }`, so the row text reads on top of the pill (design D8).
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .top) {
                        highlight(controller)

                        VStack(spacing: 0) {
                            ForEach(entries) { entry in
                                row(entry, controller: controller)
                                    .frame(height: rowHeight)
                                    // Row CONTENT comes/goes with the droplet: rows that bud in when a late
                                    // async listing lands or a search filters the list (the depth-swap itself
                                    // is governed by the whole list's `.id`/`.transition`, so this only fires
                                    // for membership changes within a stable depth — design D8). Never on the
                                    // sliding highlight. The row's `.id` is the scroll target the reader seeks.
                                    .id(entry.id)
                                    .transition(.bubbleMorph())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .animation(BubbleMorph.spring, value: entries.map(\.id))
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // Follow the highlight as the vertical edge-auto-repeat steps it: scroll the highlighted row
                // into view (centered, like the Clipboard key-list) whenever the index moves OR the listing
                // changes underneath it (a late async landing can shift which row is highlighted).
                .onChange(of: controller.highlightedIndex) { scroll(proxy, controller) }
                .onChange(of: entries.map(\.id)) { scroll(proxy, controller) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// Scroll the highlighted row into view (centered), the Files-band clone of `ClipboardBandView.scroll`:
    /// targets the entry at `highlightedIndex` within `visibleEntries` by its id, so the list follows the
    /// sliding highlight when the folder is taller than the fixed container. A no-op on an empty/over-filtered
    /// column (nothing highlighted to centre on).
    private func scroll(_ proxy: ScrollViewProxy, _ controller: FilesColumnController) {
        guard let id = controller.highlightedEntry?.id else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    // MARK: - Breadcrumb bar (bottom, full-width across all three columns)

    /// The full-width breadcrumb bar pinned at the BOTTOM (refinement 4), spanning the rail + current list +
    /// preview: `controller.breadcrumb` rendered root → chevron → … → the currently-HIGHLIGHTED item, compact
    /// and middle-truncating when long, updating live as the highlight moves (each highlight step re-derives
    /// the path in the model). Buds in with `BubbleMorph` like the band's other containers. A leading folder
    /// glyph anchors it; an empty path (nothing highlighted) shows nothing but keeps the strip's height so the
    /// container never reflows.
    @ViewBuilder
    private func breadcrumbBar(_ controller: FilesColumnController) -> some View {
        let components = controller.breadcrumb
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(tint.opacity(0.85))
            // Join the components with chevron separators on a SINGLE line, middle-truncating the whole crumb
            // string when the path is long (rather than wrapping or growing the fixed-height strip). The
            // highlighted leaf is the last component, so the tail (where you are) is what survives truncation.
            Text(breadcrumbText(components))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: FilesBandLayout.breadcrumbBarHeight)
        .bubbleMorph()
    }

    /// Render the breadcrumb components as `root › child › … › leaf` for the bottom bar. AppKit-free — the
    /// model names each component by its last path component (the view "can prettify"); here that prettifying
    /// is just joining them with a chevron so the single-line `Text` can middle-truncate the whole path.
    private func breadcrumbText(_ components: [FilesBreadcrumbComponent]) -> String {
        components.map(\.name).joined(separator: "  ›  ")
    }

    /// One current-list row: a kind glyph (or a QuickLook thumbnail when `filesIconStyle == .preview`),
    /// the display name, and the metadata selected by `AppSettings.filesRowMetadata`. Row **content** is
    /// allowed to bubble-morph (it's a container/row, not the sliding highlight), so a re-listed row buds
    /// in. The selection backing is the single sliding `highlight`, never a per-row fill.
    @ViewBuilder
    private func row(_ entry: FileEntry, controller: FilesColumnController) -> some View {
        let selected = entry.id == controller.highlightedEntry?.id
        HStack(spacing: 8) {
            rowGlyph(entry)
                .frame(width: 20, height: 20)
            Text(entry.name.isEmpty ? " " : entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 4)
            if let meta = metadataLabel(entry) {
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
    }

    /// The per-row leading glyph: a `FileKind` SF Symbol by default (`filesIconStyle == .icon`, cheap), or
    /// a live QuickLook thumbnail when the user picked `.preview` (icon fallback while it loads / when none
    /// exists). Reuses `FilePreview` for the thumbnail so there's one QuickLook surface.
    @ViewBuilder
    private func rowGlyph(_ entry: FileEntry) -> some View {
        switch settings.filesIconStyle {
        case .preview:
            FilePreview(url: entry.url)
        case .icon:
            kindGlyph(entry.kind)
        }
    }

    @ViewBuilder
    private func kindGlyph(_ kind: FileKind) -> some View {
        let symbol: String = {
            if case let .sfSymbol(name) = FilesBandBuilder.glyph(for: kind) { return name }
            return "doc"
        }()
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(kind == .folder ? tint : Color.secondary)
    }

    // MARK: - The single sliding selection highlight

    /// One persistent Liquid Glass pill that **slides** to the highlighted row by offsetting on its index
    /// (cloned from `ClipboardBandView.RowHighlight`). It is the Files band's analog of the grid's
    /// `SelectionSquare` / the clipboard list's `RowHighlight`: never re-created per row (that strobes while
    /// scrubbing — design D8), and never bubble-morphed. Hidden when the column is empty.
    @ViewBuilder
    private func highlight(_ controller: FilesColumnController) -> some View {
        if controller.highlightedEntry != nil {
            FilesRowHighlight(token: model.armingToken, armed: model.armed, dwell: model.dwell, color: tint)
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .offset(y: CGFloat(controller.highlightedIndex) * rowHeight)
                .animation(.easeOut(duration: 0.14), value: controller.highlightedIndex)
        }
    }

    // MARK: - Open-With picker (the held +1-finger app list, budded over the navigator)

    /// The Open-With popup: a bounded, BubbleMorph-entrance list of the apps that can open the highlighted
    /// file (`model.filesPicker`), centered over the navigator with the same tinted glass fill as the band.
    /// The user scrubs it vertically (the recognizer's highlight steps are routed to `filesPickerMove`) and
    /// lifts to choose. It uses the SAME single-sliding-highlight pattern as the folder list — one pill that
    /// offsets by the picker index, never a per-row fill — so scrubbing never strobes (design D8). The popup
    /// is a conditional member of this `ZStack`, so it buds in on insert and recedes on remove via the
    /// `.bubbleMorph()` membership transition (both sides governed by the one droplet shape), the bud spring
    /// driven from the enclosing `.animation(BubbleMorph.spring, value: model.filesPicker != nil)`.
    @ViewBuilder
    private var openWithPicker: some View {
        ZStack {
            if let picker = model.filesPicker {
                pickerPanel(picker)
                    .transition(.bubbleMorph())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(BubbleMorph.spring, value: model.filesPicker != nil)
    }

    /// The popup body: a header, then the candidate rows behind a single sliding selection pill (the same
    /// back-to-front layering the folder list uses). Bounded width/height so a long association list never
    /// overruns the band — the list is gesture-scrubbed, so it does not need to show every row at once, but
    /// the count here is small in practice (the apps that handle one file).
    @ViewBuilder
    private func pickerPanel(_ picker: LauncherModel.FilesPickerState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
                Text("Open With")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 4)

            ZStack(alignment: .top) {
                // The single sliding selection pill BEHIND the rows (drawn first = at the back), offset by
                // the picker index exactly like the folder list's highlight — never re-created per row.
                if picker.highlighted != nil {
                    OpenWithRowHighlight(color: tint)
                        .frame(height: pickerRowHeight)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                        .offset(y: CGFloat(picker.highlightedIndex) * pickerRowHeight)
                        .animation(.easeOut(duration: 0.14), value: picker.highlightedIndex)
                }

                VStack(spacing: 0) {
                    ForEach(picker.candidates) { candidate in
                        pickerRow(candidate)
                            .frame(height: pickerRowHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(10)
        .frame(width: pickerWidth)
        .frame(maxHeight: pickerMaxHeight)
        .background(pickerGlassFill)
    }

    /// One Open-With row: the application icon (the real bundle icon via `NSWorkspace`), its name, and a
    /// "Default" marker on the file's default application. A leaf content row (the selection backing is the
    /// single sliding pill, never a per-row fill).
    @ViewBuilder
    private func pickerRow(_ candidate: OpenWithCandidate) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.app.url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
            Text(candidate.app.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if candidate.isDefault {
                Text("Default")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(tint.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 10)
        .frame(height: pickerRowHeight)
    }

    /// The popup's glass fill: the availability-gated `glassEffect` (macOS 26+) with the `.ultraThinMaterial`
    /// fallback below it — a slightly more opaque, more rounded clone of `glassFill` so the popup reads as a
    /// distinct surface floating over the navigator.
    @ViewBuilder
    private var pickerGlassFill: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(0.16)), in: shape)
        } else {
            shape.fill(tint.opacity(0.12)).background(shape.fill(.ultraThinMaterial))
        }
    }

    /// The popup's fixed metrics: a comfortable single-column width and a per-row height a touch taller than
    /// a folder row (it carries an app icon), capped so a long association list scrolls-safe inside the band.
    private var pickerWidth: CGFloat { 280 }
    private var pickerRowHeight: CGFloat { 32 }
    private var pickerMaxHeight: CGFloat { 360 }

    // MARK: - Failure row (a failed open, surfaced bounded + non-blocking)

    /// The Files-band failure surface: a bounded card pinned to the bottom of the navigator when
    /// `model.filesOpenFailure != nil`, with the clean headline (capped + middle-truncating so an
    /// unexpectedly long message degrades instead of overrunning the band), an opt-in "Show details / Copy"
    /// disclosure for the raw text, and **Retry** + **Dismiss** affordances. It is a conditional member of
    /// this `ZStack`, so it buds in on insert and recedes on remove via the `.bubbleMorph()` membership
    /// transition (both sides governed by the one droplet shape) — never an app-modal alert (spec: bounded +
    /// non-blocking, never silent). The driving bud spring sits on the enclosing `.animation`.
    @ViewBuilder
    private var failureRow: some View {
        ZStack {
            if let failure = model.filesOpenFailure {
                failureCard(failure)
                    .transition(.bubbleMorph(anchor: .bottom))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(BubbleMorph.spring, value: model.filesOpenFailure)
    }

    /// The failure card body: a warning glyph + the clean headline, the opt-in details disclosure (only when
    /// there is raw text), then the action row. Bounded width/height; the headline never carries raw text.
    @ViewBuilder
    private func failureCard(_ failure: LauncherModel.FilesOpenFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                // The concise headline is primary: capped + middle-truncating so a long message degrades
                // gracefully instead of overflowing the fixed card (spec: bounded). Never raw error text.
                Text(failure.headline)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
            }

            // The raw OS/workspace text rides ONLY here, behind an opt-in disclosure — never inline.
            if let details = failure.details, !details.isEmpty {
                failureDetailsDisclosure(details)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    showingFailureDetails = false
                    model.onFilesRetryOpen?()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button {
                    showingFailureDetails = false
                    model.filesOpenFailure = nil   // Dismiss: clear the failure (a bounded, non-blocking exit)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: failureCardWidth)
        .frame(maxHeight: failureCardMaxHeight)
        .background(failureGlassFill)
        .padding(.bottom, 10)
    }

    /// A collapsed "Show details" disclosure for the raw technical text behind the failure: bounded (the text
    /// scrolls past ~120pt) so even a giant dump can't grow the card, with a "Copy details" action. Cloned
    /// from `ModelDetailView.detailsDisclosure` so the same error reads / copies identically everywhere.
    @ViewBuilder
    private func failureDetailsDisclosure(_ details: String) -> some View {
        DisclosureGroup(isExpanded: $showingFailureDetails) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(details, forType: .string)
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("Show details").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The failure card's glass fill: the availability-gated `glassEffect` (macOS 26+) with the
    /// `.ultraThinMaterial` fallback below it — the same tinted-glass surface idiom as `pickerGlassFill`, so
    /// the card reads as a distinct surface floating over the navigator.
    @ViewBuilder
    private var failureGlassFill: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(0.16)), in: shape)
        } else {
            shape.fill(tint.opacity(0.12)).background(shape.fill(.ultraThinMaterial))
        }
    }

    /// The failure card's fixed metrics: a comfortable bounded width and a capped height so an expanded
    /// details disclosure stays scroll-safe inside the band.
    private var failureCardWidth: CGFloat { 320 }
    private var failureCardMaxHeight: CGFloat { 280 }

    // MARK: - Search field (top of the current list)

    /// The type-to-filter field for the current folder. Its highlighted/focused appearance is driven by the
    /// MODEL's `filesSearchFocused` (refinement 5), NOT a local `@State` that drifts: it lights up ONLY while
    /// `filesSearchFocused` is true and visibly un-highlights when a step-down moves the highlight into the
    /// list (`filesSearchFocused → false`), leaving only the list-row highlight lit. The `@FocusState` is kept
    /// bound (mirrored from `filesSearchFocused` in `body`) so the field first-responds while focused — the
    /// controller makes the panel key-interactive on the same signal, so keystrokes actually land here. Typing
    /// filters `visibleEntries` live (each keystroke re-evaluates `body`, re-reading the now-filtered entries);
    /// this typed search is the app's single scoped keypress exception, and WE filter (a local case-insensitive
    /// filter in `FilesNavigationModel.visibleEntries`) — never an OS/Finder search (refinement 5a).
    private var searchField: some View {
        let focused = model.filesSearchFocused
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onChange(of: query) { _, q in controller?.setSearchQuery(q) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? tint.opacity(0.14) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? tint.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .bubbleMorph()
    }

    // MARK: - Live preview (right)

    /// The preview pane for the current highlight: a QuickLook content preview for a **file** (reusing the
    /// Clipboard band's `FilePreview`, with the file/app icon as a fallback), or a **peek** of a folder's
    /// contents (the same listing a descend would promote, so the peek and a subsequent descend agree). The
    /// pane buds in; switching highlight content re-buds via `.id` on the previewed entry. It is **not**
    /// separately navigable (there is no horizontal crossing into it — horizontal is the depth axis).
    @ViewBuilder
    private func preview(_ controller: FilesColumnController) -> some View {
        Group {
            switch controller.previewTarget {
            case let .file(entry):
                FilePreview(url: entry.url)
            case let .folder(entry, contents):
                FolderPeek(folder: entry, contents: contents, tint: tint)
            case nil:
                Color.clear
            }
        }
        // The previewed entry's id keys the swap, so moving the highlight tears down the old preview and
        // buds the new one in (and the leaving one recedes). Use the membership *transition* (not the
        // `.bubbleMorph()` modifier) across an `.id` swap so the same droplet shape governs BOTH sides,
        // per `BubbleMorph`'s own guidance; the driving `.animation(value:)` sits on the container.
        .id(previewID(controller))
        .transition(.bubbleMorph())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .animation(BubbleMorph.spring, value: previewID(controller))
    }

    /// A `Hashable` identity for whatever the preview currently shows — the highlighted entry's path, or a
    /// sentinel when the column is empty. Drives the preview's bud-in/recede on highlight changes.
    private func previewID(_ controller: FilesColumnController) -> String {
        controller.highlightedEntry?.id ?? "\u{2014}empty"
    }

    // MARK: - Glass fill (tinted from AppSettings.filesBandTint)

    /// The band surface fill: the availability-gated `glassEffect(.regular.tint(...))` (macOS 26+) with the
    /// `.ultraThinMaterial` fallback below it — cloned from `LauncherView.bandIconBackground` / `HubGlass`,
    /// tinted from `AppSettings.filesBandTint`. Subtle so the rows/preview read on top of it.
    @ViewBuilder
    private var glassFill: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(tint.opacity(0.12)), in: shape)
        } else {
            shape.fill(tint.opacity(0.08)).background(shape.fill(.ultraThinMaterial))
        }
    }

    // MARK: - Derived metrics & helpers

    /// The per-row height for the live density (`FilesBandLayout.rowHeight(for:)`) — also the highlight's
    /// slide step, so the highlight and the rows can never drift. (The current-list *column width* is the
    /// FIXED `FilesBandLayout.currentColumnWidth` now, not the live `filesColumnWidth` setting — refinement
    /// 3 pins the in-launcher navigator to the Clipboard-sized container, so the panel never resizes.)
    private var rowHeight: CGFloat { FilesBandLayout.rowHeight(for: settings.filesDensity) }

    /// The band tint as a SwiftUI `Color`, parsed from the `AppSettings.filesBandTint` hex (falling back to
    /// the builder's default blue if the hex is malformed). The single place the band's accent is resolved.
    private var tint: Color {
        Color(hexString: settings.filesBandTint) ?? Color(FilesBandBuilder.color)
    }

    /// A `Hashable` identity for the current depth (the `.id` the depth transition keys on): the current
    /// folder's path, or a sentinel for the roots list. Descend/ascend change it, so SwiftUI swaps the
    /// current-list subtree with the scaling bubble transition.
    private func depthID(_ controller: FilesColumnController) -> String {
        controller.current.folderURL?.path ?? "\u{1F4C1}roots"
    }

    /// The secondary metadata string for a row, per `AppSettings.filesRowMetadata` (an `OptionSet`, so
    /// several may show — joined with a middle dot). Folders show an item count for `.size`; files a byte
    /// size. Returns nil when no metadata is selected (or none is available).
    private func metadataLabel(_ entry: FileEntry) -> String? {
        var parts: [String] = []
        let meta = settings.filesRowMetadata
        if meta.contains(.date), let date = entry.modificationDate {
            parts.append(Self.dateFormatter.string(from: date))
        }
        if meta.contains(.kind) {
            parts.append(Self.kindLabel(entry.kind))
        }
        if meta.contains(.size) {
            if entry.isDirectory {
                if let count = controller?.cache[entry.url.standardizedFileURL.path]?.count {
                    parts.append("\(count) item\(count == 1 ? "" : "s")")
                }
            } else if let size = Self.fileSize(entry.url) {
                parts.append(Self.byteFormatter.string(fromByteCount: size))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Static formatters / label maps

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static func fileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    /// A human label for a `FileKind` (the `.kind` row metadata). View-layer concern, kept here.
    private static func kindLabel(_ kind: FileKind) -> String {
        switch kind {
        case .folder:      return "Folder"
        case .image:       return "Image"
        case .audio:       return "Audio"
        case .video:       return "Video"
        case .pdf:         return "PDF"
        case .archive:     return "Archive"
        case .sourceCode:  return "Code"
        case .text:        return "Text"
        case .application: return "App"
        case .other:       return "Document"
        }
    }
}

// MARK: - Folder-contents peek (preview pane, folder highlight)

/// A peek of a highlighted **folder's** contents in the preview pane: the same listing a descend would
/// promote to the current column (so the peek and the descend agree — `FilesNavigationModel.PreviewTarget
/// .folder(_, contents:)` carries it). A compact, NON-navigable list (horizontal is the depth axis, so the
/// preview is never crossed into) — a header, then a bounded run of rows, with an overflow count. Each row
/// buds in via the membership transition; the container buds via `BubbleMorph` at the call site.
private struct FolderPeek: View {
    let folder: FileEntry
    let contents: [FileEntry]
    let tint: Color

    /// Rows shown before an overflow line — bounded so a large folder's peek never overruns the pane.
    private let visibleLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(tint)
                Text(folder.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(contents.count) item\(contents.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider().opacity(0.2)
            if contents.isEmpty {
                Text("Empty folder").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(contents.prefix(visibleLimit)) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: peekSymbol(entry.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(entry.isDirectory ? tint : Color.secondary)
                            .frame(width: 16)
                        Text(entry.name).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                if contents.count > visibleLimit {
                    Text("+ \(contents.count - visibleLimit) more")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func peekSymbol(_ kind: FileKind) -> String {
        if case let .sfSymbol(name) = FilesBandBuilder.glyph(for: kind) { return name }
        return "doc"
    }
}

// MARK: - The sliding row highlight (Files band)

/// The Files band's list-row dwell highlight: a Liquid Glass pill that starts nearly clear and tints over
/// the dwell, then locks when armed — a clone of `ClipboardBandView.RowHighlight` (which is `private` to
/// that file). A single persistent view that **slides** between rows (the caller offsets it by index), so
/// scrubbing never strobes (design D8). `token` re-charges the pill per selection; it carries the existing
/// linear-charge / ease-out-arm motion vocabulary unchanged (no bubble-morph, no new haptics).
private struct FilesRowHighlight: View {
    let token: Int
    let armed: Bool
    let dwell: Double
    let color: Color
    @State private var intensity: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.tint(color.opacity(0.10 + 0.42 * intensity)), in: shape)
            } else {
                shape.fill(color.opacity(0.08 + 0.46 * intensity))
                    .background(shape.fill(.regularMaterial))
            }
        }
        .onAppear { restart() }
        .onChange(of: token) { restart() }
        .onChange(of: armed) { if armed { withAnimation(.easeOut(duration: 0.10)) { intensity = 1 } } }
    }

    private func restart() {
        intensity = 0
        withAnimation(.linear(duration: dwell)) { intensity = 1 }
    }
}

// MARK: - The sliding row highlight (Open-With picker)

/// The Open-With popup's selection pill: a static Liquid Glass pill that **slides** between app rows (the
/// caller offsets it by the picker index), so scrubbing the popup never strobes (design D8). Unlike the
/// list's `FilesRowHighlight` it does NOT charge over a dwell — the picker resolves on the lift (lift-to-
/// choose), not by arming — so it is a fixed-intensity selection backing, availability-gated like every
/// glass site with a `.regularMaterial` fallback.
private struct OpenWithRowHighlight: View {
    let color: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular.tint(color.opacity(0.34)), in: shape)
        } else {
            shape.fill(color.opacity(0.30)).background(shape.fill(.regularMaterial))
        }
    }
}

// MARK: - Hex → Color

extension Color {
    /// Build a `Color` from a `#RRGGBB` / `#RRGGBBAA` (or un-prefixed) hex string — the form
    /// `AppSettings.filesBandTint` persists. Returns nil for a malformed string so the caller can fall back
    /// to a default. 3-digit shorthand is not supported (the settings always write 6/8 digits).
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        if hex.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
