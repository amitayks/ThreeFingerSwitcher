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
            if context.relocationsPendingRelogin() {
                reloginBanner
            }
            HubSection {
                featureRow(.switcher, isOn: $settings.enabled,
                           subtitle: "Switch windows with three fingers; switch Spaces by sliding up/down.")
                Divider()
                featureRow(.launcher, isOn: $settings.enableLauncher,
                           subtitle: "Open a launcher of apps, scripts, and commands with four fingers.")
                Divider()
                featureRow(.clipboard, isOn: $settings.keepClipboardHistory,
                           subtitle: "Keep a history of what you copy, in the launcher's Clipboard band.")
                Divider()
                featureRow(.files, isOn: $settings.filesBandEnabled,
                           subtitle: "Pilot your local folders, preview, and open files — a Files band in the launcher.")
                Divider()
                featureRow(.ai, isOn: $settings.aiCommandsEnabled,
                           subtitle: "Run on-device AI commands on your selection, clipboard, or screen.")
                Divider()
                featureRow(.keyboardLanguage, isOn: $settings.keyboardLanguageEnabled,
                           subtitle: "Remember and auto-switch the keyboard language per app.")
            }
        }
    }

    /// The one-re-login banner: a gesture relocation has been applied but macOS hands the lanes
    /// over only at the next login — the same honest state the wizard's re-login act and the
    /// overlay's dimmed row dots show, surfaced where every feature toggle lives.
    private var reloginBanner: some View {
        HubSection {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("One log-out finishes your gesture setup")
                        .font(.body).fontWeight(.medium)
                    Text("macOS hands trackpad gestures over at login — the claimed lanes go live the next time you log in. Log Out sends the standard ⇧⌘Q; macOS asks to confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Log Out Now…") { context.onLogOutNow() }
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
