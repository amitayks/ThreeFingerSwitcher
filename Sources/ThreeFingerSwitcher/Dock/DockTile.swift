import Foundation
import CoreGraphics

/// Which edge of its display the Dock occupies. Drives where the preview popup is anchored relative to
/// the hovered tile (away from the screen edge).
enum DockOrientation: Equatable {
    case bottom
    case left
    case right
}

/// One resolved **application** tile in the Dock: the running app it represents and where its icon sits
/// on screen. Folder/stack, Trash, Downloads, separator, and minimized-window tiles are NOT modeled —
/// the reader filters them out, so a `DockTile` always maps to a process we can enumerate windows for.
///
/// **Coordinate space:** `frame` is in **Cocoa global screen coordinates** (bottom-left origin, y up) —
/// the same space as `NSEvent.mouseLocation`, `NSScreen.frame`, and the overlay panel. The real AX
/// reader converts from Accessibility's top-left space at the boundary, so the pure hover/anchor math
/// never has to juggle coordinate handedness.
struct DockTile: Equatable {
    let pid: pid_t
    let bundleID: String?
    let title: String
    /// The icon's on-screen rect in Cocoa global coordinates. Updates with Dock magnification (the AX
    /// reader re-reads while the cursor is in the strip), so this is the tile's *current* frame.
    let frame: CGRect
}

/// A single read of the Dock: its app tiles plus the geometry needed to anchor a popup (orientation +
/// the usable frame of the display the Dock is on). All rects in Cocoa global coordinates.
struct DockSnapshot: Equatable {
    let tiles: [DockTile]
    let orientation: DockOrientation
    /// The visible (menu-bar/Dock-excluded) frame of the screen the Dock is on, for clamping the popup.
    let screenFrame: CGRect
}

/// The seam onto the Dock's Accessibility tree — mirrors the `FileWorkspace` / `LLMRuntime` idea so the
/// hover logic depends only on this protocol and can be driven by a static fake in tests. The real
/// conformer (`AXDockReader`) reads `Dock.app`'s AX tree; it degrades to `nil` (no crash, no raw error)
/// when the tree or an attribute can't be read.
protocol DockReader: AnyObject {
    /// Read the current Dock state, or `nil` when the Dock is unreadable (e.g. auto-hidden / no AX).
    func read() -> DockSnapshot?
}

/// A fixed-snapshot `DockReader` for unit tests (and a degraded-to-empty stand-in). Returns whatever
/// snapshot it was given, so tests drive the hover model deterministically without a live Dock.
final class StaticDockReader: DockReader {
    var snapshot: DockSnapshot?
    init(_ snapshot: DockSnapshot?) { self.snapshot = snapshot }
    func read() -> DockSnapshot? { snapshot }
}
