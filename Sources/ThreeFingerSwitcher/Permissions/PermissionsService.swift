import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Combine

/// Detects and helps the user grant the permissions the app needs. Accessibility and Screen
/// Recording are required; Input Monitoring is best-effort (spike 1.3 saw no prompt for the
/// multitouch read, but we still surface it if the OS ever requires it).
@MainActor
final class PermissionsService: ObservableObject {
    enum Status { case granted, denied, unknown }

    @Published var accessibility: Status = .unknown
    @Published var screenRecording: Status = .unknown
    @Published var inputMonitoring: Status = .unknown

    func refresh() {
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
        inputMonitoring = mapHID(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
    }

    var allRequiredGranted: Bool {
        accessibility == .granted && screenRecording == .granted
    }

    // MARK: - Requests

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings(.accessibility)
    }

    func requestScreenRecording() {
        // Triggers the system prompt the first time; afterwards deep-link to Settings.
        _ = CGRequestScreenCaptureAccess()
        openSettings(.screenRecording)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openSettings(.inputMonitoring)
    }

    // MARK: - Deep links

    enum Pane {
        case accessibility, screenRecording, inputMonitoring

        var urlString: String {
            switch self {
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .screenRecording:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .inputMonitoring:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }

    func openSettings(_ pane: Pane) {
        if let url = URL(string: pane.urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func mapHID(_ access: IOHIDAccessType) -> Status {
        switch access {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }
}
