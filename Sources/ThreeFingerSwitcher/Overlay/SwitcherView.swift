import SwiftUI

/// AltTab-style horizontal strip of window cards with a moving highlight. The highlight is
/// bound to `model.selectedIndex` so it moves without rebuilding the strip; the strip
/// auto-scrolls to keep the selected card visible.
struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    private let cardWidth = SwitcherLayout.cardInnerWidth
    private let cardHeight = SwitcherLayout.cardHeight

    var body: some View {
        ZStack {
            // Re-identified per Space-row so a row change slides the old strip out and the new
            // one in (direction from lastRowDirection), instead of cutting instantly.
            strip
                .id(model.currentRow)
                .transition(rowTransition)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.32), value: model.currentRow)
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

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SwitcherLayout.interCardSpacing) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                        card(window, selected: index == model.selectedIndex)
                            .id(index)
                    }
                }
                .padding(SwitcherLayout.stripPadding)
                .padding(.leading, model.rowCount > 1 ? SwitcherLayout.rowIndicatorGutter : 0)
            }
            // Only scroll when the strip overflows; otherwise the content hugs the panel
            // (which is sized to the content) and there is nothing to scroll or bounce.
            .scrollDisabled(!model.overflow)
            .onChange(of: model.selectedIndex) { _, newValue in
                guard model.overflow else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Vertical slide+fade; direction follows the row change (up = next Space).
    private var rowTransition: AnyTransition {
        let up = model.lastRowDirection >= 0
        return .asymmetric(
            insertion: .move(edge: up ? .bottom : .top).combined(with: .opacity),
            removal: .move(edge: up ? .top : .bottom).combined(with: .opacity)
        )
    }

    /// Vertical dots on the left showing which Space-row is active and how many exist. The first
    /// Space-row (current) is at the bottom so swiping up moves the highlight upward. Hidden for
    /// a single row.
    @ViewBuilder
    private var rowIndicator: some View {
        if model.rowCount > 1 {
            VStack(spacing: 8) {
                ForEach((0..<model.rowCount).reversed(), id: \.self) { i in
                    Circle()
                        .fill(i == model.currentRow ? Color.accentColor : Color.white.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.leading, 11)
        }
    }

    @ViewBuilder
    private func card(_ window: WindowInfo, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.25))
                if let thumb = model.thumbnails[window.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let icon = window.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                }
            }
            .frame(width: cardWidth, height: cardHeight)

            HStack(spacing: 6) {
                if let icon = window.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(window.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: cardWidth)
        }
        .padding(SwitcherLayout.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.35) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
        .scaleEffect(selected ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}
