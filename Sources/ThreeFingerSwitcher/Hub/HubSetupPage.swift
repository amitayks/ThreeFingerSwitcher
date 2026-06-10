import SwiftUI

/// The Setup & Permissions page — the former Onboarding window, folded into the Hub. Reflects live
/// permission status with deep-links, and hosts the native-gesture opt-ins (each its own card with
/// the same enable/restore flows the coordinator drives).
struct SetupPage: View {
    let context: HubContext
    @ObservedObject private var permissions: PermissionsService
    @ObservedObject private var settings: AppSettings
    /// The native-gesture/restore state is read via plain closures over non-observable config objects
    /// (TrackpadGestureConfig etc.), so toggling this after an action forces the cards to re-read them.
    @State private var refresh = false

    init(context: HubContext) {
        self.context = context
        _permissions = ObservedObject(wrappedValue: context.permissions)
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    /// Run a gesture/restore action, then nudge `refresh` so the (non-observable) live-state cards re-read.
    private func act(_ action: () -> Void) { action(); refresh.toggle() }

    var body: some View {
        HubPage(HubDestination.setup.title,
                subtitle: "Grant the permissions below, then free the gestures you want to use.") {
            let _ = refresh   // re-evaluate the closure-driven cards after an action
            HubSection("Permissions") {
                permissionRow(title: "Accessibility (required)",
                              detail: "Enumerate and raise windows.",
                              status: permissions.accessibility,
                              action: permissions.requestAccessibility)
                Divider()
                permissionRow(title: "Screen Recording (required for thumbnails)",
                              detail: "Capture window thumbnails. Without it, cards show app icons only.",
                              status: permissions.screenRecording,
                              action: permissions.requestScreenRecording)
                Divider()
                permissionRow(title: "Input Monitoring (optional — usually not needed)",
                              detail: "The trackpad read does not require this. Safe to skip; the app may not appear in this list at all.",
                              status: permissions.inputMonitoring,
                              optional: true,
                              action: permissions.requestInputMonitoring)
                Divider()
                HStack {
                    Button("Refresh status", action: context.onRefreshPermissions)
                    Spacer()
                    if permissions.allRequiredGranted {
                        Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
            }

            HubSection("Native gesture") {
                if context.trackpadClaimed() {
                    Label("The horizontal three-finger swipe is currently used by macOS to switch full-screen apps.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Free the three-finger horizontal swipe…") { act(context.onSetupNativeGesture) }
                } else if context.trackpadNeedsRelogin() {
                    Label("Setting changed. Log out and back in (or restart) for it to fully take effect.", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Horizontal three-finger swipe is free. Mission Control / App Exposé still work on up/down.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if context.trackpadHasBackup() {
                    Button("Restore native gesture setting…") { act(context.onRestoreNativeGesture) }
                }
            }

            HubSection("Spaces") {
                if context.spacesAutoRearrangeOn() {
                    Label("macOS rearranges Spaces by most recent use, so the switcher's row order keeps shifting.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Keep Spaces in a fixed order…") { act(context.onKeepSpacesFixed) }
                } else {
                    Label("Spaces stay in a fixed order — the switcher's row order is stable.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HubSection("Space-row switching (optional)") {
                if !settings.manageVerticalGesture {
                    Label("Slide three fingers up/down while the switcher is open to switch Spaces. This moves Mission Control / App Exposé to four fingers.", systemImage: "arrow.up.arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Button("Enable Space-row switching…") { act(context.onEnableSpaceRowSwitching) }
                } else if context.spaceRowNeedsRelogin() {
                    Label("Enabled. Log out and back in (or restart) so macOS frees the three-finger up/down swipe.", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("Space-row switching is on. Mission Control / App Exposé are on four-finger up/down.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if context.verticalGestureHasBackup() {
                    Button("Restore Mission Control (three-finger up/down)…") { act(context.onRestoreMissionControl) }
                }
            }

            HubSection("Four-finger launcher (optional)") {
                if !settings.enableLauncher {
                    Label("Slide four fingers horizontally to open a launcher of your favorite apps, scripts, and presets. This frees the native four-finger swipe gestures (Mission Control / App Exposé stay on three-finger up/down).", systemImage: "square.grid.2x2")
                        .foregroundStyle(.secondary)
                    Button("Enable the four-finger launcher…") { act(context.onEnableLauncher) }
                } else if context.launcherNeedsRelogin() {
                    Label("Enabled. Log out and back in (or restart) so macOS frees the four-finger swipes.", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("The four-finger launcher is on. Open it by sliding four fingers horizontally.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if context.launcherHasBackup() {
                    Button("Disable launcher & restore four-finger swipes…") { act(context.onRestoreLauncher) }
                }
            }
        }
        .onAppear { context.onRefreshPermissions() }
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, status: PermissionsService.Status,
                              optional: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            if optional && status != .granted {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            } else {
                statusIcon(status)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status != .granted {
                Button(optional ? "Open Settings" : "Grant", action: action)
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: PermissionsService.Status) -> some View {
        switch status {
        case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .unknown: Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
        }
    }
}
