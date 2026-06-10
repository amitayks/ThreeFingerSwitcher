import SwiftUI

/// Shared Liquid Glass / material treatment so the configuration Hub reads like the runtime overlays.
/// `LauncherView` / `SwitcherView` / `ClipboardBandView` all use the same `glassEffect(.regular)` (on
/// macOS 26+) with an `.ultraThinMaterial` fallback below it; the Hub reuses that exact idiom so the
/// window and the overlays feel like one app.
struct HubGlass: View {
    var cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }
}

extension View {
    /// Wrap content as a rounded "card" with the app's glass/material background — the grouping unit
    /// for Hub pages (one card per logical section), echoing the overlays' rounded glass surfaces.
    func hubCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(HubGlass(cornerRadius: cornerRadius))
    }
}

/// A titled section on a Hub page: a caption-styled header above a glass card of content. Pages stack
/// these inside a scroll view so any one section can grow without breaking the layout.
struct HubSection<Content: View>: View {
    let title: String?
    let footnote: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hubCard()
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A standard scroll-safe page scaffold: a large title and a vertically scrolling stack of sections.
struct HubPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.largeTitle).bold()
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
