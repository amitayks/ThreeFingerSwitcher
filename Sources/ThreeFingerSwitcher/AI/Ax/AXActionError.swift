import Foundation

/// The computer-use tool layer's error taxonomy (`add-voice-computer-use-agent`, spec "Computer-use
/// failures join the single error taxonomy"). Parallel to `FileActionError`: a Core `LocalizedError`
/// with clean per-case headlines, populated at the `AXUIElement` boundary. Raw AX/OS error text rides
/// ONLY in `copyableDetails`; surfaces are bounded + non-blocking; `AIError.message(for:)` translates.
public enum AXActionError: Error, Equatable {
    /// The Accessibility grant is missing or was revoked mid-session.
    case notPermitted
    /// The target app's AX server didn't answer in time (beach-balling app). The step timeout also
    /// covers this; the boundary maps an explicit AX timeout here so the headline is honest.
    case appNotResponding(appName: String)
    /// The target window disappeared between snapshot and act.
    case windowGone
    /// The element ID doesn't resolve against the CURRENT snapshot epoch — the window changed since
    /// the last read. The loop's recovery is a fresh `read_window` (constrained-ID rule: an act can
    /// only target what currently exists; a stale target NEVER degrades to a guess).
    case staleElement
    /// The element exists but does not support the requested action (not pressable / not settable).
    case elementNotActionable(role: String)
    /// The act was posted but the re-read could not observe the expected change (verify-after-act):
    /// an unverified side effect is a failure, never a false "Done".
    case verifyFailed(expectation: String)
    /// The window exposes no usable accessibility content (an AX desert — Electron/canvas surfaces).
    case unreadableWindow(appName: String)
    /// Raw diagnostic for the opt-in disclosure, populated at the boundary where available.
    public var copyableDetails: String? {
        switch self {
        case let .verifyFailed(expectation): return "Expected: \(expectation)"
        case let .appNotResponding(app):     return "AX request to \(app) timed out"
        case .notPermitted, .windowGone, .staleElement, .elementNotActionable, .unreadableWindow:
            return nil
        }
    }
}

extension AXActionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notPermitted:
            return "Accessibility access is off. Allow it in System Settings so the assistant can read and act on windows."
        case let .appNotResponding(appName):
            return "\(appName) isn't responding."
        case .windowGone:
            return "That window is gone."
        case .staleElement:
            return "The window changed — it needs to be read again."
        case let .elementNotActionable(role):
            return "That element (\(role)) can't be acted on."
        case .verifyFailed:
            return "The action didn't take effect."
        case let .unreadableWindow(appName):
            return "Can't read this \(appName) window."
        }
    }
}
