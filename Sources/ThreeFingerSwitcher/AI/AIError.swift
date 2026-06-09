import Foundation

/// The AI feature's SINGLE error→message translator (design D1). Every user-facing AI error surface —
/// the Settings model-status row, the overlay canvas, any alert — routes its message through here, so
/// the same underlying error yields the SAME concise headline everywhere (spec: "Single error taxonomy
/// and translator"). It also enforces the clean-message invariant: raw error text (`"\(error)"`,
/// `String(describing:)`, an OS error's `.localizedDescription`) is NEVER used as a headline — it rides
/// only on the opt-in `details` payload (and logs).
///
/// HOME (task 1.6): this lives in `ThreeFingerSwitcherCore`, alongside the shared `RuntimeError`
/// taxonomy. Core is visible to BOTH the `GemmaRuntime` (MLX) target and the app target, so both reach
/// it without a layering violation, and Core stays MLX-free (it references only Foundation `NSError`
/// and the app's own `RuntimeError`/`TaskError`). Vendor errors — e.g. `Gemma4DownloadError`, which is
/// only visible inside `GemmaRuntime` — are mapped into `RuntimeError` at the runtime boundary (design
/// D6, `GemmaMLXRuntime.prepare`) BEFORE they reach this translator, so `AIError` never needs to import
/// the vendor package.

/// A presentable error: a concise, user-facing `headline` plus optional, separately-carried `details`
/// (the raw technical text, for an opt-in "Show details / Copy" affordance and logs — never inline by
/// default). Carrying `details` apart from `headline` is what lets the UI bound the headline while
/// still exposing the full diagnostic on demand (design D4).
public struct AIPresentedError: Equatable, Sendable {
    /// The short, human-readable sentence shown by default on every surface.
    public let headline: String
    /// Raw technical detail for an opt-in disclosure / copy / log. `nil` when there is nothing more
    /// useful than the headline itself.
    public let details: String?

    public init(headline: String, details: String? = nil) {
        self.headline = headline
        self.details = details
    }
}

public enum AIError {

    /// The generic, safe headline for an error the translator does not recognize.
    public static let unknownHeadline = "Something went wrong."

    /// Translate ANY error into a clean `AIPresentedError`. Resolution order (spec / design D1):
    /// 1. The app's own `LocalizedError` taxonomy (`RuntimeError`, `TaskError`) → its `errorDescription`
    ///    as the headline (these are authored to be clean and per-case).
    /// 2. Cancellation (`CancellationError`) → a benign "Cancelled." headline (callers treat cancellation
    ///    as not-a-failure; the translator still returns a clean string for any surface that asks).
    /// 3. The vendor/OS classifier for a bare `NSError` (connectivity / HTTP status) → a taxonomy case.
    /// 4. The generic fallback headline.
    ///
    /// The raw `String(describing: error)` is ALWAYS stashed as `details` (so the full technical text is
    /// available on demand and in logs), except where the error carries a cleaner detail of its own
    /// (e.g. `RuntimeError.modelLoadFailed(detail:)`) — and it is NEVER used as the headline.
    public static func message(for error: Error) -> AIPresentedError {
        // 1) The app's own self-describing taxonomy. We match our OWN types explicitly (not any
        //    `LocalizedError`) so a vendor `LocalizedError` can't smuggle raw interpolation into a
        //    headline — vendor errors are mapped to `RuntimeError` at the boundary instead.
        if let runtime = error as? RuntimeError {
            return AIPresentedError(headline: runtime.errorDescription ?? unknownHeadline,
                                    details: details(for: runtime))
        }
        if let task = error as? TaskError {
            return AIPresentedError(headline: task.errorDescription ?? unknownHeadline,
                                    details: String(describing: task))
        }

        // 2) Cancellation is not a real failure — give a benign, clean headline if asked.
        if error is CancellationError {
            return AIPresentedError(headline: RuntimeError.cancelled.errorDescription ?? "Cancelled.",
                                    details: nil)
        }

        // 3) Vendor/OS classifier: map a bare NSError (connectivity, HTTP status) into the taxonomy and
        //    reuse that case's clean description. The raw NSError dump becomes the copyable details.
        let ns = error as NSError
        let rawDetails = String(describing: error)
        if let mapped = classify(ns) {
            return AIPresentedError(headline: mapped.errorDescription ?? unknownHeadline, details: rawDetails)
        }

        // 4) Unknown → safe generic headline; the raw text is opt-in details only, never the headline.
        return AIPresentedError(headline: unknownHeadline, details: rawDetails)
    }

    // MARK: - Vendor / OS classifier

    /// Classify a bare `NSError` into the shared taxonomy. Connectivity failures (URL-loading system)
    /// map to `.offline`; other URL-loading failures and 5xx map to `.serverUnavailable`; the
    /// auth/forbidden/not-found HTTP statuses map to `.authOrAccessDenied`. Returns `nil` when the
    /// error doesn't look like a recognized network/HTTP failure (→ generic fallback upstream).
    ///
    /// NOTE: in production the Gemma download library's errors are already mapped to `RuntimeError` at
    /// the runtime boundary, so this NSError path is mostly a safety net (and is what the unit tests
    /// pin over synthetic `NSError`s).
    static func classify(_ error: NSError) -> RuntimeError? {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet,   // -1009
                 NSURLErrorNetworkConnectionLost,     // -1005
                 NSURLErrorCannotConnectToHost,       // -1004
                 NSURLErrorCannotFindHost,            // -1003
                 NSURLErrorDNSLookupFailed,           // -1006
                 NSURLErrorTimedOut,                  // -1001
                 NSURLErrorDataNotAllowed,            // -1020
                 NSURLErrorInternationalRoamingOff:   // -1018
                return .offline
            default:
                return .serverUnavailable
            }
        }
        // An HTTP status carried as a plain NSError code (e.g. a mapped vendor/network error).
        return runtimeError(forHTTPStatus: error.code)
    }

    /// Map an HTTP status code to the taxonomy: 401/403/404 → access denied; any other 4xx/5xx →
    /// server-unavailable. Returns `nil` for non-HTTP codes. `public` and shared so a runtime boundary
    /// (e.g. `GemmaMLXRuntime`, which has the status in hand) classifies identically to this translator.
    public static func runtimeError(forHTTPStatus code: Int) -> RuntimeError? {
        switch code {
        case 401, 403, 404: return .authOrAccessDenied
        case 400..<600:     return .serverUnavailable
        default:            return nil
        }
    }

    // MARK: - Details derivation

    /// The copyable `details` for a `RuntimeError`: prefer a carried diagnostic (e.g.
    /// `modelLoadFailed(detail:)`) over the bare enum reflection; `nil` when the headline already says
    /// everything (no extra technical text to expose).
    private static func details(for runtime: RuntimeError) -> String? {
        switch runtime {
        case let .modelLoadFailed(detail):
            return detail
        case let .decodeFailed(detail):
            return detail
        case .offline, .serverUnavailable, .authOrAccessDenied, .modelMissing,
             .integrityFailed, .cancelled, .couldNotProduceValid, .unsupportedModality, .unavailable:
            return nil
        }
    }
}
