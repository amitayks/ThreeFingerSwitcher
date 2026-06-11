import SwiftUI
import AppKit

extension Color {
    /// Bridge the AppKit-free `ItemColor` model value into a SwiftUI color.
    init(_ c: ItemColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}

/// The launcher HUD, styled like the macOS "Applications" grid: one big rounded container whose bands
/// render as a **vertical title list on the left** and the active band's items as a multi-column grid
/// on the **right** that scrolls vertically on overflow. The cursor is 2D — `.bands` (the left list)
/// or `.grid` (see `LauncherModel`); vertical switches the band on the list, horizontal crosses
/// between the list and the grid. The selection is a single Liquid Glass square that darkens over the
/// dwell, then arms (haptic).
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    /// The AI command executor whose streaming state the preview canvas observes (nil when AI commands
    /// aren't wired — the canvas is then never reached because no `.aiCommand` item can be fired).
    var executor: AICommandExecutor? = nil
    /// Enable/download wiring for the canvas's `.unavailable` state (configuration-hub).
    var availability: AICanvasAvailability? = nil

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(LauncherGridLayout.cellWidth), spacing: LauncherGridLayout.spacing),
              count: LauncherGridLayout.columns)
    }

    var body: some View {
        Group {
            // The AI streaming preview canvas replaces the whole surface while it is open (an AI command
            // was fired and is generating / awaiting commit) — no band list alongside it. Everything
            // else is the master-detail shell: the band list on the left, the content on the right.
            if model.canvasActive {
                canvas
            } else {
                HStack(spacing: 0) {
                    // The left band-title list only exists when there's more than one band to choose
                    // between; a single band shows just its content (lands on `.grid`, item 0).
                    if model.bandCount > 1 {
                        bandList
                    }
                    // The right pane: the Clipboard band's master-detail, else the icon grid.
                    if model.currentBandIsClipboard {
                        ClipboardBandView(model: model)
                    } else {
                        grid
                    }
                }
            }
        }
        .padding(LauncherGridLayout.containerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.ultraThinMaterial)
        )
    }

    /// The AI preview canvas, bound to the executor's streaming state. When no executor is wired it
    /// falls back to an empty surface (defensive — the canvas is unreachable without one).
    @ViewBuilder
    private var canvas: some View {
        if let executor, let command = model.canvasCommand {
            AICommandCanvasView(executor: executor, command: command,
                                tint: command.tint.map(Color.init) ?? Color(model.currentBandColor),
                                availability: availability)
        } else {
            Color.clear
        }
    }

    // MARK: Band icon list (the left column)

    /// The vertical list of band **icons** on the left, at a fixed small spacing and centered in the
    /// column (not spread). Only the highlighted (active) band's icon shows its band color; the rest are
    /// colorless until selected. The hidden band name is exposed as a tooltip for discoverability.
    private var bandList: some View {
        VStack(spacing: LauncherGridLayout.bandRowSpacing) {
            ForEach(Array(model.bandNames.enumerated()), id: \.offset) { idx, name in
                bandIcon(idx: idx).help(name)
            }
        }
        .frame(width: LauncherGridLayout.bandColumnWidth - LauncherGridLayout.containerPadding)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func bandIcon(idx: Int) -> some View {
        let isActive = (idx == model.currentBand)                            // whose content is shown
        let isCursor = (model.focus == .bands && idx == model.currentBand)   // cursor on the band list
        let color = model.bandColors.indices.contains(idx)
            ? Color(model.bandColors[idx]) : Color(model.currentBandColor)
        ZStack {
            bandIconBackground(isCursor: isCursor)
            bandIconGlyph(idx: idx, active: isActive, color: color)
                .frame(width: LauncherGridLayout.bandIconSize, height: LauncherGridLayout.bandIconSize)
        }
        .frame(width: LauncherGridLayout.bandIconSize + 18, height: LauncherGridLayout.bandIconSize + 18)
        .scaleEffect(isCursor ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.12), value: isCursor)
    }

    /// Render a band's icon. The active band shows its band color; inactive bands are colorless (a
    /// secondary tint for symbols, dimmed for emoji, which can't be desaturated) so color marks the
    /// current band.
    @ViewBuilder
    private func bandIconGlyph(idx: Int, active: Bool, color: Color) -> some View {
        let icon = model.bandIcons.indices.contains(idx) ? model.bandIcons[idx] : .sfSymbol("square.grid.2x2.fill")
        switch icon {
        case .sfSymbol(let name):
            Image(systemName: name).resizable().scaledToFit()
                .foregroundStyle(active ? color : Color.secondary)
        case .emoji(let glyph):
            Text(glyph).font(.system(size: LauncherGridLayout.bandIconSize * 0.92))
                .opacity(active ? 1 : 0.45)
        case .appDefault, .fileIcon:
            // Bands don't use app/file icons; fall back to a neutral symbol.
            Image(systemName: "square.grid.2x2.fill").resizable().scaledToFit()
                .foregroundStyle(active ? color : Color.secondary)
        }
    }

    /// Only the icon under the cursor (on the band list) gets a subtle backing; the rest are bare.
    @ViewBuilder
    private func bandIconBackground(isCursor: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *), isCursor {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color.white.opacity(isCursor ? 0.22 : 0.0))
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
                .padding(.top, LauncherGridLayout.gridTopInset)
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
            case .aiCommand: return "sparkles"
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
