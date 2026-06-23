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

/// The observable rail state (the AppKit/SwiftUI seam). The pure scheduler/store own the data; this is
/// the view-model the overlay renders. `@MainActor` — UI state.
@MainActor
final class NotchHomeZoneViewModel: ObservableObject {
    @Published var sessions: [ParkedSession] = []
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

    /// Reveal the rail at `rect` and order it to the front (reveal only).
    func show(at rect: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    /// Reposition the already-visible rail WITHOUT re-ordering it to the front (per-tick reanchor) — so a
    /// layer above (e.g. a menu) is never stomped, matching the Dock-preview `move(to:)` discipline.
    func move(to rect: CGRect) {
        panel?.setFrame(rect, display: true)
    }

    /// Synchronous teardown (no deferred close — Space-switch ghost landmine).
    func hide() {
        panel?.orderOut(nil)
    }
}

/// The rail: a horizontally-scrollable row of parked cards EMERGING FROM the notch (design D5). The whole
/// bordered container spreads down out of the notch edge — a container-level `bubbleMorph(anchor: .top)`
/// scale/clip-reveal anchored at the TOP edge on the `BubbleMorph` spring, so it reads as water spreading
/// down into the container rather than a card-by-card pop. Each card still buds in (anchored `.top` too,
/// so per-card growth also flows downward from the notch). A bounded `failed` badge carries the clean
/// headline ONLY (raw text lives behind an opt-in disclosure on the restored canvas, never here).
struct NotchHomeZoneRailView: View {
    @ObservedObject var model: NotchHomeZoneViewModel
    let onRestore: (AgentSessionID) -> Void
    let onDiscard: (AgentSessionID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotchHomeZoneLayout.cardSpacing) {
                ForEach(model.sessions) { session in
                    NotchParkedCard(session: session,
                                    onRestore: { onRestore(session.id) },
                                    onDiscard: { onDiscard(session.id) })
                        .bubbleMorph(anchor: .top)   // each card grows downward, out of the notch edge
                }
            }
            .padding(NotchHomeZoneLayout.padding)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 18))   // clip-reveal so the spread is bounded by the chrome
        // Container-level spread: the bordered container scales up FROM ITS TOP EDGE (flush at the notch)
        // on the same droplet spring, so the whole rail unfurls downward out of the notch.
        .bubbleMorph(anchor: .top)
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
