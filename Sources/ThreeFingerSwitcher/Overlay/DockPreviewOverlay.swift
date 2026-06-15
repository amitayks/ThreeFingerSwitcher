import AppKit
import SwiftUI

/// Card / popup metrics for the Dock-preview row. Every card shares a fixed thumbnail HEIGHT; its WIDTH
/// is derived from the window's own aspect ratio (so each tab fits its real proportions), clamped to a
/// sane range. The popup width is the sum of the cards' aspect-derived widths.
enum DockPreviewLayout {
    static let thumbHeight: CGFloat = 126
    static let titleHeight: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let padding: CGFloat = 16
    /// Vertical breathing room around the row so the hovered card's scale + accent border are never
    /// clipped at the top/bottom (the bug after removing the app-name header).
    static let rowVInset: CGFloat = 8
    /// Clamp the aspect-derived card width so a very portrait window isn't a sliver and a very wide one
    /// (e.g. ultrawide) doesn't dominate the row.
    static let minCardWidth: CGFloat = 96
    static let maxCardWidth: CGFloat = 300

    static var cardHeight: CGFloat { thumbHeight + 6 + titleHeight }
    static var height: CGFloat { padding * 2 + rowVInset * 2 + cardHeight }

    /// A card's width for a window of `aspect` (width/height): the fixed thumbnail height × aspect,
    /// clamped. A non-finite/zero aspect falls back to 16:10.
    static func cardWidth(forAspect aspect: CGFloat) -> CGFloat {
        let a = (aspect.isFinite && aspect > 0) ? aspect : 1.6
        return min(max(thumbHeight * a, minCardWidth), maxCardWidth)
    }

    /// Desired popup size for cards of the given aspects, clamped to the available screen width (the row
    /// scrolls horizontally when it would overflow).
    static func size(forAspects aspects: [CGFloat], maxWidth: CGFloat) -> CGSize {
        let widths = aspects.map(cardWidth(forAspect:))
        let content = padding * 2 + widths.reduce(0, +) + cardSpacing * CGFloat(max(aspects.count - 1, 0))
        let floorWidth = padding * 2 + minCardWidth
        return CGSize(width: min(max(content, floorWidth), maxWidth), height: height)
    }
}

/// Owns the **mouse-interactive** Dock-preview popup panel. Unlike every other overlay in the app it does
/// NOT ignore the mouse — it must receive hover and click on its thumbnails. It is still a
/// `.nonactivatingPanel` and never becomes key/main (no keyboard input), so it never steals focus and the
/// previously focused window stays the raise target. Teardown is **synchronous** (`orderOut`) — the
/// files-band ghost-on-Space-switch landmine applies here too.
@MainActor
final class DockPreviewOverlayController {
    let model = DockPreviewModel()
    private var panel: SwitcherPanel?

    /// A card was hovered (`inside == true`) or unhovered. Drives the live peek.
    var onHover: ((CGWindowID, Bool) -> Void)?
    /// A card was clicked — commit (raise) that window.
    var onCommit: ((CGWindowID) -> Void)?
    /// Retry / dismiss the bounded error card.
    var onRetryError: (() -> Void)?

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: DockPreviewLayout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The ONE overlay that takes the pointer: hover + click on thumbnails are the whole interaction.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: DockPreviewView(
            model: model,
            onHover: { [weak self] id, inside in self?.onHover?(id, inside) },
            onCommit: { [weak self] id in self?.onCommit?(id) },
            onRetryError: { [weak self] in self?.onRetryError?() },
            onDismissError: { [weak self] in self?.model.dismissError() }
        ))
        return panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    /// Show (or move) the popup at `rect`.
    func show(at rect: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    /// Synchronous teardown (no deferred close — Space-switch ghost landmine).
    func hide() {
        panel?.orderOut(nil)
    }
}

/// The Dock-preview row: a slim header (app name) over a horizontally-scrolling row of window cards. The
/// hovered card enlarges and shows the live peek; minimized windows are badged. A bounded, non-blocking
/// error card replaces the row on a failed commit.
struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    let onHover: (CGWindowID, Bool) -> Void
    let onCommit: (CGWindowID) -> Void
    let onRetryError: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        Group {
            if let error = model.error {
                errorCard(error)
                    .padding(DockPreviewLayout.padding)
            } else {
                row
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }

    private var row: some View {
        // No app-name header — just the tabs. The vertical inset keeps the hovered card's scale +
        // accent border from clipping against the top/bottom of the container.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DockPreviewLayout.cardSpacing) {
                ForEach(model.windows) { window in
                    card(window)
                }
            }
            .padding(.horizontal, DockPreviewLayout.padding)
            .padding(.vertical, DockPreviewLayout.padding + DockPreviewLayout.rowVInset)
        }
    }

    private func card(_ window: DockPreviewWindow) -> some View {
        let isHot = model.highlightedID == window.id
        let cardW = DockPreviewLayout.cardWidth(forAspect: window.aspect)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.25))
                if let thumb = model.thumbnails[window.id] {
                    // The card is ALREADY sized to the window's aspect, so fill crops only the hairline
                    // difference between the AX frame (card aspect) and the captured image's frame — no
                    // wrong-aspect mangling. Fill (not fit) means every frame lands edge-to-edge in the
                    // same place, so the seed→live swap doesn't sit off-center or jump to re-center.
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cardW, height: DockPreviewLayout.thumbHeight)
                        .clipped()
                } else if let icon = model.icons[window.id] {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
                        .opacity(0.9)
                }
                if window.isMinimized {
                    VStack {
                        Spacer()
                        Text("Minimized")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
            }
            .frame(width: cardW, height: DockPreviewLayout.thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHot ? Color.accentColor : .white.opacity(0.10), lineWidth: isHot ? 2 : 1))
            .opacity(window.isMinimized && !isHot ? 0.7 : 1)

            Text(window.title.isEmpty ? model.appName : window.title)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: cardW, height: DockPreviewLayout.titleHeight)
                .foregroundStyle(isHot ? .primary : .secondary)
        }
        .scaleEffect(isHot ? 1.06 : 1)
        .shadow(color: .black.opacity(isHot ? 0.35 : 0), radius: isHot ? 10 : 0, y: isHot ? 4 : 0)
        .animation(.easeOut(duration: 0.12), value: isHot)
        .contentShape(Rectangle())
        .onHover { inside in onHover(window.id, inside) }
        .onTapGesture { onCommit(window.id) }
    }

    @ViewBuilder
    private func errorCard(_ error: DockPreviewError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.errorDescription ?? "Something went wrong.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3).truncationMode(.middle)
            if let details = error.copyableDetails {
                DisclosureGroup("Show details") {
                    ScrollView { Text(details).font(.caption.monospaced()).textSelection(.enabled) }
                        .frame(maxHeight: 80)
                }
                .font(.caption)
            }
            HStack {
                Button("Retry") { onRetryError() }
                Button("Dismiss") { onDismissError() }
                Spacer()
            }
            .controlSize(.small)
        }
        .frame(width: 320)
    }
}
