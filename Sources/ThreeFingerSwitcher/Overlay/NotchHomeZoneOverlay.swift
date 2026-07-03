import AppKit
import SwiftUI
import Combine

/// The solved content-fit size of the notch rail (design D5), mirroring `SwitcherGridLayout`: the rail
/// HUGS its actual sessions in width AND height like `SwitcherLayout.solveGrid` + `OverlayController.layout`
/// — width = chrome + summed card widths + inter-card spacing (clamped to a fraction of the visible
/// frame), height fitted (clamped to a fraction, overflowing → scroll). Both the view (which renders)
/// and the controller (which sizes the panel) read THIS one result so the rendered rail and the panel
/// frame cannot drift.
struct NotchRailLayout: Equatable {
    /// The hugged content size (the panel frame), already clamped to the available screen fraction.
    let contentSize: CGSize
    /// True when the natural width exceeds the clamp (the row scrolls horizontally).
    let overflowsHorizontally: Bool
    /// True when the natural height exceeds the clamp (the row scrolls vertically — many tall cards).
    let overflowsVertically: Bool

    static let zero = NotchRailLayout(contentSize: .zero,
                                      overflowsHorizontally: false,
                                      overflowsVertically: false)
}

/// Layout metrics + the content-fit solve for the notch home-zone rail. The rail is a horizontally
/// scrollable row of parked cards that EMERGES FROM the notch and hugs its sessions (no hardcoded width).
enum NotchHomeZoneLayout {
    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 92
    static let cardSpacing: CGFloat = 12
    static let padding: CGFloat = 14
    /// The resting zone (the reveal target + the ambient-glow host) — a slim top-center tab.
    static let zoneWidth: CGFloat = 120
    static let zoneHeight: CGFloat = 10

    /// Fraction of the active screen's visible frame the rail may occupy before it scrolls (the
    /// `SwitcherLayout.canvasWidthFraction`/`canvasHeightFraction` idiom).
    static let maxWidthFraction: CGFloat = 0.86
    static let maxHeightFraction: CGFloat = 0.60

    static var railHeight: CGFloat { padding * 2 + cardHeight }

    /// Rail width for `count` cards, clamped to the available screen width (scrolls when it overflows).
    /// Retained as the width primitive `solve` builds on; a single card hugs to a one-card floor.
    static func railWidth(count: Int, maxWidth: CGFloat) -> CGFloat {
        return min(max(naturalWidth(count: count), oneCardWidth), maxWidth)
    }

    /// The un-clamped natural width for `count` cards (chrome + cards + inter-card spacing).
    static func naturalWidth(count: Int) -> CGFloat {
        let n = max(count, 0)
        guard n > 0 else { return oneCardWidth }
        return padding * 2 + cardWidth * CGFloat(n) + cardSpacing * CGFloat(max(n - 1, 0))
    }

    /// The one-card floor — a single (or empty) rail hugs to exactly one card plus chrome.
    static var oneCardWidth: CGFloat { padding * 2 + cardWidth }

    /// Solve the content-fit size for `count` parked cards within `visibleFrame` (design D5): width hugs
    /// the cards (chrome + sum + spacing), clamped to `maxWidthFraction` of the visible width with a
    /// one-card floor (overflow → horizontal scroll); height is a single band (`railHeight`), clamped to
    /// `maxHeightFraction` of the visible height (overflow → vertical scroll). Mirrors
    /// `SwitcherLayout.solveGrid`'s contentSize + overflow-flag contract.
    static func solve(count: Int, visibleFrame: CGRect) -> NotchRailLayout {
        let maxW = visibleFrame.width > 1 ? visibleFrame.width * maxWidthFraction : naturalWidth(count: count)
        let maxH = visibleFrame.height > 1 ? visibleFrame.height * maxHeightFraction : railHeight

        let natural = naturalWidth(count: count)
        let width = min(max(natural, oneCardWidth), maxW)
        let height = min(railHeight, maxH)

        return NotchRailLayout(
            contentSize: CGSize(width: width, height: height),
            overflowsHorizontally: natural > maxW + 0.5,
            overflowsVertically: railHeight > maxH + 0.5)
    }
}

/// How the panel attaches to the display top: `.notch` merges into a physical notch (the NotchNook look —
/// the opaque-black panel top reaches the physical top and spans behind the black notch, no carving), `.tab`
/// is the honest top-center rounded pill on a notchless/external display. Carries the notch cutout size
/// (panel-local points); its height is the notch-band headroom the view keeps the centered content clear of.
enum NotchAttachment: Equatable {
    case notch(cutout: CGSize)
    case tab
}

/// The observable rail state (the AppKit/SwiftUI seam). The pure scheduler/store own the data; this is
/// the view-model the overlay renders. `@MainActor` — UI state.
@MainActor
final class NotchHomeZoneViewModel: ObservableObject {
    @Published var sessions: [ParkedSession] = []
    /// The current attachment mode + notch cutout (set by the controller before each reveal/reposition).
    /// Defaults to `.tab` so the view is well-defined before the first geometry solve.
    @Published var attachment: NotchAttachment = .tab
    /// Drives the smooth ease-in-out **spread**: `false` collapses the panel toward the notch (a tiny seed
    /// at the top-center), `true` spreads it out to full size. The controller flips it inside `withAnimation`
    /// on reveal (→ true) and animated hide (→ false), so the panel grows out of / recedes into the notch.
    @Published var isExpanded: Bool = false
    /// True iff at least one parked session is in `.needsYou` — drives the ambient glow.
    var hasNeedsYou: Bool { sessions.contains { $0.state == .needsYou } }
}

/// Owns the **mouse-interactive, non-activating** notch home-zone panel — the `DockPreviewOverlayController`
/// recipe (design §5/§8): `[.borderless, .nonactivatingPanel]`, `ignoresMouseEvents = false`,
/// `acceptsMouseMovedEvents = true`, `level = .popUpMenu`, `.canJoinAllSpaces`, NEVER key/main (so it
/// never steals focus from the foreground app — the restore target). Teardown is **synchronous**
/// (`orderOut`) — the ghost-on-Space-switch landmine applies here exactly as in the Files band + Dock
/// preview. `show(at:)` orders front (reveal); `move(to:)` repositions only (never re-fronts, so the
/// ambient glow / any layer above is never stomped); `hide()` orders out synchronously.
@MainActor
final class NotchHomeZoneOverlayController {
    let model = NotchHomeZoneViewModel()
    private var panel: SwitcherPanel?

    /// A card was pulled back (clicked / dragged down) — restore that session as the active canvas.
    var onRestore: ((AgentSessionID) -> Void)?
    /// A card was discarded.
    var onDiscard: ((AgentSessionID) -> Void)?

    private func makePanel() -> SwitcherPanel {
        // The initial content rect is the one-card floor; the controller's content-fit solve resizes it to
        // hug the actual sessions on `show(at:)`/`move(to:)` (no hardcoded width — the placement-bug fix).
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: NotchHomeZoneLayout.oneCardWidth,
                                height: NotchHomeZoneLayout.railHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The rail takes the pointer (click/drag a card to restore) — like the Dock preview, the lone
        // mouse-interactive overlay species. Still non-activating + never key/main → no focus steal.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        // Attached mode positions the panel's TOP at the physical top of the display (over the menu bar) so
        // its black merges with the notch — skip AppKit's constrain-below-the-menu-bar so the frame sticks.
        panel.reachesPhysicalTop = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchHomeZoneRailView(
            model: model,
            onRestore: { [weak self] id in self?.onRestore?(id) },
            onDiscard: { [weak self] id in self?.onDiscard?(id) }
        ))
        return panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    /// The ease-in-out spread duration (reveal grow / animated-hide recede), shared by both directions.
    static let spreadDuration: TimeInterval = 0.3
    /// A scheduled animated-hide teardown, cancelled if a fresh reveal arrives mid-recede.
    private var pendingHide: DispatchWorkItem?
    /// True while an animated recede is in flight (its `orderOut` is scheduled but not yet run) — the
    /// controller reads this to pause its re-feed timer so it doesn't re-trigger the recede every tick.
    var isReceding: Bool { pendingHide != nil }

    /// Reveal or reposition the rail at `rect` and spread it OUT of the notch (ease-in-out). Handles the
    /// first show (orders front) and per-tick reanchor (repositions only — never re-fronts a visible panel,
    /// so a layer above like a menu is never stomped, matching the Dock-preview `move(to:)` discipline). A
    /// reveal arriving during an animated recede cancels the pending teardown and re-spreads.
    func reveal(at rect: CGRect) {
        pendingHide?.cancel(); pendingHide = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // The window (the "outer container") casts NO shadow in attached mode — a window drop-shadow at the
        // top would read as a border where the panel merges into the notch/menu bar. Tab mode keeps it.
        let attached: Bool = { if case .notch = model.attachment { return true }; return false }()
        if panel.hasShadow != !attached {
            panel.hasShadow = !attached
            panel.invalidateShadow()
        }
        let wasVisible = panel.isVisible
        panel.setFrame(rect, display: true)
        if !wasVisible { panel.orderFrontRegardless() }
        if !model.isExpanded {
            withAnimation(.easeInOut(duration: Self.spreadDuration)) { model.isExpanded = true }
        }
    }

    /// Tear down the rail. `animated` recedes it back INTO the notch (ease-in-out) then orders out on
    /// completion — used for the gentle grace-dismiss. `animated == false` is the **synchronous** `orderOut`
    /// (the ghost-on-Space-switch landmine) — used for restore/disable where the teardown must be immediate.
    func hide(animated: Bool) {
        guard let panel else { return }
        guard animated else {
            pendingHide?.cancel(); pendingHide = nil
            model.isExpanded = false
            panel.orderOut(nil)                    // synchronous — ghost-on-Space-switch landmine
            return
        }
        if pendingHide != nil { return }           // already receding — don't restart the animation
        withAnimation(.easeInOut(duration: Self.spreadDuration)) { model.isExpanded = false }
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.pendingHide = nil
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spreadDuration, execute: work)
    }
}

/// The rail: a horizontally-scrollable row of parked cards. In attached mode it's a **plain black rounded
/// rectangle** whose top edge reaches the physical top so its black simply spans up **behind** the (also
/// black) notch — no cutout is carved, because both are black and read as one shape. The whole container
/// spreads out of / recedes into the notch on the controller's ease-in-out `isExpanded` transition. The
/// cards are **centered** (both axes) in the panel — horizontally so a few sessions don't hug the left, and
/// vertically so they sit clear of the notch. A bounded `failed` badge carries the clean headline ONLY (raw
/// text lives behind an opt-in disclosure on the restored canvas, never here).
struct NotchHomeZoneRailView: View {
    @ObservedObject var model: NotchHomeZoneViewModel
    let onRestore: (AgentSessionID) -> Void
    let onDiscard: (AgentSessionID) -> Void

    private var isAttached: Bool {
        if case .notch = model.attachment { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NotchHomeZoneLayout.cardSpacing) {
                    ForEach(model.sessions) { session in
                        NotchParkedCard(session: session,
                                        onRestore: { onRestore(session.id) },
                                        onDiscard: { onDiscard(session.id) })
                    }
                }
                .padding(.horizontal, NotchHomeZoneLayout.padding)
                // Center the cards across the whole panel (both axes): `minWidth` centers a few sessions
                // instead of left-hugging them yet still allows horizontal scroll when they overflow;
                // `minHeight` centers the row vertically so it sits clear of the notch that overlaps the top.
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .center)
            }
        }
        .background(chromeFill)
        .overlay(chromeStroke)
        .clipShape(chromeShape)
        // The smooth ease-in-out SPREAD: the whole panel grows out of / recedes into the notch, anchored at
        // its TOP edge, so it unfurls downward AND out to both sides. The controller flips `isExpanded`
        // inside `withAnimation(.easeInOut)`, which drives this transition.
        .scaleEffect(model.isExpanded ? 1 : Self.seedScale, anchor: .top)
        .opacity(model.isExpanded ? 1 : 0)
    }

    /// The collapsed seed scale — small enough to read as emerging from the notch, non-zero so the anchor
    /// stays well-defined during the spread (a literal `0` collapses the frame and the anchor with it).
    private static let seedScale: CGFloat = 0.06

    /// The chrome silhouette. Attached mode is a plain rounded rectangle with a **flat top** (square top
    /// corners so it grows cleanly from the physical top / behind the notch) and rounded bottom corners; the
    /// tab-degradation path is a fully-rounded pill. No notch is carved — the black spans behind the notch.
    private var chromeShape: AnyShape {
        if isAttached {
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 20,
                bottomTrailingRadius: 20, topTrailingRadius: 0))
        }
        return AnyShape(RoundedRectangle(cornerRadius: 18))
    }

    /// In attached mode the fill is opaque black so it reads as one shape with the hardware notch's black
    /// pixels (a translucent material would reveal a seam); in tab mode it stays the app's `.regularMaterial`.
    @ViewBuilder private var chromeFill: some View {
        if isAttached {
            chromeShape.fill(Color.black)
        } else {
            chromeShape.fill(.regularMaterial)
        }
    }

    /// The hairline border. In attached mode it traces only the **sides and bottom** — never the top edge —
    /// so there is no line where the panel merges into the notch / menu bar at the physical top; the tab
    /// path keeps a full rounded-rect border.
    @ViewBuilder private var chromeStroke: some View {
        if isAttached {
            NotchPanelBorderShape().stroke(.white.opacity(0.08), lineWidth: 1)
        } else {
            chromeShape.stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

/// An OPEN border tracing the attached panel's left side, rounded bottom, and right side — but NOT the top
/// edge — so the merged panel shows no hairline at the physical top where it meets the notch/menu bar.
private struct NotchPanelBorderShape: Shape {
    var bottomRadius: CGFloat = 20
    func path(in rect: CGRect) -> Path {
        let W = rect.width, H = rect.height
        let r = min(bottomRadius, min(W, H) / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))                                  // top-left (top edge NOT drawn)
        p.addLine(to: CGPoint(x: 0, y: H - r))
        p.addQuadCurve(to: CGPoint(x: r, y: H), control: CGPoint(x: 0, y: H))
        p.addLine(to: CGPoint(x: W - r, y: H))
        p.addQuadCurve(to: CGPoint(x: W, y: H - r), control: CGPoint(x: W, y: H))
        p.addLine(to: CGPoint(x: W, y: 0))                              // up to top-right, then stop
        return p
    }
}

/// One parked-session card: a title + a state badge. Clicking it pulls it back (restore).
struct NotchParkedCard: View {
    let session: ParkedSession
    let onRestore: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Button(action: onRestore) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title.isEmpty ? "Session" : session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                ParkStateBadge(state: session.state, badgeCount: session.badgeCount)
                Spacer(minLength: 0)
            }
            .frame(width: NotchHomeZoneLayout.cardWidth,
                   height: NotchHomeZoneLayout.cardHeight, alignment: .topLeading)
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(session.state == .needsYou ? Color.accentColor : .white.opacity(0.10),
                              lineWidth: session.state == .needsYou ? 2 : 1))
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Discard", role: .destructive, action: onDiscard) }
    }
}

/// The per-card state badge — thinking / done-count / needs-you accent / failed-with-clean-headline.
struct ParkStateBadge: View {
    let state: ParkState
    let badgeCount: Int

    var body: some View {
        switch state {
        case .parked:
            label("Thinking…", system: "ellipsis", tint: .secondary)
        case .idle where badgeCount > 0, .active where badgeCount > 0:
            label("\(badgeCount) new", system: "checkmark.circle.fill", tint: .green)
        case .idle, .active:
            label("Parked", system: "moon.zzz", tint: .secondary)
        case .needsYou:
            label("Needs you", system: "exclamationmark.circle.fill", tint: .accentColor)
        case .completed:
            // Terminal — auto-dismissed forever on the next pass, so this is a brief transient render.
            label("Done", system: "checkmark.circle.fill", tint: .green)
        }
    }

    private func label(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// The ambient needs-you glow on the resting zone — a soft, slow pulse present IFF any session is
/// `.needsYou` (the controller toggles `isActive`). Reuses `PulseHalo`/`BreathingGlowBackdrop`
/// (`WizardMotion`) so it reads as the same app. Never modal, never a sound, never re-fronts the panel;
/// `allowsHitTesting(false)` keeps it ambient. Hosted in its own slim non-activating panel by the
/// controller so it can sit on the resting zone independent of the rail's reveal.
struct NotchAmbientGlow: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                BreathingGlowBackdrop(color: .accentColor)
                PulseHalo(color: .accentColor, size: 80, intensity: 0.9)
            }
        }
        .frame(width: NotchHomeZoneLayout.zoneWidth, height: NotchHomeZoneLayout.zoneHeight + 60)
        .allowsHitTesting(false)
    }
}
