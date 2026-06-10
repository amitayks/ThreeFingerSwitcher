import SwiftUI

/// The Hub landing page: every feature's master enable toggle at a glance, each row deep-linking to
/// that feature's detail page. Toggling here writes the same `AppSettings` property as the feature page.
struct OverviewPage: View {
    let context: HubContext
    @ObservedObject var nav: HubNavigation
    @ObservedObject private var settings: AppSettings

    init(context: HubContext, nav: HubNavigation) {
        self.context = context
        self.nav = nav
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    var body: some View {
        HubPage("Overview", subtitle: "Turn features on or off, then open one to configure it.") {
            HubSection {
                featureRow(.switcher, isOn: $settings.enabled,
                           subtitle: "Switch windows with a three-finger horizontal swipe.")
                Divider()
                featureRow(.spaces, isOn: $settings.manageVerticalGesture,
                           subtitle: "Switch Spaces by sliding up/down while the switcher is open.")
                Divider()
                featureRow(.launcher, isOn: $settings.enableLauncher,
                           subtitle: "Open a launcher of apps, scripts, and commands with four fingers.")
                Divider()
                featureRow(.clipboard, isOn: $settings.keepClipboardHistory,
                           subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.")
                Divider()
                featureRow(.ai, isOn: $settings.aiCommandsEnabled,
                           subtitle: "Run on-device AI commands on your selection, clipboard, or screen.")
            }
        }
    }

    private func featureRow(_ destination: HubDestination, isOn: Binding<Bool>, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: destination.systemImage)
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title).font(.body).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
            Button { nav.selection = destination } label: {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open \(destination.title)")
        }
        .contentShape(Rectangle())
    }
}
