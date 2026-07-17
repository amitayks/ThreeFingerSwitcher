import Foundation

/// The video-backend SELECTOR (`ai-video-animation-generation`, design D1/D2) backing the persisted
/// `videoProvider` key (addendum §1). One seam (`MediaRuntime`), two interchangeable backends — this value
/// names WHICH conformer is wired, exactly as `aiSelectedModelID` names the chat model. The default is
/// `.cloud` (a hosted-API escalation), the honest calm default: no 35 GB download, no chat eviction, no
/// fans (design D2).
///
/// `.localLTXV` is the FRONTIER option — a ComfyUI/MPS 35 GB+ graph (NOT in-process MLX) — selectable ONLY
/// when the master `fullPotentialEnabled` AND `mediaGenEnabled` are both ON. This type carries the pure
/// validity rule (`isSelectable(...)`) so the gating is `swift test`-verified without the toggle page (the
/// flags are CONSUMED via injected booleans, owned by `ai-full-potential-toggle`). MLX-free Core.
public enum VideoProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The default: a hosted video API (LTX Studio / equivalent). Spends money + uploads bytes →
    /// `.dangerous` + budget-capped at the sink (design D3). Nothing is downloaded or made resident.
    case cloud
    /// The frontier: a local LTXV ComfyUI/MPS graph (35 GB+, minutes-per-clip, EVICTS chat). Behind the
    /// master toggle; spends no money so it is OFF the cloud budget path (design D6).
    case localLTXV

    public var id: String { rawValue }

    /// The honest default — the calm path (design D2). A user who never touched the setting gets cloud.
    public static let defaultProvider: VideoProvider = .cloud

    /// True iff this is the cloud escalation (→ `.dangerous` tier + budget + upload disclosure). The local
    /// provider is `false` (no spend, no upload).
    public var isCloud: Bool { self == .cloud }

    /// Whether THIS provider may be SELECTED given the master gates. `.cloud` is always a valid selection
    /// (it is the default, gated separately by `fleetCloudEscalationEnabled` at the contributor). `.localLTXV`
    /// requires BOTH `fullPotentialEnabled` AND `mediaGenEnabled` — the frontier is never reachable with the
    /// master off (design D2 / spec "Local LTXV requires the master toggle"). A sub-flag NEVER overrides the
    /// master OFF.
    public func isSelectable(fullPotentialEnabled: Bool, mediaGenEnabled: Bool) -> Bool {
        switch self {
        case .cloud:
            return true
        case .localLTXV:
            return fullPotentialEnabled && mediaGenEnabled
        }
    }

    /// Resolve a STORED raw value into an effective provider under the current master gates: an invalid
    /// `.localLTXV` (master off) falls back to the calm `.cloud` default rather than offering a frontier the
    /// gates forbid (defends a settings desync — the toggle flipped off while `.localLTXV` was persisted).
    public static func resolved(rawValue: String?,
                                fullPotentialEnabled: Bool,
                                mediaGenEnabled: Bool) -> VideoProvider {
        let stored = rawValue.flatMap(VideoProvider.init(rawValue:)) ?? .defaultProvider
        return stored.isSelectable(fullPotentialEnabled: fullPotentialEnabled, mediaGenEnabled: mediaGenEnabled)
            ? stored
            : .defaultProvider
    }
}
