import SwiftUI

/// Mission-Control-style grid of window cards, each at its TRUE proportion (one uniform scale across
/// all windows) wrapped into balanced rows. Every Space is laid out on one canvas as a vertical
/// **reel**: switching Space animates a single offset so all Spaces translate together (nothing is
/// created/destroyed), staying smooth even when switching fast. The visible container **hugs the
/// current Space** and morphs to fit as the reel moves; the NSPanel behind it is stable (max-sized,
/// transparent), so the container resize and the reel slide animate together in one SwiftUI pass.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    private var contentSize: CGSize { model.gridLayout.contentSize }

    var body: some View {
        // The hugging container, centered within the (larger, transparent) panel.
        container
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var container: some View {
        VStack(spacing: 10) {
            reel
            titleBar
                .frame(height: SwitcherLayout.titleAreaHeight - 10)
        }
        .padding(SwitcherLayout.gridContainerPadding)
        .padding(.leading, model.rowCount > 1 ? SwitcherLayout.rowIndicatorGutter : 0)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .leading) { rowIndicator }
    }

    /// The reel: every Space's grid stacked in one column (highest-index Space on top, matching the
    /// indicator), each cell at its OWN content height, translated by a single offset so the current
    /// Space sits at the viewport top. The viewport is sized to the current Space (so the container
    /// hugs it) and clips the rest of the reel. Moving to a LATER Space rolls the reel DOWN (the new
    /// Space, which sits above, descends into view); an EARLIER Space rolls it UP. The animation is
    /// applied explicitly on a switch (see `OverlayController.updateRow`), never on appearance.
    private var reel: some View {
        let n = model.rowCount
        let cur = contentSize
        return VStack(spacing: SwitcherLayout.gridRowSpacing) {
            ForEach(Array((0..<max(n, 0)).reversed()), id: \.self) { space in
                spaceGrid(space)
                    .frame(width: cur.width, height: cellHeight(space))
            }
        }
        .offset(y: reelOffset())
        .frame(width: cur.width, height: cur.height, alignment: .top)
        .clipped()
    }

    /// The natural content height of a Space's grid (its reel cell height).
    private func cellHeight(_ space: Int) -> CGFloat {
        model.spaceGrids.indices.contains(space) ? model.spaceGrids[space].contentSize.height : 0
    }

    /// Reel translation: minus the total height of every cell stacked ABOVE the current one (the
    /// higher-index Spaces, plus the inter-cell gaps), which puts the current Space's cell at the
    /// viewport top.
    private func reelOffset() -> CGFloat {
        let n = model.rowCount
        guard n > 0 else { return 0 }
        var above: CGFloat = 0
        var j = model.currentRow + 1
        while j < n {
            above += cellHeight(j) + SwitcherLayout.gridRowSpacing
            j += 1
        }
        return -above
    }

    /// One Space's grid, centered within its reel cell: balanced rows of variable-size cards.
    @ViewBuilder
    private func spaceGrid(_ space: Int) -> some View {
        let layout = model.spaceGrids.indices.contains(space) ? model.spaceGrids[space] : .empty
        let windows = model.rows.indices.contains(space) ? model.rows[space] : []
        VStack(spacing: SwitcherLayout.gridRowSpacing) {
            ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: SwitcherLayout.gridCardSpacing) {
                    ForEach(row, id: \.self) { index in
                        if windows.indices.contains(index), layout.sizes.indices.contains(index) {
                            card(window: windows[index], size: layout.sizes[index],
                                 selected: space == model.currentRow && index == model.selectedIndex)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // center the grid within its reel cell
    }

    /// Vertical dots on the left showing which Space is active and how many exist. The first Space is
    /// at the bottom so swiping up moves the highlight upward. Hidden for a single Space. While the
    /// Space relocation still awaits its re-login the dots dim and a pending glyph sits above them.
    @ViewBuilder
    private var rowIndicator: some View {
        if model.rowCount > 1 {
            VStack(spacing: 8) {
                if model.rowSwitchingPending {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help("Log out and back in to switch Spaces here")
                }
                ForEach((0..<model.rowCount).reversed(), id: \.self) { i in
                    Circle()
                        .fill(dotColor(isCurrent: i == model.currentRow))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.leading, 11)
        }
    }

    private func dotColor(isCurrent: Bool) -> Color {
        if model.rowSwitchingPending {
            return Color.white.opacity(isCurrent ? 0.35 : 0.15)   // gated: the whole axis dims
        }
        return isCurrent ? Color.accentColor : Color.white.opacity(0.35)
    }

    /// The single highlighted-window title beneath the reel (Mission-Control idiom) — replaces the
    /// per-card title row. Updates as the highlight moves without rebuilding the grid. Bounded to the
    /// current grid's content width (NOT `.infinity`) so it centers over the grid and truncates within
    /// it — otherwise the title row stretches to the max-sized panel and the visible container can't hug
    /// the current Space's WIDTH the way it already hugs its height.
    @ViewBuilder
    private var titleBar: some View {
        if let window = model.selectedWindow {
            HStack(spacing: 6) {
                if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(window.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Hard-CUT the icon+title on selection change (no crossfade), so it swaps the same way a
            // within-row window move already does — even during a Space switch's animated reel slide,
            // whose ambient `withAnimation` would otherwise give the text/icon a fade content-transition.
            // Stripping the animation on the CONTENT subtree only (the `.frame` is applied OUTSIDE this
            // transaction) keeps the container width hugging/animating with the reel while the title snaps.
            .transaction { $0.animation = nil }
            .frame(width: max(contentSize.width, 1))
        }
    }

    /// One window card at its solved size. The thumbnail is scaled to **fit** (letterbox) within the
    /// card's real-proportion bounds, NOT cropped to fill: a clean capture (whose aspect matches the
    /// card) still fills it edge-to-edge, while a wrong-aspect transitional / in-flight frame that
    /// slipped past the capture-side gates is shown harmlessly reduced rather than smeared sideways. The
    /// selection highlight is keyed to the current Space + `selectedIndex` (one card at a time), so the
    /// moving highlight never strobes.
    @ViewBuilder
    private func card(window: WindowInfo, size: CGSize, selected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
            if let thumb = model.thumbnails[window.id] {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: min(64, size.width * 0.5), height: min(64, size.height * 0.5))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.10),
                              lineWidth: selected ? 3 : 1)
        )
    }
}
