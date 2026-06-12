import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for `PermissionsService`'s live-polling lifecycle (Permissions/PermissionsService.swift).
/// The timer factory is injected so no real timers fire; statuses come from the real (harmless,
/// read-only) detection APIs — the lifecycle, refcounting, and tick plumbing are what's under test.
@MainActor
final class PermissionsPollingTests: XCTestCase {
    private final class TimerFactorySpy {
        var startCount = 0
        var lastTick: (@MainActor () -> Void)?
        /// Un-scheduled timers so invalidate() is safe and nothing ever fires on its own.
        func make(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Timer {
            startCount += 1
            lastTick = tick
            return Timer(timeInterval: interval, repeats: true) { _ in }
        }
    }

    private var service: PermissionsService!
    private var spy: TimerFactorySpy!

    override func setUp() {
        super.setUp()
        service = PermissionsService()
        spy = TimerFactorySpy()
        service.pollTimerFactory = { [spy] interval, tick in spy!.make(interval, tick) }
    }

    func testStartPollingRefreshesImmediatelyAndCreatesOneTimer() {
        XCTAssertFalse(service.isPolling)
        service.startPolling()
        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(spy.startCount, 1)
        // The immediate refresh resolved every status from the real detection APIs.
        XCTAssertNotEqual(service.accessibility, .unknown)
        XCTAssertNotEqual(service.screenRecording, .unknown)
    }

    func testOverlappingSurfacesShareOneTimer() {
        service.startPolling()   // wizard act appears
        service.startPolling()   // Setup page also visible
        XCTAssertEqual(spy.startCount, 1, "refcounted: no second timer")
        service.stopPolling()    // one surface goes away
        XCTAssertTrue(service.isPolling, "the other surface still needs the poll")
        service.stopPolling()
        XCTAssertFalse(service.isPolling)
    }

    func testUnbalancedStopIsSafe() {
        service.stopPolling()
        XCTAssertFalse(service.isPolling)
        service.startPolling()
        XCTAssertTrue(service.isPolling)
    }

    func testTickRefreshesStatuses() {
        service.startPolling()
        service.accessibility = .unknown   // perturb; the tick must re-resolve it
        spy.lastTick?()
        XCTAssertNotEqual(service.accessibility, .unknown)
    }

    func testRestartAfterFullStopCreatesANewTimer() {
        service.startPolling()
        service.stopPolling()
        service.startPolling()
        XCTAssertEqual(spy.startCount, 2)
    }
}
