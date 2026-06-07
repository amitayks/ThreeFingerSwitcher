import SwiftUI
import AppKit

extension Color {
    /// Bridge the AppKit-free `ItemColor` model value into a SwiftUI color.
    init(_ c: ItemColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

/// The launcher HUD, styled like the macOS "Applications" grid: one big rounded container with
/// category tabs across the top and the current band's items in a multi-column grid that scrolls
/// vertically on overflow. The cursor is 2D and can rise onto the headers row (see `LauncherModel`).
/// The selection is a single Liquid Glass square that darkens over the dwell, then arms (haptic).
struct LauncherView: View {
    @ObservedObject var model: LauncherModel

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(LauncherGridLayout.cellWidth), spacing: LauncherGridLayout.spacing),
              count: LauncherGridLayout.columns)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Divider().opacity(0.35)
            if model.currentBandIsClipboard {
                ClipboardBandView(model: model)
            } else {
                grid
            }
        }
        .padding(LauncherGridLayout.containerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial)
        )
    }

    // MARK: Category tabs (the headers row)

    private var tabs: some View {
        HStack(spacing: 10) {
            ForEach(Array(model.bandNames.enumerated()), id: \.offset) { idx, name in
                headerPill(idx: idx, name: name)
            }
        }
        .frame(height: LauncherGridLayout.tabsHeight - LauncherGridLayout.containerPadding,
               alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func headerPill(idx: Int, name: String) -> some View {
        let isCursor = (model.focus == .headers && idx == model.currentBand)   // cursor on the headers
        let isActive = (idx == model.currentBand)                              // whose grid is shown
        Text(name)
            .font(.system(size: 14, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(headerBackground(isCursor: isCursor))
            .scaleEffect(isCursor ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isCursor)
    }

    /// Every category pill shares one neutral background (the band's color lives on its items, not
    /// here). Only the pill being highlighted to select it (cursor on the headers) brightens — the
    /// active band is distinguished by its bolder, brighter text instead.
    @ViewBuilder
    private func headerBackground(isCursor: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *), isCursor {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color.white.opacity(isCursor ? 0.26 : 0.07))
        }
    }

    // MARK: Icon grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: LauncherGridLayout.spacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        cell(item, selected: model.focus == .grid && idx == model.selectedIndex)
                            .id(item.id)
                    }
                }
                .padding(.top, 14)
            }
            .onChange(of: model.selectedIndex) { scroll(proxy) }
            .onChange(of: model.focus) { scroll(proxy) }
            .onChange(of: model.currentBand) { proxy.scrollTo(scrollTarget, anchor: .top) }
        }
    }

    private var scrollTarget: AnyHashable? {
        guard model.focus == .grid, model.items.indices.contains(model.selectedIndex) else { return nil }
        return model.items[model.selectedIndex].id
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        withAnimation(.easeInOut(duration: 0.16)) { proxy.scrollTo(target, anchor: .center) }
    }

    @ViewBuilder
    private func cell(_ item: LaunchItem, selected: Bool) -> some View {
        let bandColor = Color(model.currentBandColor)
        VStack(spacing: 8) {
            ZStack {
                if selected {
                    SelectionSquare(token: model.armingToken, armed: model.armed,
                                    dwell: model.dwell, color: bandColor)
                }
                iconView(item)
                    .frame(width: LauncherGridLayout.iconSize, height: LauncherGridLayout.iconSize)
                if let marker = kindMarker(item) {
                    VStack { HStack { Spacer(); marker }; Spacer() }
                        .padding(6)
                        .frame(width: LauncherGridLayout.iconSize + 26, height: LauncherGridLayout.iconSize + 26)
                }
            }
            .frame(width: LauncherGridLayout.iconSize + 30, height: LauncherGridLayout.iconSize + 30)
            .scaleEffect(selected ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.12), value: selected)

            Text(item.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(width: LauncherGridLayout.cellWidth - 8)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .frame(width: LauncherGridLayout.cellWidth, height: LauncherGridLayout.cellHeight)
    }

    @ViewBuilder
    private func iconView(_ item: LaunchItem) -> some View {
        switch item.icon {
        case .appDefault:
            Image(nsImage: appIcon(for: item)).resizable().aspectRatio(contentMode: .fit)
        case .fileIcon:
            Image(nsImage: fileIcon(for: item)).resizable().aspectRatio(contentMode: .fit)
        case .sfSymbol(let name):
            Image(systemName: name).font(.system(size: 48))
                .foregroundStyle(item.tint.map(Color.init) ?? Color(model.currentBandColor))
        case .emoji(let glyph):
            Text(glyph).font(.system(size: 48))
        }
    }

    @ViewBuilder
    private func kindMarker(_ item: LaunchItem) -> (some View)? {
        let symbol: String? = {
            switch item.kind {
            case .preset: return "square.stack.3d.up.fill"
            case .script: return "terminal.fill"
            default: return nil
            }
        }()
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
    }

    private func appIcon(for item: LaunchItem) -> NSImage {
        if case let .app(bundleURL, _) = item.kind {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    private func fileIcon(for item: LaunchItem) -> NSImage {
        if case let .path(url) = item.kind {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage()
    }
}

/// The single selection highlight: a Liquid Glass rounded square that starts nearly transparent and
/// darkens over the dwell, then locks when armed. No ring, no checkmark. Driven by `token` (bumped
/// per item selection) so it re-animates each time a new item starts charging.
private struct SelectionSquare: View {
    let token: Int
    let armed: Bool
    let dwell: Double
    let color: Color
    @State private var intensity: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
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
