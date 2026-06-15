import AppKit
import ApplicationServices
import CoreGraphics

/// The production `DockReader`: reads `Dock.app`'s Accessibility tree into a `DockSnapshot`. Resolves each
/// **application** dock item to its running process and on-screen frame (converting AX's top-left space to
/// Cocoa bottom-left at this boundary), and ignores folder/stack, Trash, Downloads, separator, and
/// minimized-window items. Degrades to `nil` — never a crash, never raw error text — when the Dock tree or
/// an attribute can't be read (e.g. auto-hidden Dock, or Accessibility not granted). It caches NOTHING:
/// each `read()` re-queries, so magnification (tile frames grow live) and auto-hide reveal are picked up
/// fresh rather than from a stale snapshot.
final class AXDockReader: DockReader {
    /// Dock-item subrole that marks a running/launchable application tile (the only kind we preview).
    private let applicationSubrole = "AXApplicationDockItem"

    func read() -> DockSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dockApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock").first else { return nil }
        let dockEl = AXUIElementCreateApplication(dockApp.processIdentifier)

        guard let items = dockItems(of: dockEl), !items.isEmpty else { return nil }

        // Index running regular apps by bundle id once, to resolve each app tile → pid.
        let runningByBundle: [String: NSRunningApplication] = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { a, _ in a }
        )

        var tiles: [DockTile] = []
        for item in items {
            guard axString(item, kAXSubroleAttribute as String) == applicationSubrole else { continue }
            guard let app = resolveApp(item, runningByBundle: runningByBundle) else { continue }
            guard let frame = tileFrame(item) else { continue }
            tiles.append(DockTile(pid: app.processIdentifier,
                                  bundleID: app.bundleIdentifier,
                                  title: axString(item, kAXTitleAttribute as String) ?? (app.localizedName ?? ""),
                                  frame: frame))
        }
        guard !tiles.isEmpty else { return nil }   // auto-hidden / nothing resolvable → idle

        let orientation = Self.orientation()
        let screenFrame = Self.dockScreenFrame(for: tiles)
        return DockSnapshot(tiles: tiles, orientation: orientation, screenFrame: screenFrame)
    }

    // MARK: - AX traversal

    /// The dock item elements: the children of the Dock's `AXList`, falling back to the Dock app's own
    /// children if no list is exposed (defensive across macOS versions).
    private func dockItems(of dockEl: AXUIElement) -> [AXUIElement]? {
        guard let children = axCopy(dockEl, kAXChildrenAttribute as String) as? [AXUIElement] else { return nil }
        if let list = children.first(where: { axString($0, kAXRoleAttribute as String) == (kAXListRole as String) }),
           let listChildren = axCopy(list, kAXChildrenAttribute as String) as? [AXUIElement] {
            return listChildren
        }
        return children
    }

    /// Resolve an application dock item to its running app: prefer its file URL → bundle id, falling back
    /// to a title match. Returns nil when the app isn't running (nothing to preview).
    private func resolveApp(_ item: AXUIElement,
                            runningByBundle: [String: NSRunningApplication]) -> NSRunningApplication? {
        if let url = axCopy(item, kAXURLAttribute as String) as? URL,
           let bundle = Bundle(url: url)?.bundleIdentifier,
           let app = runningByBundle[bundle] {
            return app
        }
        if let title = axString(item, kAXTitleAttribute as String) {
            return runningByBundle.values.first { $0.localizedName == title }
        }
        return nil
    }

    /// The dock item's icon rect in Cocoa global coordinates, or nil if position/size can't be read.
    private func tileFrame(_ item: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let posValue = axCopy(item, kAXPositionAttribute as String),
              let sizeValue = axCopy(item, kAXSizeAttribute as String) else { return nil }
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return Self.cocoaRect(fromAXTopLeft: CGRect(origin: origin, size: size))
    }

    // MARK: - Geometry

    /// Convert an AX/Quartz rect (top-left origin, y down from the primary display's top) to Cocoa global
    /// (bottom-left origin, y up) — the space the cursor monitor and overlay panel use.
    static func cocoaRect(fromAXTopLeft rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryTop = primary.frame.maxY   // primary screen has origin (0,0), so maxY == its height
        return CGRect(x: rect.origin.x,
                      y: primaryTop - rect.origin.y - rect.height,
                      width: rect.width, height: rect.height)
    }

    /// The Dock's orientation, read from the `com.apple.dock` defaults (`bottom`/`left`/`right`).
    static func orientation() -> DockOrientation {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    /// The visible frame of the screen the Dock tiles sit on (for clamping the popup). Picks the screen
    /// containing the tile-union center, falling back to the main screen.
    static func dockScreenFrame(for tiles: [DockTile]) -> CGRect {
        guard let first = tiles.first else { return NSScreen.main?.visibleFrame ?? .zero }
        var union = first.frame
        for t in tiles.dropFirst() { union = union.union(t.frame) }
        let center = CGPoint(x: union.midX, y: union.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }
}
