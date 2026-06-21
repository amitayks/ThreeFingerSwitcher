import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure helpers introduced by `robust-offspace-window-fidelity`:
///   - `ThumbnailService.isOffAllDisplays` / `isDegradedCapture` — the set-aside/off-screen detection
///     that keeps a degraded Stage-Manager strip-proxy capture from overwriting a good thumbnail.
///
/// Off-Space listing now requires a live-or-cached Accessibility element (the metadata-only gate and
/// its negative-observation cache were removed), so listing is exercised by the `--diag` dump and
/// manual multi-Space checks rather than a unit test.
///
/// `@MainActor` because `ThumbnailService` is main-actor isolated (matching `SwitcherModelTests`);
/// the helpers under test are pure but inherit that isolation.
@MainActor
final class OffSpaceFidelityTests: XCTestCase {

    // MARK: - P1: set-aside / off-screen detection

    /// A single 1440x900 display at the origin (top-left global coordinate space).
    private let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testOnScreenWindowIsNotOffAllDisplays() {
        XCTAssertFalse(ThumbnailService.isOffAllDisplays(
            CGRect(x: 100, y: 100, width: 800, height: 600), displayUnion: display))
    }

    func testWindowParkedOffLeftIsOffAllDisplays() {
        // Stage Manager parks set-aside windows off-screen to the left → entirely negative-X.
        XCTAssertTrue(ThumbnailService.isOffAllDisplays(
            CGRect(x: -2000, y: 100, width: 800, height: 600), displayUnion: display))
    }

    func testWindowParkedOffRightIsOffAllDisplays() {
        XCTAssertTrue(ThumbnailService.isOffAllDisplays(
            CGRect(x: 1600, y: 100, width: 800, height: 600), displayUnion: display))
    }

    func testWindowStraddlingLeftEdgeIsNotOffAllDisplays() {
        // Partially visible (real edge window) must NOT be suppressed.
        XCTAssertFalse(ThumbnailService.isOffAllDisplays(
            CGRect(x: -200, y: 100, width: 800, height: 600), displayUnion: display))
    }

    func testNullDisplayUnionNeverSuppresses() {
        // No display evidence → never declare a window off-screen (don't suppress a capture blindly).
        XCTAssertFalse(ThumbnailService.isOffAllDisplays(
            CGRect(x: -5000, y: 0, width: 100, height: 100), displayUnion: .null))
    }

    // MARK: - P1: authoritative degraded-capture test

    func testCleanCaptureIsNotDegraded() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(ThumbnailService.isDegradedCapture(
            scFrame: frame, logicalFrame: frame, displayUnion: display))
    }

    func testOffScreenCaptureIsDegraded() {
        let frame = CGRect(x: -2000, y: 100, width: 800, height: 600)
        XCTAssertTrue(ThumbnailService.isDegradedCapture(
            scFrame: frame, logicalFrame: frame, displayUnion: display))
    }

    func testScaledProxyCaptureIsDegraded() {
        // SCK reports a frame far smaller than the window's logical frame in both dimensions.
        XCTAssertTrue(ThumbnailService.isDegradedCapture(
            scFrame: CGRect(x: 50, y: 50, width: 200, height: 130),
            logicalFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUnion: display))
    }

    func testNearFullSizeCaptureIsNotDegraded() {
        // A capture at >=85% of logical in both dimensions is treated as clean (small slack for shadow /
        // title-bar measurement differences); a cleanly-presented window reports ~100%.
        XCTAssertFalse(ThumbnailService.isDegradedCapture(
            scFrame: CGRect(x: 100, y: 100, width: 740, height: 540),
            logicalFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUnion: display))
    }

    func testStageManagerTransitionCaptureIsDegraded() {
        // A window mid-animation between the Stage-Manager strip and the full stage is well below the
        // clean threshold even when it's already past 50% — the band the old 0.5 gate let through.
        XCTAssertTrue(ThumbnailService.isDegradedCapture(
            scFrame: CGRect(x: 100, y: 100, width: 500, height: 400),   // ~0.63 / ~0.67 of logical
            logicalFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
            displayUnion: display))
    }

    func testAspectMorphTransitionCaptureIsDegraded() {
        // The strip⇄stage morph changes aspect, so ONE dimension can be near-full while the other is
        // short; either being short marks it degraded (the `||`, not `&&`).
        XCTAssertTrue(ThumbnailService.isDegradedCapture(
            scFrame: CGRect(x: 0, y: 33, width: 1300, height: 500),     // w ~0.86 (ok) but h ~0.53 (short)
            logicalFrame: CGRect(x: 0, y: 33, width: 1511, height: 949),
            displayUnion: display))
    }

    // MARK: - P1: Stage-Manager strip-thumbnail detection (current-Space set-aside)

    func testStripProxyDetected() {
        // CGWindowList reports the small scaled strip rect (positive x, on-screen) while AX reports
        // the real window size — the current-Space set-aside case the off-screen test misses.
        XCTAssertTrue(ThumbnailService.isStripProxy(
            displayedFrame: CGRect(x: 16, y: 164, width: 160, height: 184),
            realFrame: CGRect(x: 0, y: 33, width: 1512, height: 949)))
    }

    func testNormalWindowIsNotStripProxy() {
        // A cleanly-visible window: CGWindowList bounds match the AX size → not a proxy.
        let f = CGRect(x: 100, y: 100, width: 1200, height: 800)
        XCTAssertFalse(ThumbnailService.isStripProxy(displayedFrame: f, realFrame: f))
    }

    func testZeroRealFrameIsNotStripProxy() {
        // No real-size info (legacy path / no AX element) → never suppress a capture.
        XCTAssertFalse(ThumbnailService.isStripProxy(
            displayedFrame: CGRect(x: 16, y: 164, width: 160, height: 184), realFrame: .zero))
    }

    func testNearFullSizeWindowIsNotStripProxy() {
        // A window displayed at >=85% of its AX size in both dimensions is not a proxy (a cleanly-
        // presented window reports ~100%; the slack absorbs shadow / title-bar measurement differences).
        XCTAssertFalse(ThumbnailService.isStripProxy(
            displayedFrame: CGRect(x: 0, y: 0, width: 740, height: 540),
            realFrame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }

    func testStageManagerTransitionWindowIsStripProxy() {
        // A window mid-animation between the strip and the stage (past 50% but not yet settled) is a
        // proxy — the case the old 0.5 threshold let through and captured sideways.
        XCTAssertTrue(ThumbnailService.isStripProxy(
            displayedFrame: CGRect(x: 0, y: 33, width: 800, height: 500),   // ~0.53 / ~0.53 of real
            realFrame: CGRect(x: 0, y: 33, width: 1511, height: 949)))
    }

    // MARK: - Refresh sweep: capture cleanly-presented windows, skip degraded ones

    func testRefreshCapturesCleanlyPresentedWindow() {
        // A cleanly-presented window is captured. A cached frame is no longer a reason to skip — the sweep
        // re-captures to stay fresh and self-heal; the pure gate just checks how the window is presented.
        let f = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(ThumbnailService.shouldPrefetchCapture(
            displayedFrame: f, realFrame: f, displayUnion: display))
    }

    func testRefreshSkipsStripProxy() {
        // A Stage-Manager strip proxy would capture as the tilted strip → skipped, served from cache/icon.
        XCTAssertFalse(ThumbnailService.shouldPrefetchCapture(
            displayedFrame: CGRect(x: 16, y: 164, width: 160, height: 184),
            realFrame: CGRect(x: 0, y: 33, width: 1512, height: 949), displayUnion: display))
    }

    func testRefreshSkipsOffDisplayWindow() {
        // A window parked off every display (Stage-Manager set-aside) is skipped (degraded).
        let f = CGRect(x: -2000, y: 100, width: 800, height: 600)
        XCTAssertFalse(ThumbnailService.shouldPrefetchCapture(
            displayedFrame: f, realFrame: f, displayUnion: display))
    }

    // MARK: - Motion gate: discard a frame grabbed while the window is animating

    func testStillFrameIsNotInMotion() {
        // Identical bounds immediately before and after the capture → the window is settled → keep the frame.
        let f = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertFalse(ThumbnailService.frameMovedDuringCapture(before: f, after: f))
    }

    func testMovedFrameIsInMotion() {
        // A frame change across the capture (Stage-Manager morph / Dock genie) marks it in-motion → discard,
        // so the tilted "sideways" frame never replaces the last good one.
        let before = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(ThumbnailService.frameMovedDuringCapture(
            before: before, after: CGRect(x: 100, y: 100, width: 812, height: 600)))   // 12px wider mid-morph
    }

    func testEvenOnePixelShiftIsInMotion() {
        // The gate is exact: even a 1px origin shift during the animation is enough to reject the frame.
        let before = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(ThumbnailService.frameMovedDuringCapture(
            before: before, after: CGRect(x: 101, y: 100, width: 800, height: 600)))
    }

    // MARK: - Capture sizing bounded to the display target

    func testLargeWindowCaptureIsCappedToDisplayTarget() {
        // A 4K window at 2× backing would be 7680×4320 native; it must be capped to the 600×400 target,
        // not captured at full native resolution.
        let dims = ThumbnailService.captureDimensions(
            windowSize: CGSize(width: 3840, height: 2160), backingScale: 2,
            cap: CGSize(width: 600, height: 400))
        XCTAssertLessThanOrEqual(dims.width, 600)
        XCTAssertLessThanOrEqual(dims.height, 400)
        XCTAssertEqual(dims.width, 600)        // width is the binding dimension here
        XCTAssertLessThan(dims.width, 7680)    // definitively not full native
    }

    func testSmallWindowCaptureIsNotUpscaled() {
        // A small window stays at its native size (fit ≤ 1) — never upscaled to fill the cap.
        let dims = ThumbnailService.captureDimensions(
            windowSize: CGSize(width: 200, height: 150), backingScale: 2,
            cap: CGSize(width: 600, height: 400))
        XCTAssertEqual(dims.width, 400)        // 200 × 2, unscaled
        XCTAssertEqual(dims.height, 300)       // 150 × 2, unscaled
    }

    // MARK: - Periodic refresh cadence

    func testPreviewRefreshIntervalIsSlowNotLive() {
        // The visible row refreshes on a slow "slowly but surely" sweep, NOT the old 0.1s live loop —
        // guards against a regression back to a per-tick highlight capture.
        XCTAssertGreaterThanOrEqual(AppCoordinator.previewRefreshInterval, 0.5)
    }
}
