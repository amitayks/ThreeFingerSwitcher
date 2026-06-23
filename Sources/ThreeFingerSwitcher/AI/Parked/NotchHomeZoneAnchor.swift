import Foundation
import CoreGraphics

/// The pure top-center anchor geometry for the notch home zone (design §5), mirroring
/// `DockHoverModel.anchorRect`/`clamp`. Notch-aware but NEVER notch-dependent: a notched display tucks
/// the zone just below the notch/menu bar; a notchless built-in OR an external display degrades to a
/// top-center menu-bar tab at a fixed margin. Coordinates are Cocoa global (bottom-left). MLX-free Core.
enum NotchHomeZoneAnchor {
    /// Margin under the notch (when present) / under the menu bar (the `ReceiveHUD` 12pt precedent).
    static let notchMargin: CGFloat = 8
    static let menuBarMargin: CGFloat = 12
    /// Inset keeping rects on-screen (the `DockHoverModel.screenInset` idiom).
    static let screenInset: CGFloat = 8

    /// The resting zone: top-center on the active screen. `safeAreaTop > 0` ⇒ a physical notch (tuck
    /// `safeAreaTop + notchMargin` below the top); `== 0` ⇒ a top-center tab at `menuBarMargin`.
    /// `visibleFrame` is the screen's visible frame (Cocoa, bottom-left; `maxY` is just under the menu bar).
    static func zoneRect(size: CGSize, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGRect {
        let topGap = safeAreaTop > 0 ? safeAreaTop + notchMargin : menuBarMargin
        let origin = CGPoint(x: visibleFrame.midX - size.width / 2,
                             y: visibleFrame.maxY - topGap - size.height)
        return clamp(CGRect(origin: origin, size: size), within: visibleFrame)
    }

    /// The rail EMERGES FROM the notch (design D5): its TOP edge is FLUSH at the notch / menu-bar lower
    /// edge — i.e. flush at the resting zone's TOP (`zone.maxY`), ZERO gap — and it grows DOWNWARD (Cocoa:
    /// smaller y). Top-centered on the zone, clamped on-screen (shift-only, never resized). This replaces
    /// the old free-floating rect that left a full `notchMargin` gap below the zone (the placement bug);
    /// "emerge from the notch" means the container reads as water spreading down out of the notch edge.
    static func railRect(zone: CGRect, size: CGSize, visibleFrame: CGRect) -> CGRect {
        let origin = CGPoint(x: zone.midX - size.width / 2,
                             y: zone.maxY - size.height)
        return clamp(CGRect(origin: origin, size: size), within: visibleFrame)
    }

    /// The ONE contiguous live/hit region (design D5): the union of the resting zone, the connecting band
    /// down to the container top, and the container itself — with NO gap — and extended UP past the zone
    /// into the notch pixels (toward `visibleFrame.maxY` and a touch above, the menu-bar/notch strip) so
    /// moving the cursor UP into the notch lands INSIDE the live zone (the docking target) and never
    /// grace-dismisses. Because `railRect` is flush at `zone.maxY` the zone+container already touch; this
    /// just unions them and lifts the top edge over the notch. Used by both the reveal model (keep-open
    /// test) and the controller's edge-gate.
    static func liveZoneRect(zone: CGRect, rail: CGRect?, visibleFrame: CGRect) -> CGRect {
        // Lift the top edge above the zone into the notch/menu-bar strip (a small contiguous overshoot).
        let topOvershoot = max(menuBarMargin, notchMargin)
        let top = max(zone.maxY + topOvershoot, (rail?.maxY ?? zone.maxY))
        let topCapped = visibleFrame.isNull ? top : min(top, visibleFrame.maxY)
        // The bottom is the container's bottom edge (the rail) when shown, else the zone's bottom.
        let bottom = min(zone.minY, rail?.minY ?? zone.minY)
        // The horizontal span covers both the (narrow) zone and the (wider) container with no inset.
        let minX = min(zone.minX, rail?.minX ?? zone.minX)
        let maxX = max(zone.maxX, rail?.maxX ?? zone.maxX)
        return CGRect(x: minX, y: bottom, width: maxX - minX, height: max(topCapped - bottom, 0))
    }

    /// Keep `rect` inside `bounds` (inset by `screenInset`) without resizing — shift origin only
    /// (verbatim the `DockHoverModel.clamp` idiom).
    static func clamp(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return rect }
        let area = bounds.insetBy(dx: screenInset, dy: screenInset)
        var origin = rect.origin
        origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - rect.width))
        origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }
}
