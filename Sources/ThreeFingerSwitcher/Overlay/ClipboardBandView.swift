import SwiftUI
import AppKit
import QuickLookThumbnailing

/// The Clipboard band's master-detail body: a multi-line list of truncated **keys** on the left and a
/// large **value preview** on the right showing the selected entry's *actual content* (rendered image,
/// QuickLook file preview, full text, or color swatch). Navigated by the same scrub/dwell/lift as the
/// grid; horizontal is repurposed (RIGHT pins, LEFT → previous band) up in `LauncherModel`.
struct ClipboardBandView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        if model.items.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                keyList
                    .frame(width: ClipboardBandLayout.keyColumnWidth)
                Divider().opacity(0.3)
                valuePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No clipboard history yet").font(.system(size: 15, weight: .medium))
            Text("Copy something and it shows up here.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Key list (left)

    /// Per-row vertical stride (row height + inter-row spacing) — also the highlight's step.
    private static let rowSpacing: CGFloat = 4
    private static var rowStride: CGFloat { ClipboardBandLayout.keyRowHeight + rowSpacing }

    private var keyList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                        keyRow(item, selected: model.focus == .grid && idx == model.selectedIndex)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                // A SINGLE highlight that slides to the selected row, instead of one created/destroyed
                // per row (which strobes while scrubbing). Lives in the scrolled content's space so it
                // tracks its row through scrolling.
                .background(alignment: .top) { highlight }
            }
            .onChange(of: model.selectedIndex) { scroll(proxy) }
            .onChange(of: model.focus) { scroll(proxy) }
        }
    }

    @ViewBuilder
    private var highlight: some View {
        if model.focus == .grid, model.items.indices.contains(model.selectedIndex) {
            RowHighlight(token: model.armingToken, armed: model.armed, dwell: model.dwell,
                         color: Color(model.currentBandColor))
                .frame(height: ClipboardBandLayout.keyRowHeight)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .offset(y: CGFloat(model.selectedIndex) * Self.rowStride)
                .animation(.easeOut(duration: 0.14), value: model.selectedIndex)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard model.focus == .grid, model.items.indices.contains(model.selectedIndex) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            proxy.scrollTo(model.items[model.selectedIndex].id, anchor: .center)
        }
    }

    @ViewBuilder
    private func keyRow(_ item: LaunchItem, selected: Bool) -> some View {
        let color = Color(model.currentBandColor)
        HStack(spacing: 8) {
            iconGlyph(item.icon).frame(width: 18)
            Text(item.title.isEmpty ? " " : item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 4)
            if model.isPinned(item) {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(color)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardBandLayout.keyRowHeight)
        // Selection highlight is a single sliding overlay (see `highlight`), not a per-row background.
    }

    @ViewBuilder
    private func iconGlyph(_ icon: ItemIcon) -> some View {
        switch icon {
        case .sfSymbol(let name): Image(systemName: name).font(.system(size: 13)).foregroundStyle(.secondary)
        case .emoji(let g):       Text(g).font(.system(size: 13))
        default:                  Image(systemName: "doc").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    // MARK: Value preview (right)

    @ViewBuilder
    private var valuePreview: some View {
        if let entry = selectedEntry {
            ClipboardValueView(entry: entry)
                .padding(16)
        } else {
            Color.clear
        }
    }

    private var selectedEntry: ClipboardEntry? {
        guard let item = model.selectedItem, case let .clipboardEntry(entry) = item.kind else { return nil }
        return entry
    }
}

/// Renders one entry's actual content, full size (overflow clips — there is no focusable value pane).
struct ClipboardValueView: View {
    let entry: ClipboardEntry

    var body: some View {
        switch entry.kind {
        case .text, .richText, .url:
            ScrollView {
                Text(text ?? "")
                    .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                    .textSelection(.disabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .image:
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { placeholder("photo") }
        case .file:
            if let url = fileURL { FilePreview(url: url) } else { placeholder("doc") }
        case .color:
            colorSwatch
        }
    }

    // MARK: Decoded content

    private var text: String? {
        entry.data(for: ClipboardUTI.plainText).flatMap { String(data: $0, encoding: .utf8) } ?? entry.key
    }

    /// Heuristic: show text that looks like code/structured data in a monospaced font.
    private var monospaced: Bool {
        guard let t = text else { return false }
        return t.contains("{") || t.contains(";") || t.contains("\t") || t.contains("()")
    }

    private var image: NSImage? {
        (entry.data(for: ClipboardUTI.png) ?? entry.data(for: ClipboardUTI.tiff)).flatMap { NSImage(data: $0) }
    }

    private var fileURL: URL? {
        entry.data(for: ClipboardUTI.fileURL)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { URL(string: $0) }
    }

    @ViewBuilder
    private var colorSwatch: some View {
        let color = decodedColor
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(color.map(Color.init) ?? Color.gray)
                .frame(width: 160, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.2)))
            Text(entry.key).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var decodedColor: NSColor? {
        guard let data = entry.data(for: ClipboardUTI.color) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private func placeholder(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Async QuickLook content preview for a file entry — the actual rendered content (PDF page, document
/// thumbnail, etc.), not just the file's icon. Falls back to the Finder icon if QuickLook has nothing.
private struct FilePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) { await load() }
    }

    private func load() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 700, height: 700), scale: 2,
            representationTypes: .all)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

/// A list-row dwell highlight: a Liquid Glass pill that starts nearly clear and tints over the dwell,
/// then locks when armed — the list analog of the grid's `SelectionSquare`. It is a single persistent
/// view that slides between rows (see `highlight`), so scrubbing doesn't strobe. `token` re-animates
/// the charge per selection.
private struct RowHighlight: View {
    let token: Int
    let armed: Bool
    let dwell: Double
    let color: Color
    @State private var intensity: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
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
