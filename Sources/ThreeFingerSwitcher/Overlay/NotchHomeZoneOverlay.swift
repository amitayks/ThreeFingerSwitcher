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

/// Layout metrics + the content-fit solve for the notch home-zone rail. The rail is a NON-scrollable row
/// of parked cards that EMERGES FROM the notch and HUGS its sessions (no hardcoded width) — it EXPANDS as
/// cards are added rather than scrolling. The `overflows*` flags remain as safety signals (a pathological
/// count beyond the parked-session cap) but no longer drive a scroll view.
enum NotchHomeZoneLayout {
    static let cardWidth: CGFloat = 168
    static let cardHeight: CGFloat = 92
    static let cardSpacing: CGFloat = 12
    /// Horizontal chrome padding (each side of the card row).
    static let padding: CGFloat = 14
    /// The card row is **centered** in the panel with **symmetric** vertical padding. On a notched display
    /// that padding is the **notch height + a little** (`railNotchClearance`) on BOTH the top and the bottom
    /// — so the row clears the notch by a small gap and sits balanced (never shoved to the bottom). Because
    /// it depends on the runtime notch height, the attached panel height is computed by the controller
    /// (which knows the cutout); this constant is only the "a little". On a notchless/external display there
    /// is no notch to clear, so a fixed comfortable vertical padding (`railTabVerticalPadding`) is used.
    static let railNotchClearance: CGFloat = 8
    static let railTabVerticalPadding: CGFloat = 16

    /// The in-place EXPANDED conversation panel's content-fit solve (`notch-native-conversations` D4):
    /// a fixed comfortable reading size clamped to fractions of the visible frame (small screens stay
    /// sane; content scrolls inside). Same anchor functions as the rail — only the content size differs.
    static func solveExpanded(visibleFrame: CGRect) -> CGSize {
        let maxW = visibleFrame.width > 1 ? visibleFrame.width * 0.46 : expandedWidth
        let maxH = visibleFrame.height > 1 ? visibleFrame.height * 0.62 : expandedHeight
        return CGSize(width: min(expandedWidth, maxW), height: min(expandedHeight, maxH))
    }
    static let expandedWidth: CGFloat = 560
    static let expandedHeight: CGFloat = 520
    /// The resting zone (the reveal target + the ambient-glow host) — a slim top-center tab.
    static let zoneWidth: CGFloat = 120
    static let zoneHeight: CGFloat = 10

    /// Fraction of the active screen's visible frame the rail may occupy before it scrolls (the
    /// `SwitcherLayout.canvasWidthFraction`/`canvasHeightFraction` idiom).
    static let maxWidthFraction: CGFloat = 0.86
    static let maxHeightFraction: CGFloat = 0.60

    /// The tab-mode (notchless) rail content height: the card row centered with `railTabVerticalPadding`
    /// on top and bottom. The attached (notched) height is computed per-notch via `attachedRailContentHeight`.
    static var railHeight: CGFloat { cardHeight + 2 * railTabVerticalPadding }

    /// The below-notch content height to hand `attachedPanelRect` so the card row ends up **centered** in the
    /// merged panel with `notchHeight + railNotchClearance` padding on the top and bottom. `attachedPanelRect`
    /// re-adds the notch band on top of this, so it is `card + notch + 2*clearance` — making the total panel
    /// `card + 2*(notch + clearance)`, which centered yields the symmetric notch-clearing padding.
    static func attachedRailContentHeight(notchHeight: CGFloat) -> CGFloat {
        cardHeight + notchHeight + 2 * railNotchClearance
    }

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
    /// the cards (chrome + sum + spacing) so the dock EXPANDS per card, clamped to `maxWidthFraction` of the
    /// visible width with a one-card floor (a safety ceiling for the pathological beyond-cap case — the dock
    /// is non-scrollable, so past the ceiling it clips rather than scrolls); height is a single band
    /// (`railHeight`), clamped to `maxHeightFraction` of the visible height. Mirrors `SwitcherLayout.solveGrid`'s
    /// contentSize + overflow-flag contract (the `overflows*` flags are retained as signals only).
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
    /// What the panel is showing (`notch-native-conversations` D4): the card RAIL, or ONE session
    /// EXPANDED in place into its conversation view. The same panel and chrome serve both — never a
    /// second panel.
    enum Mode: Equatable {
        case rail
        case expanded(AgentSessionID)
    }

    @Published var sessions: [ParkedSession] = []
    /// The current attachment mode + notch cutout (set by the controller before each reveal/reposition).
    /// Defaults to `.tab` so the view is well-defined before the first geometry solve.
    @Published var attachment: NotchAttachment = .tab
    /// Drives the smooth ease-in-out **spread**: `false` collapses the panel toward the notch (a tiny seed
    /// at the top-center), `true` spreads it out to full size. The controller flips it inside `withAnimation`
    /// on reveal (→ true) and animated hide (→ false), so the panel grows out of / recedes into the notch.
    @Published var isExpanded: Bool = false
    /// Rail vs in-place expanded conversation (`notch-native-conversations` D4).
    @Published var mode: Mode = .rail
    /// The engine driving the currently-expanded session's conversation (set by the controller on
    /// expand, cleared on collapse). The expanded view observes it directly.
    @Published var engine: NotchSessionEngine?
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

    /// A card was clicked — expand that session IN PLACE into its conversation view.
    var onExpand: ((AgentSessionID) -> Void)?
    /// The "+ New chat" card was activated — create a fresh session (durable at birth) and expand it.
    var onNewSession: (() -> Void)?
    /// The expanded conversation asked to collapse (chevron / Esc / notch-nub click).
    var onCollapse: (() -> Void)?
    /// A card was discarded (deletion — from the card's context menu or the expanded header).
    var onDiscard: ((AgentSessionID) -> Void)?

    /// Flip the panel's key-capability while the expanded composer is focused (`notch-native-conversations`
    /// D5): the panel stays `.nonactivatingPanel` (becoming key never activates the app; the front app
    /// keeps focus) and NEVER becomes main. Dropping key BEFORE any order-out is the caller's job on
    /// collapse/teardown paths (the focus-leak ordering).
    func setKeyCapable(_ on: Bool) {
        guard let panel else { return }
        panel.keyInteractive = on
        if on {
            panel.makeKey()
        } else if panel.isKeyWindow {
            panel.resignKey()
        }
    }

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
            onExpand: { [weak self] id in self?.onExpand?(id) },
            onNewSession: { [weak self] in self?.onNewSession?() },
            onCollapse: { [weak self] in self?.onCollapse?() },
            onDiscard: { [weak self] id in self?.onDiscard?(id) },
            onComposerFocusChanged: { [weak self] focused in self?.setKeyCapable(focused) }
        ))
        return panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect { panel?.frame ?? .zero }

    /// The fluid "droplet" spread duration — the orderOut delay after an animated shrink, and the duration
    /// of the rail↔expanded frame stretch.
    static let spreadDuration: TimeInterval = 0.34
    /// The spring driving the grow-from-a-point (reveal) / shrink-to-a-point (hide) content scale — a fluid
    /// droplet spread (a touch of settle, no bounce-heavy overshoot).
    private static let growSpring: Animation = .spring(response: 0.42, dampingFraction: 0.78)
    /// A scheduled animated-hide teardown, cancelled if a fresh reveal arrives mid-recede.
    private var pendingHide: DispatchWorkItem?
    /// True while an animated recede is in flight (its `orderOut` is scheduled but not yet run) — the
    /// controller reads this to pause its re-feed timer so it doesn't re-trigger the recede every tick.
    var isReceding: Bool { pendingHide != nil }
    /// True while a rail↔expanded frame STRETCH is animating — per-tick reposition setFrames are skipped so
    /// they don't snap the frame and kill the stretch mid-flight.
    private var isResizing = false

    /// Reveal / resize / reposition the panel at `rect`. Three paths, all fade-free:
    /// - **First show** → place at the target instantly, order front, and GROW the whole panel (border and
    ///   all) out of a point behind the notch via a spring on the content scale (anchored at the top).
    /// - **Mode change** (`animateResize`, rail↔expanded) → STRETCH the window frame to the new size fluidly
    ///   (the SwiftUI shape fills the window, so the frame edge IS the border).
    /// - **Per-tick reanchor** → reposition instantly (never re-fronts a visible panel — matching the
    ///   Dock-preview `move(to:)` discipline — and skipped entirely while a stretch is mid-flight).
    /// A reveal arriving during an animated recede cancels the pending teardown.
    func reveal(at rect: CGRect, animateResize: Bool = false) {
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
        if !panel.isVisible {
            // FIRST SHOW: seed the panel as a point behind the notch, order front, then spring it open.
            model.isExpanded = false
            panel.setFrame(rect, display: true)
            panel.orderFrontRegardless()
            withAnimation(Self.growSpring) { model.isExpanded = true }
            return
        }
        if animateResize, panel.frame != rect {
            // MODE CHANGE (rail↔expanded): stretch the border to the new size.
            model.isExpanded = true
            animateFrame(to: rect)
            return
        }
        // PER-TICK reanchor: reposition instantly (skipped while a stretch is mid-flight so it isn't snapped),
        // and RE-GROW if this reveal arrived mid-shrink (the pending grace-dismiss teardown was just cancelled
        // above) so the panel springs back open instead of staying collapsed as a point.
        if !isResizing { panel.setFrame(rect, display: true) }
        if !model.isExpanded {
            withAnimation(Self.growSpring) { model.isExpanded = true }
        }
    }

    /// Fluidly stretch the panel's window frame to `rect` (the rail↔expanded border stretch). One-shot and
    /// self-terminating — the idle-CPU-spin landmine is about *perpetual* animations; this settles and stops.
    private func animateFrame(to rect: CGRect) {
        guard let panel else { return }
        isResizing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.spreadDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)   // fluid ease-out
            panel.animator().setFrame(rect, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isResizing = false }
        })
    }

    /// Tear down the panel. `animated` SHRINKS whatever is showing (rail OR the expanded conversation)
    /// straight back into the point behind the notch (spring on the scale, no fade) then orders out on
    /// completion — the gentle grace-dismiss AND the swipe-up straight-close. `animated == false` is the
    /// **synchronous** `orderOut` (the ghost-on-Space-switch landmine) — restore/disable, teardown immediate.
    /// `completion` runs AFTER the order-out (used by the straight-close to reset the panel to rail mode).
    func hide(animated: Bool, completion: (() -> Void)? = nil) {
        guard let panel else { completion?(); return }
        // Drop key BEFORE any order-out (D5 ordering): a panel holding key through its teardown can
        // strand first-responder state on a Space switch. Harmless when it was never key.
        setKeyCapable(false)
        guard animated else {
            pendingHide?.cancel(); pendingHide = nil
            model.isExpanded = false
            panel.orderOut(nil)                    // synchronous — ghost-on-Space-switch landmine
            completion?()
            return
        }
        if pendingHide != nil { return }           // already receding — don't restart the animation
        withAnimation(Self.growSpring) { model.isExpanded = false }
        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
            self?.pendingHide = nil
            completion?()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spreadDuration, execute: work)
    }
}

/// The rail: a NON-scrollable row of parked cards that hugs and EXPANDS with its sessions. In attached mode it's a **plain black rounded
/// rectangle** whose top edge reaches the physical top so its black simply spans up **behind** the (also
/// black) notch — no cutout is carved, because both are black and read as one shape. The whole container
/// spreads out of / recedes into the notch on the controller's ease-in-out `isExpanded` transition. The
/// cards are **centered** (both axes) in the panel — horizontally so a few sessions don't hug the left, and
/// vertically so they sit clear of the notch. A bounded `failed` badge carries the clean headline ONLY (raw
/// text lives behind an opt-in disclosure on the restored canvas, never here).
struct NotchHomeZoneRailView: View {
    @ObservedObject var model: NotchHomeZoneViewModel
    let onExpand: (AgentSessionID) -> Void
    let onNewSession: () -> Void
    let onCollapse: () -> Void
    let onDiscard: (AgentSessionID) -> Void
    /// The composer focus seam (`notch-native-conversations` D5): the controller flips the panel's
    /// key-capability so keystrokes reach the field only while it is focused.
    let onComposerFocusChanged: (Bool) -> Void

    private var isAttached: Bool {
        if case .notch = model.attachment { return true }
        return false
    }

    var body: some View {
        Group {
            switch model.mode {
            case .rail:
                railBody
            case let .expanded(id):
                if let engine = model.engine {
                    NotchConversationView(
                        engine: engine,
                        session: model.sessions.first { $0.id == id },
                        isAttached: isAttached,
                        onCollapse: onCollapse,
                        onDelete: { onDiscard(id) },
                        onComposerFocusChanged: onComposerFocusChanged)
                } else {
                    // Defensive: an expanded id with no engine (discarded underneath) renders the rail.
                    railBody
                }
            }
        }
        .background(chromeFill)
        .overlay(chromeStroke)
        .clipShape(chromeShape)
        // The fluid "droplet" SPREAD: the whole panel — border and all — GROWS from a point behind the notch
        // to full size (reveal) and shrinks back (hide), anchored at its TOP edge so it unfurls downward AND
        // out to both sides. Driven by the controller's spring on `isExpanded`. There is NO opacity fade —
        // the border itself stretches out of the point (rail↔expanded resizes stretch the window frame).
        .scaleEffect(model.isExpanded ? 1 : Self.seedScale, anchor: .top)
    }

    /// The card rail (the `.rail` mode body): the persistent "+ New chat" card, then one card per
    /// session. Present even with zero sessions — the dock is never an empty dead end.
    ///
    /// NON-scrollable: the panel is sized (by the shared `solve`, counting this same "+ New chat" card) to
    /// HUG every rendered card, so the dock simply EXPANDS as sessions are added rather than scrolling. The
    /// panel is **height-sized by the controller** so that simply CENTERING the row here yields the intended
    /// symmetric vertical padding — the notch height + a little on a notched display (so the cards clear the
    /// notch and sit balanced), or a fixed gap in tab mode.
    private var railBody: some View {
        HStack(spacing: NotchHomeZoneLayout.cardSpacing) {
            NotchNewChatCard(action: onNewSession)
            ForEach(model.sessions) { session in
                NotchParkedCard(session: session,
                                onExpand: { onExpand(session.id) },
                                onDiscard: { onDiscard(session.id) })
            }
        }
        .padding(.horizontal, NotchHomeZoneLayout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// The collapsed seed scale — a near-point at the notch the panel springs out of; non-zero so the
    /// `.top` scale anchor stays well-defined during the grow (a literal `0` collapses the anchor with it).
    private static let seedScale: CGFloat = 0.03

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

/// The persistent "+ New chat" card (`notch-native-conversations`): the notch is the ONLY birthplace of
/// conversational sessions, so the rail always offers one — including on an empty dock.
struct NotchNewChatCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("New chat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: NotchHomeZoneLayout.cardWidth,
                   height: NotchHomeZoneLayout.cardHeight)
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help("Start a new conversation")
    }
}

/// One parked-session card: a title + a state badge. Clicking it expands it in place.
struct NotchParkedCard: View {
    let session: ParkedSession
    let onExpand: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        Button(action: onExpand) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.title.isEmpty ? "Session" : session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                ParkStateBadge(state: session.state, badgeCount: session.badgeCount,
                               isScheduled: session.nextRunAt != nil)
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
    /// Whether a `.parked` row is scheduled or actively advancing (`nextRunAt` set, or being served
    /// right now) vs DORMANT awaiting the user (a confirm-tier pause). Irrelevant for other states.
    var isScheduled: Bool = true

    var body: some View {
        switch state {
        case .parked where isScheduled:
            label("Thinking…", system: "ellipsis", tint: .secondary)
        case .parked:
            // Dormant: a paused step waits until the user opens the session (no escalation, no glow).
            label("Waiting for you", system: "hourglass", tint: .secondary)
        case .idle where badgeCount > 0, .active where badgeCount > 0:
            label("\(badgeCount) new", system: "checkmark.circle.fill", tint: .green)
        case .active:
            // The foreground session: expanded right now, or collapsed while its turn still streams
            // (the engine keeps it `.active` so the background scheduler never double-advances it).
            label("Working…", system: "circle.dotted", tint: .secondary)
        case .idle:
            label("Parked", system: "moon.zzz", tint: .secondary)
        case .needsYou:
            label("Needs you", system: "exclamationmark.circle.fill", tint: .accentColor)
        }
    }

    private func label(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// The in-place EXPANDED conversation (`notch-native-conversations` D4): one session's thread + composer
/// inside the same merged-notch chrome. A cursor-and-keyboard surface — Approve/Skip and Copy are
/// buttons; Enter sends; Esc collapses. The panel becomes key ONLY while the composer is focused (the
/// `onComposerFocusChanged` seam), so the previously-front app keeps focus otherwise.
struct NotchConversationView: View {
    @ObservedObject var engine: NotchSessionEngine
    /// The session's rail row (title/state), when it still exists.
    let session: ParkedSession?
    /// Attached (merged-notch, over the physical top) vs tab mode — drives the top headroom.
    let isAttached: Bool
    let onCollapse: () -> Void
    let onDelete: () -> Void
    let onComposerFocusChanged: (Bool) -> Void

    @State private var composerText = ""
    @State private var thinkingExpanded = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                // Attached mode: the panel's top band sits behind the physical notch — keep the header
                // clear of it (the same headroom idea the centered rail uses).
                .padding(.top, isAttached ? 34 : 10)
                .padding(.horizontal, 14)
            Divider().opacity(0.25).padding(.vertical, 8)
            thread
                .padding(.horizontal, 14)
            composer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .onChange(of: composerFocused) { _, focused in onComposerFocusChanged(focused) }
        // Collapse on Esc from anywhere in the view (the composer owns key events while focused).
        .onExitCommand { onCollapse() }
        .onDisappear { onComposerFocusChanged(false) }   // never leave the panel key-capable behind
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(engine.conversation?.title ?? session?.title ?? "Conversation")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete this session")
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Collapse back to the dock")
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if engine.conversation?.messages.isEmpty ?? true {
                        emptyHint
                    }
                    ForEach(engine.conversation?.messages ?? []) { message in
                        turnBubble(message)
                    }
                    if !engine.thinking.isEmpty {
                        thinkingSection
                    }
                    toolStepsList
                    stateExtras
                    Color.clear.frame(height: 1).id(Self.tailID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            // Open at the END of the conversation (latest turn), not the top — an existing session with
            // history lands at its most recent messages; also keeps the thread pinned to the bottom as it
            // streams. The explicit scroll-to-tail below still animates the jump on each new turn.
            .defaultScrollAnchor(.bottom)
            .onChange(of: engine.conversation?.messages.count ?? 0) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.tailID, anchor: .bottom) }
            }
            .onChange(of: streamingPartial) {
                proxy.scrollTo(Self.tailID, anchor: .bottom)
            }
        }
    }

    private static let tailID = "notch-conversation-tail"

    private var streamingPartial: String {
        if case let .conversing(partial) = engine.state { return partial }
        return ""
    }

    private var emptyHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("Ask anything — this chat lives here at the notch until it expires or you delete it.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func turnBubble(_ message: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.role == .user ? "You" : message.role == .assistant ? "AI" : "Context")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                if message.role == .assistant, !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy this answer")
                }
            }
            BidiText(text: message.text.isEmpty ? "…" : message.text, fontSize: 13)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(message.role == .user ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.05)))
    }

    /// The in-flight assistant turn + per-state extras: the streaming bubble, the approval card with
    /// Approve/Skip buttons, the bounded failed card, and the availability hint.
    @ViewBuilder
    private var stateExtras: some View {
        switch engine.state {
        case .loadingModel:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the model…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case let .conversing(partial):
            VStack(alignment: .leading, spacing: 3) {
                Text("AI").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                BidiText(text: partial.isEmpty ? "…" : partial, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        case let .awaitingApproval(review):
            approvalCard(review)
        case let .failed(message):
            failedCard(message)
        case .unavailable:
            VStack(alignment: .leading, spacing: 4) {
                Label("AI is unavailable", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text("Enable AI commands and download the model in the Hub, then send again.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        case .idle, .awaitingTurn:
            EmptyView()
        }
    }

    /// A paused tool step's review card — resolved by BUTTONS (the notch is the cursor world; the
    /// launcher's two-finger compass is not imported here).
    private func approvalCard(_ review: TaskReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if case let .action(title, fields, _) = review {
                Label(title, systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(field.label).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        Text(field.value).font(.system(size: 12)).foregroundStyle(.white)
                            .naturalTextDirection(for: field.value)
                    }
                }
            } else {
                Label("This step needs your approval", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button { engine.approve() } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button { engine.skip() } label: {
                    Label("Skip", systemImage: "arrow.uturn.forward")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
    }

    /// The bounded, non-blocking failed card: a clean headline only; raw detail is not rendered here
    /// (one taxonomy, one translator — the headline came through `AIError.message(for:)`).
    private func failedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(3).truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
    }

    /// The assistant's live reasoning, collapsed to one tappable row (the canvas's collapsible-thinking
    /// idea, compacted for the notch surface).
    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { thinkingExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Text("Thinking").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                ScrollView {
                    BidiText(text: engine.thinking, fontSize: 11, color: .secondaryLabelColor)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    /// The route loop's ran tool steps — a compact status list (summary + glyph per step).
    @ViewBuilder
    private var toolStepsList: some View {
        if !engine.toolSteps.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(engine.toolSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: Self.stepGlyph(step.status))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Self.stepColor(step.status))
                        Text(step.summary.isEmpty ? step.tool : step.summary)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        }
    }

    private static func stepGlyph(_ status: ToolStepStatus) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .declined: return "minus.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .awaitingApproval: return "exclamationmark.shield.fill"
        }
    }

    private static func stepColor(_ status: ToolStepStatus) -> Color {
        switch status {
        case .done: return .green
        case .declined: return .secondary
        case .failed: return .red
        case .awaitingApproval: return .orange
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message…", text: $composerText)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .onSubmit(sendComposer)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(composerFocused ? 0.5 : 0.15)))
            Button(action: sendComposer) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Send")
        }
    }

    private func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerText = ""
        engine.send(text)
    }
}
