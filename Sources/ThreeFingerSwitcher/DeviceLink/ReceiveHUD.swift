import AppKit
import SwiftUI
import DeviceLinkProtocol

/// The transient on-receive notch HUD: a small, non-activating glass capsule near the top-center of the
/// active screen confirming that a device-link item just landed (or that it couldn't). Mirrors the
/// `LanesLiveToast` panel pattern — a borderless `.nonactivatingPanel` that never steals focus, ignores
/// the mouse (click-through), floats below the notch/menu bar, fades+drifts in, rests, then lifts away.
/// A burst of receives coalesces into the single live panel (content updated + timer re-armed) rather
/// than stacking windows. Fire-and-forget: `show` is the last, non-throwing step on the receive path, so
/// a HUD problem can never affect storage/auto-paste.
@MainActor
final class ReceiveHUDController {
    private var panel: NSPanel?
    /// The pending auto-dismiss; cancelled + re-armed when a new receive coalesces into the live panel.
    private var dismissWork: DispatchWorkItem?
    /// Bumped on every show/hide. A dismiss fade-out captures the value and only tears the panel down if it
    /// still matches in its completion — so a receive that coalesces DURING the fade revives the panel
    /// instead of having it nil'd out from under the new content.
    private var epoch = 0
    private let restDuration: TimeInterval = 3.5

    /// Show (or, if already visible, update) the HUD for a received item. `kind` drives the icon/label,
    /// `deviceName` the source (falls back to "a device"), `success == false` swaps to the failure state.
    func show(kind: LinkItemKind, from deviceName: String?, success: Bool) {
        epoch += 1   // supersede any in-flight dismiss fade-out's completion (see hide())
        let content = ReceiveHUDView(kind: kind, deviceName: deviceName, success: success)

        // Coalesce: a receive while the HUD is still up just swaps the content and re-arms the timer —
        // bursts update one panel instead of stacking (mirrors LanesLiveToast's single-instance guard).
        if let panel {
            (panel.contentView as? NSHostingView<ReceiveHUDView>)?.rootView = content
            panel.contentView?.layoutSubtreeIfNeeded()
            layout(panel)
            // Snap back to opaque in case a dismiss fade-out was mid-flight (the epoch bump above already
            // stops that stale fade's completion from tearing the panel down).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
            armDismiss()
            return
        }

        let view = NSHostingView(rootView: content)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let rect = topCenterRect(size: size)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        // NOT `.canJoinAllSpaces` — that causes a documented Space-switch ghost; `.ignoresCycle` keeps it
        // out of window cycling while `.fullScreenAuxiliary` lets it ride over a full-screen app.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        // Drift down into place + fade in, like the lanes toast — never a hard pop on the desktop.
        panel.alphaValue = 0
        panel.setFrame(rect.offsetBy(dx: 0, dy: 12), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(rect, display: true)
        }
        armDismiss()
    }

    /// Dismiss any visible HUD immediately (fade out, then nil the panel). Called on feature teardown.
    func hide() {
        dismissWork?.cancel()
        dismissWork = nil
        guard let panel else { return }
        epoch += 1
        let token = epoch
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 8), display: true)
        }, completionHandler: { [weak self] in
            // A receive (or another hide) during the fade bumped the epoch — it revived this panel, so
            // don't tear it down.
            guard let self, self.epoch == token else { return }
            self.panel?.orderOut(nil)
            self.panel?.close()
            self.panel = nil
        })
    }

    /// (Re-)schedule the rest → fade-out. Cancelling the prior work item is what lets a coalesced receive
    /// keep the panel alive for a fresh full duration instead of inheriting the old deadline.
    private func armDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restDuration, execute: work)
    }

    /// Re-place an already-shown panel after a content swap (the coalesced item may resize the capsule).
    private func layout(_ panel: NSPanel) {
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrame(topCenterRect(size: size), display: true)
    }

    /// Notch-aware top-center geometry on the active screen: centered on the visible frame, with the top
    /// edge a margin below the menu bar/notch (`safeAreaInsets.top` where the screen reports one — the
    /// notch — else a fixed margin under the menu bar).
    private func topCenterRect(size: NSSize) -> NSRect {
        let screen = screenUnderMouse() ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? .zero
        let safeTop = screen?.safeAreaInsets.top ?? 0
        let topMargin: CGFloat = safeTop > 0 ? safeTop + 8 : 12
        let x = (frame.minX + (frame.width - size.width) / 2).rounded()
        let y = (frame.maxY - size.height - topMargin).rounded()
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

/// The glass capsule the HUD draws: an SF Symbol for the item kind (or a warning on failure) beside a
/// short "Received <kind> from <device>" / "Couldn't receive from <device>" line, in the app's `HubGlass`.
private struct ReceiveHUDView: View {
    let kind: LinkItemKind
    let deviceName: String?
    let success: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(success ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.orange))
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(HubGlass(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var source: String { deviceName ?? "a device" }

    private var message: String {
        success ? "Received \(kindLabel) from \(source)" : "Couldn't receive from \(source)"
    }

    private var symbol: String {
        guard success else { return "exclamationmark.triangle.fill" }
        switch kind {
        case .text, .richText: return "doc.text"
        case .url: return "link"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file: return "doc"
        }
    }

    private var kindLabel: String {
        switch kind {
        case .text, .richText: return "text"
        case .url: return "link"
        case .image: return "image"
        case .color: return "value"
        case .file: return "file"
        }
    }
}
