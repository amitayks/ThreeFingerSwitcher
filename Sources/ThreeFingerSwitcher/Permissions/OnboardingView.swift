import SwiftUI

/// Onboarding / permissions window. Reflects live permission status and offers to grant each
/// one, plus the native-gesture setup that frees the horizontal three-finger swipe.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsService
    let trackpadClaimed: Bool
    let trackpadNeedsRelogin: Bool
    let spacesAutoRearrangeOn: Bool
    let onSetupNativeGesture: () -> Void
    let onKeepSpacesFixed: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Three-Finger Window Switcher")
                .font(.title2).bold()
            Text("Slide three fingers left/right to switch windows. Grant the permissions below, then free the horizontal three-finger gesture.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Permissions") {
                VStack(spacing: 12) {
                    permissionRow(
                        title: "Accessibility (required)",
                        detail: "Enumerate and raise windows.",
                        status: permissions.accessibility,
                        action: permissions.requestAccessibility
                    )
                    Divider()
                    permissionRow(
                        title: "Screen Recording (required for thumbnails)",
                        detail: "Capture window thumbnails. Without it, cards show app icons only.",
                        status: permissions.screenRecording,
                        action: permissions.requestScreenRecording
                    )
                    Divider()
                    permissionRow(
                        title: "Input Monitoring (optional — usually not needed)",
                        detail: "The trackpad read does not require this. Safe to skip; the app may not appear in this list at all.",
                        status: permissions.inputMonitoring,
                        optional: true,
                        action: permissions.requestInputMonitoring
                    )
                }
                .padding(6)
            }

            GroupBox("Native gesture") {
                VStack(alignment: .leading, spacing: 8) {
                    if trackpadClaimed {
                        Label("The horizontal three-finger swipe is currently used by macOS to switch full-screen apps.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Free the three-finger horizontal swipe…", action: onSetupNativeGesture)
                    } else if trackpadNeedsRelogin {
                        Label("Setting changed. Log out and back in (or restart) for it to fully take effect.", systemImage: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Horizontal three-finger swipe is free. Mission Control / App Exposé still work on up/down.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Spaces") {
                VStack(alignment: .leading, spacing: 8) {
                    if spacesAutoRearrangeOn {
                        Label("macOS rearranges Spaces by most recent use, so the switcher's row order keeps shifting.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Keep Spaces in a fixed order…", action: onKeepSpacesFixed)
                    } else {
                        Label("Spaces stay in a fixed order — the switcher's row order is stable.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Button("Refresh status", action: onRefresh)
                Spacer()
                if permissions.allRequiredGranted {
                    Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, status: PermissionsService.Status, optional: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            if optional && status != .granted {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            } else {
                statusIcon(status)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
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
