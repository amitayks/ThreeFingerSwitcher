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

    // MARK: - Attached (notch-merged) mode — the NotchNook look

    /// The physical notch cutout box in Cocoa global coords (bottom-left), or `nil` when the display has no
    /// notch (notchless built-in OR external → the honest top-center tab). Derived from the two menu-bar
    /// strips flanking the camera housing (`NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`): the
    /// cutout is the gap BETWEEN them, its height `safeAreaTop`, its top edge the physical top
    /// (`screenFrame.maxY`). The y is taken from `screenFrame` (robust) — only the aux X extents are trusted.
    static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat,
                          auxLeft: CGRect?, auxRight: CGRect?) -> CGRect? {
        guard safeAreaTop > 0, let l = auxLeft, let r = auxRight, r.minX > l.maxX else { return nil }
        return CGRect(x: l.maxX, y: screenFrame.maxY - safeAreaTop,
                      width: r.minX - l.maxX, height: safeAreaTop)
    }

    /// The smallest horizontal flank kept on each side of the notch inside the merged panel, so the notch
    /// tongue always fits with its concave fillets even when the content (few cards) is narrower than the
    /// notch. The merged panel width is `max(contentWidth, notchWidth + 2 * minNotchFlank)`.
    static let minNotchFlank: CGFloat = 26

    /// The resting nub in attached mode: a thin lip hugging the notch — centered on the cutout, its TOP
    /// edge FLUSH at the notch's bottom (`notch.minY`, zero gap), growing downward. Clamped horizontally
    /// within `screenFrame` (the top is never clamped — it must stay welded to the notch).
    static func attachedNubRect(size: CGSize, notch: CGRect, screenFrame: CGRect) -> CGRect {
        let origin = CGPoint(x: notch.midX - size.width / 2, y: notch.minY - size.height)
        return clampHorizontally(CGRect(origin: origin, size: size), within: screenFrame)
    }

    /// The expanded/merged panel: centered on the notch, its TOP reaching the PHYSICAL top (`notch.maxY`)
    /// so the panel's black spans the notch band and reads as one shape. `contentSize.height` is the height
    /// BELOW the notch (the rail); total panel height = `notch.height + contentSize.height`. The width hugs
    /// the content but never narrower than the notch + flanks. Clamped horizontally within `screenFrame`;
    /// the top stays welded to the physical top (never clamped down).
    static func attachedPanelRect(contentSize: CGSize, notch: CGRect, screenFrame: CGRect) -> CGRect {
        let width = max(contentSize.width, notch.width + 2 * minNotchFlank)
        let totalH = contentSize.height + notch.height
        let origin = CGPoint(x: notch.midX - width / 2, y: notch.maxY - totalH)
        return clampHorizontally(CGRect(origin: origin, size: CGSize(width: width, height: totalH)),
                                 within: screenFrame)
    }

    /// The one contiguous live/hit region for attached mode: the union of the resting nub, the merged panel
    /// (when shown), and the notch cutout itself — so the cursor moving UP into the notch (the docking
    /// target) stays inside the live zone and never grace-dismisses. Mirrors `liveZoneRect`'s contract.
    static func attachedLiveZone(nub: CGRect, panel: CGRect?, notch: CGRect) -> CGRect {
        var union = nub.union(notch)
        if let panel { union = union.union(panel) }
        return union
    }

    /// Horizontal-only clamp: shift the origin so `rect` stays within `bounds` inset by `screenInset` on the
    /// LEFT/RIGHT only, leaving the vertical position (welded to the notch/physical top) untouched.
    static func clampHorizontally(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        guard !bounds.isNull, bounds.width > 0 else { return rect }
        let minX = bounds.minX + screenInset
        let maxX = bounds.maxX - screenInset
        var origin = rect.origin
        origin.x = min(max(origin.x, minX), max(minX, maxX - rect.width))
        return CGRect(origin: origin, size: rect.size)
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
