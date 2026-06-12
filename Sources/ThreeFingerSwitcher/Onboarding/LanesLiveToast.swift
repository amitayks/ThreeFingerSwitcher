import AppKit
import SwiftUI

/// The post-re-login acknowledgment for a wizard completed with "Later": a small, transient,
/// non-activating glass capsule — never a modal — telling the user their claimed lanes are live.
/// Auto-dismisses; shown at most once (the store's acknowledgment flag is consumed by the caller).
@MainActor
final class LanesLiveToast {
    private var panel: NSPanel?

    func show(duration: TimeInterval = 4.5) {
        guard panel == nil, let screen = NSScreen.main else { return }
        let view = NSHostingView(rootView: LanesLiveToastView())
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let frame = screen.visibleFrame
        let rect = NSRect(x: (frame.minX + (frame.width - size.width) / 2).rounded(),
                          y: (frame.minY + frame.height * 0.80).rounded(),
                          width: size.width, height: size.height)
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        // The payoff lands like everything else in the performance moves: it drifts down into
        // place and fades in, rests, then lifts away — never a hard pop on the user's desktop.
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
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
                panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 8), display: true)
            }, completionHandler: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.panel?.close()
                self?.panel = nil
            })
        }
    }
}

private struct LanesLiveToastView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw.fill")
                .foregroundStyle(.tint)
            Text("Your gestures are live — try a three-finger slide.")
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(HubGlass(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
