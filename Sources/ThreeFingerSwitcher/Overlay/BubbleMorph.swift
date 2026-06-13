import SwiftUI

/// The app's **first spring** — a near-zero droplet that buds up into presence. A `ViewModifier`
/// (applied via `View.bubbleMorph(anchor:)`) that animates a view *in* by interpolating
/// `scaleEffect(0.02 → 1, anchor:)` + `opacity(0 → 1)` on a single `spring(response: 0.34,
/// dampingFraction: 0.72)`, flipped on `.onAppear`. It is the Files band's depth/preview/row entrance
/// motion and is deliberately confined to **containers / rows / preview / menus, never leaf glyphs**.
///
/// It intentionally does **not** touch the existing motion vocabulary: the selection highlight keeps
/// its linear charge ramp (`.linear(dwell)`) and its `.easeOut` arm snap, and there are **no new
/// haptics** — the `.alignment` arm tick stays the only one (design D8). For SwiftUI membership
/// insert/remove (e.g. a depth `.id`-swap, where there's no stable view to drive `.onAppear` across the
/// change), use the matching ``bubbleTransition(anchor:)`` so the same droplet shape governs both the
/// budding-in *and* the receding-out side.
struct BubbleMorph: ViewModifier {
    /// The point the droplet buds from — `.center` by default; columns may bud from their attachment
    /// edge (`.leading` / `.trailing`) so the morph reads as growing *out of* the rail.
    var anchor: UnitPoint = .center

    /// The bud spring, shared with ``bubbleTransition(anchor:)`` so a modifier-driven entrance and a
    /// transition-driven one settle on the same clock.
    static let spring: Animation = .spring(response: 0.34, dampingFraction: 0.72)

    /// The droplet's starting scale — small enough to read as a bud, non-zero so the anchor stays
    /// well-defined (a literal `0` collapses the frame and the anchor with it).
    static let seedScale: CGFloat = 0.02

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : Self.seedScale, anchor: anchor)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(Self.spring) { shown = true }
            }
    }
}

extension View {
    /// Bud this view up into presence on appear (see ``BubbleMorph``). Use on **containers / rows /
    /// preview / menus, never leaf glyphs**, and never on the single sliding selection highlight
    /// (per-row morphs reintroduce the documented scrub strobe — design D8).
    func bubbleMorph(anchor: UnitPoint = .center) -> some View {
        modifier(BubbleMorph(anchor: anchor))
    }
}

extension AnyTransition {
    /// The membership-insert/remove counterpart to ``BubbleMorph``: the same `0.02 → 1` droplet scale
    /// combined with opacity, for views that come and go inside a `ForEach` / `.id`-keyed swap (where
    /// there's no persistent view to carry `.onAppear` across the change). Pair it with
    /// `.animation(BubbleMorph.spring, value:)` (or wrap the mutation in `withAnimation(BubbleMorph
    /// .spring)`) so insert and remove ride the bud spring — matching the `SwitcherView` `.id`/
    /// `.transition` idiom, but **scaling, not sliding**.
    static func bubbleMorph(anchor: UnitPoint = .center) -> AnyTransition {
        .scale(scale: BubbleMorph.seedScale, anchor: anchor)
            .combined(with: .opacity)
    }
}
