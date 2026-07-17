import Foundation

/// The pure canvas RESOLVE model (design D7, §6.3) — the canonical two-finger compass over a finished
/// media preview. **DOWN (only when the canvas is at its top) extracts** the result (save / paste /
/// set-as); **RIGHT discards** the preview (the asset is already durably in the gallery, so a discard
/// never loses the file). A sub-threshold two-finger scroll does NOT resolve (reading the preview never
/// extracts or discards it) — the resolve excursion sits ABOVE incidental scroll, mirroring the AI
/// canvas's `canvasResolveThreshold`. Pure + `swift test`-verified; the native overlay drives it. MLX-free
/// Core.
public enum MediaCanvasResolution: Equatable, Sendable {
    /// DOWN-at-top past threshold → extract (save / paste / set-as).
    case extract
    /// RIGHT past threshold → discard the preview (file stays in the gallery).
    case discard
    /// Below threshold, or not at the top for a DOWN, or up (ignored) → no resolution.
    case none
}

/// What an extract DOES (the destinations the canonical "swipe-DOWN extracts" affords). The native
/// overlay turns the chosen destination into the concrete side effect (the file is already written).
public enum MediaExtractIntent: String, Equatable, Sendable {
    case save      // reveal / keep (it's already in the gallery — surface it)
    case paste     // paste into the front app
    case setAs     // set-as (wallpaper / etc.)
}

public enum MediaCanvasResolver {
    /// The resolve excursion threshold (normalized centroid travel) — ABOVE incidental two-finger scroll,
    /// matching the AI canvas's `canvasResolveThreshold` so reading the preview never resolves it.
    public static let resolveThreshold: Double = 0.22

    /// Resolve a two-finger excursion over a finished preview. `dx`/`dy` are signed normalized centroid
    /// travel (down = +y by the project's overlay convention); `atTop` is whether the canvas is scrolled
    /// to its top (a DOWN extract requires it, per the compass). Returns `.none` for a non-terminal job,
    /// a sub-threshold excursion, an up swipe, or a DOWN when not at the top.
    public static func resolve(dx: Double, dy: Double, atTop: Bool, state: MediaJobState) -> MediaCanvasResolution {
        // Only a TERMINAL preview resolves — a still-generating canvas is read-only.
        guard state.isTerminal else { return .none }
        let ax = abs(dx), ay = abs(dy)
        // Sub-threshold scroll never resolves (reading ≠ extracting/discarding).
        guard max(ax, ay) >= resolveThreshold else { return .none }
        // Horizontal-dominant RIGHT → discard. (LEFT is treated as discard too — any horizontal dismiss.)
        if ax >= ay {
            return dx > 0 ? .discard : .discard
        }
        // Vertical-dominant: DOWN extracts ONLY at the top; UP is ignored.
        if dy > 0 {
            return atTop ? .extract : .none
        }
        return .none   // up swipe → ignored
    }
}
