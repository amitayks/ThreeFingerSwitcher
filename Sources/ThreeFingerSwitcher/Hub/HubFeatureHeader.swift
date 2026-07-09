import SwiftUI

/// A gesture-driven feature page's leading block: a live `HubGesturePreview` and, **directly beneath
/// it**, a switch-style master-enable row matching the Overview "home page" toggle
/// (`OverviewPage.featureRow` — icon + title + subtitle + a `.switch` toggle). This is the
/// "below the preview, a toggle like the home page" composition the configuration-hub spec asks for;
/// the master enable writes the same persisted preference as the prior `ToggleRow` / Overview switch.
///
/// The header is reusable across the gesture pages (Switcher / Launcher / Clipboard / Files / AI): each
/// supplies its preview's miniature plus the icon / title / subtitle / `isOn` binding. The secondary
/// controls a page keeps below the header (sliders, pickers, buttons) are untouched by this type.
struct HubFeatureHeader<Miniature: View>: View {
    /// The preview surface shown first — pass a fully configured `HubGesturePreview`.
    var preview: HubGesturePreview<Miniature>
    /// The master-toggle row's leading SF Symbol (mirrors the Overview row's `destination.systemImage`).
    var icon: String
    /// The feature's title (the Overview row's `destination.title`).
    var title: String
    /// The one-line subtitle beneath the title (the Overview row's `subtitle`).
    var subtitle: String
    /// The feature's master enable — the same persisted `AppSettings` preference as before.
    @Binding var isOn: Bool

    init(
        preview: HubGesturePreview<Miniature>,
        icon: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) {
        self.preview = preview
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        VStack(spacing: 16) {
            preview
            masterToggleRow
        }
    }

    /// The Overview `featureRow` look, scoped to the master enable: icon + title + subtitle + `.switch`.
    private var masterToggleRow: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
        .contentShape(Rectangle())
    }
}

#if DEBUG
private struct HubFeatureHeaderPreviewHost: View {
    @State private var on = true
    var body: some View {
        HubFeatureHeader(
            preview: HubGesturePreview(gesture: GesturePose.switcherDemo()) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(height: 120)
                    .overlay(Text("miniature").foregroundStyle(.secondary))
            },
            icon: "rectangle.on.rectangle",
            title: "Window Switcher",
            subtitle: "Switch windows with three fingers; switch Spaces by sliding up/down.",
            isOn: $on
        )
        .environmentObject(HubPreviewActivity())
        .frame(width: 360)
        .padding()
    }
}

#Preview("HubFeatureHeader") { HubFeatureHeaderPreviewHost() }
#endif
