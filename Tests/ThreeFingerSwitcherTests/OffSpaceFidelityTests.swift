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

    func testModestlySmallerCaptureIsNotDegraded() {
        // A capture only somewhat smaller than logical (>=50% in a dimension) is treated as clean,
        // so a genuinely small or slightly-resized window is not misclassified.
        XCTAssertFalse(ThumbnailService.isDegradedCapture(
            scFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
            logicalFrame: CGRect(x: 100, y: 100, width: 800, height: 600),
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

    func testModestlySmallerWindowIsNotStripProxy() {
        // A window only somewhat smaller in display than its AX size (>=50% in a dimension) is not a
        // strip proxy, so a genuinely small or slightly-scaled window is not misclassified.
        XCTAssertFalse(ThumbnailService.isStripProxy(
            displayedFrame: CGRect(x: 0, y: 0, width: 500, height: 400),
            realFrame: CGRect(x: 0, y: 0, width: 800, height: 600)))
    }
}
