import Foundation
import CoreGraphics

/// The pure overscroll-park decision (design §4), consumed at the `AppCoordinator` seam — the recognizer
/// is UNTOUCHED. Mirrors the existing `canvasAtTop` commit guard exactly: TOP of canvas = act
/// (down-at-top = commit), BOTTOM = stash (up-past-bottom = park). The consumer reads the recognizer's
/// raw `launcherCanvasResolve(dx:dy:)`; this helper decides whether an UP excursion is a park.
enum OverscrollPark {
    /// Park ONLY when the canvas is already at its bottom AND the accumulated UP excursion exceeds
    /// `overscrollThreshold` (a value ABOVE `canvasResolveThreshold`, so reading the canvas / a normal
    /// scroll-to-bottom never parks).
    /// - Parameter dy: UP travel is positive (the recognizer's vertical direction); a normal scroll.
    static func shouldPark(dy: CGFloat, canvasAtBottom: Bool, overscrollThreshold: CGFloat) -> Bool {
        canvasAtBottom && dy > overscrollThreshold
    }
}
