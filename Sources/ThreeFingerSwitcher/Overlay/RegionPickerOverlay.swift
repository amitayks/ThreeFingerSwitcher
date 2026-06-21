import AppKit

/// Owns the **mouse-interactive** screen-region picker overlay (spec `screen-region-picker`): a
/// full-screen, dimmed, crosshair surface over the revealed desktop on which the user drags a rectangle
/// to capture. Like `DockPreviewOverlayController` it is the rare overlay that does NOT ignore the mouse;
/// it is still a `.nonactivatingPanel` and never becomes key/main (no keyboard — cancellation is a
/// click-without-drag, never Esc), so the captured front app stays frontmost. Teardown is **synchronous**
/// (`orderOut` + `close`) — the files-band / Dock ghost-on-Space-switch landmine applies here too.
///
/// The pure geometry + the click-vs-drag verdict live in `RegionPickerModel`; this controller only wires
/// AppKit mouse events to it and renders. v1 scopes a pick to a single display: the screen under the
/// cursor at show time (falling back to the main screen).
@MainActor
final class RegionPickerOverlay {
    private var panel: NSPanel?

    /// Resolved once per session: a designated rectangle (Cocoa global, bottom-left) to capture, or a
    /// cancel (a click without a drag). The overlay is torn down before this fires.
    private var onResolve: ((RegionPickerModel.Resolution) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Present the picker over the screen under the cursor and call `onResolve` exactly once when the drag
    /// resolves. The overlay orders itself out (synchronously) before invoking the callback, so a capture
    /// that fronts a window / a Space switch never carries the dimming surface along.
    func show(onResolve: @escaping (RegionPickerModel.Resolution) -> Void) {
        self.onResolve = onResolve
        let screen = Self.screenUnderCursor()
        let panel = makePanel(on: screen)
        self.panel = panel
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Synchronous teardown (no deferred close — Space-switch ghost landmine). Idempotent.
    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false          // the picker takes the pointer (drag to select)
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu                   // above normal windows, over the revealed desktop
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let canvas = RegionPickerCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.onResolve = { [weak self] resolution in self?.resolve(resolution) }
        panel.contentView = canvas
        return panel
    }

    /// Tear down the overlay FIRST (synchronous), then deliver the resolution — so a capture that fronts a
    /// window never grabs the dimming surface, and the front app is restored before the callback runs.
    private func resolve(_ resolution: RegionPickerModel.Resolution) {
        let callback = onResolve
        onResolve = nil
        hide()
        callback?(resolution)
    }

    /// The screen under the cursor at show time (single-display v1), falling back to the main screen.
    private static func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// The drawing + mouse-tracking surface inside the picker panel. Non-flipped (default bottom-left), so its
/// coordinates align with Cocoa screen handedness; it feeds window-space points to a `RegionPickerModel`
/// and converts the resolved rectangle to **global screen** coordinates once, at mouse-up.
private final class RegionPickerCanvas: NSView {
    var onResolve: ((RegionPickerModel.Resolution) -> Void)?
    private var model = RegionPickerModel()

    override var acceptsFirstResponder: Bool { true }
    /// Take the very first click without requiring the panel to activate first (it never becomes key).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)   // "select mode" cursor over the whole surface
    }

    override func mouseDown(with event: NSEvent) {
        model.begin(at: event.locationInWindow)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        model.drag(to: event.locationInWindow)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let resolution = model.end(at: event.locationInWindow)
        needsDisplay = true
        switch resolution {
        case .cancel:
            onResolve?(.cancel)
        case let .region(windowRect):
            onResolve?(.region(rectToScreen(windowRect)))
        }
    }

    /// Convert a rectangle in window coordinates to global screen coordinates (both bottom-left). The
    /// content view fills the window at the origin, so window coords == view coords; only the origin needs
    /// the window→screen hop (size is translation-invariant).
    private func rectToScreen(_ windowRect: CGRect) -> CGRect {
        guard let window else { return windowRect }
        let origin = window.convertPoint(toScreen: windowRect.origin)
        return CGRect(origin: origin, size: windowRect.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim the whole surface so the revealed desktop reads as "pick a region" mode.
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard let sel = model.liveRect, sel.width > 0, sel.height > 0 else { return }
        // Punch the selection clear (reveal the live desktop through the window) and outline it.
        NSColor.clear.set()
        sel.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: sel)
        outline.lineWidth = 2
        outline.stroke()
    }
}
