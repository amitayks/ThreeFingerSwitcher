import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for `notch-conversation-gestures`: the shared D4 flick classifier (§1), the recognizer's
/// two-finger notch mode with fall-through (§2), and the audit ledger's single removal operation —
/// the user's per-session purge (§3). ParkController-level purge/wiring lives in `ParkedSessionsTests`.
@MainActor
final class NotchFlickGestureTests: XCTestCase {

    // MARK: - Harness

    /// Records canvas + notch resolves and the switcher lifecycle, so routing tests can assert exactly
    /// which grammar consumed a synthetic frame stream.
    private final class MockDelegate: GestureRecognizerDelegate {
        private(set) var canvasResolves: [(dx: Int, dy: Int)] = []
        private(set) var notchResolves: [(dx: Int, dy: Int)] = []
        private(set) var activateCount = 0

        func gestureDidActivate() { activateCount += 1 }
        func gestureDidStep(_ direction: Int) {}
        func gestureDidStepRow(_ direction: Int) {}
        func gestureDidTriggerMissionControl(up: Bool) {}
        func gestureDidCommit() {}
        func gestureDidCancel() {}
        func launcherCanvasResolve(dx: Int, dy: Int) { canvasResolves.append((dx, dy)) }
        func notchConversationResolve(dx: Int, dy: Int) { notchResolves.append((dx, dy)) }
    }

    private func makeSettings() -> AppSettings {
        let defaults = UserDefaults(suiteName: "ThreeFingerSwitcherTests.\(UUID().uuidString)")!
        return AppSettings(defaults: defaults)   // defaults: flick 0.8 vel / 0.12s window, axisLockRatio, exactly-three
    }

    private func makeRecognizer(_ settings: AppSettings, delegate: MockDelegate) -> GestureRecognizer {
        let r = GestureRecognizer(settings: settings)
        r.delegate = delegate
        return r
    }

    private func frame(_ count: Int, x: CGFloat, y: CGFloat,
                       vx: CGFloat = 0, vy: CGFloat = 0, t: CFTimeInterval) -> TouchFrame {
        TouchFrame(testFingerCount: count, centroid: CGPoint(x: x, y: y),
                   velocity: CGVector(dx: vx, dy: vy), time: t)
    }

    // MARK: - 1. FlickExcursionClassifier (the shared D4 math, direct)

    private func classify(_ c: FlickExcursionClassifier) -> (dx: Int, dy: Int)? {
        c.classifyOnLift(travelFloor: 0.12, velocityThreshold: 0.8, liftWindow: 0.12, axisLockRatio: 1.4)
    }

    func testClassifierFastFlicksClassifyWithTheRightSign() {
        // Up, down, right, left — each a fast excursion with a prompt lift.
        let cases: [(dx: CGFloat, dy: CGFloat, vx: CGFloat, vy: CGFloat, want: (Int, Int))] = [
            (0, 0.2, 0, 2.0, (0, 1)),     // up
            (0, -0.2, 0, 2.0, (0, -1)),   // down
            (0.2, 0, 2.0, 0, (1, 0)),     // right
            (-0.2, 0, 2.0, 0, (-1, 0)),   // left
        ]
        for c in cases {
            var flick = FlickExcursionClassifier()
            flick.begin(at: CGPoint(x: 0.5, y: 0.5), time: 0)
            flick.track(centroid: CGPoint(x: 0.5 + c.dx, y: 0.5 + c.dy),
                        velocity: CGVector(dx: c.vx, dy: c.vy), time: 0.05,
                        velocityThreshold: 0.8, axisLockRatio: 1.4)
            let out = classify(flick)
            XCTAssertNotNil(out)
            XCTAssertEqual(out?.dx, c.want.0)
            XCTAssertEqual(out?.dy, c.want.1)
        }
    }

    func testClassifierSoftScrubIsNil() {
        var flick = FlickExcursionClassifier()
        flick.begin(at: CGPoint(x: 0.5, y: 0.3), time: 0)
        // Plenty of travel, but the peak velocity never crosses the threshold — a reading-scroll.
        for i in 1...6 {
            flick.track(centroid: CGPoint(x: 0.5, y: 0.3 + CGFloat(i) * 0.05),
                        velocity: CGVector(dx: 0, dy: 0.3), time: Double(i) * 0.05,
                        velocityThreshold: 0.8, axisLockRatio: 1.4)
        }
        XCTAssertNil(classify(flick), "sub-threshold peak velocity is a SCROLL, never a flick")
    }

    func testClassifierDeceleratedLiftIsNil() {
        var flick = FlickExcursionClassifier()
        flick.begin(at: CGPoint(x: 0.5, y: 0.3), time: 0)
        // One genuinely fast frame early…
        flick.track(centroid: CGPoint(x: 0.5, y: 0.45), velocity: CGVector(dx: 0, dy: 2.0), time: 0.05,
                    velocityThreshold: 0.8, axisLockRatio: 1.4)
        // …then the fingers decelerate and linger well past the lift window before the lift.
        flick.track(centroid: CGPoint(x: 0.5, y: 0.5), velocity: CGVector(dx: 0, dy: 0.1), time: 0.4,
                    velocityThreshold: 0.8, axisLockRatio: 1.4)
        XCTAssertNil(classify(flick), "a pause before lifting means a hold/scroll, not a flick")
    }

    func testClassifierTravelUnderFloorIsNil() {
        var flick = FlickExcursionClassifier()
        flick.begin(at: CGPoint(x: 0.5, y: 0.5), time: 0)
        // Fast but tiny — a twitch, not an excursion.
        flick.track(centroid: CGPoint(x: 0.5, y: 0.55), velocity: CGVector(dx: 0, dy: 2.0), time: 0.03,
                    velocityThreshold: 0.8, axisLockRatio: 1.4)
        XCTAssertNil(classify(flick), "the travel floor gates twitches out")
    }

    func testClassifierAxisLockPicksTheDominantAxis() {
        var flick = FlickExcursionClassifier()
        flick.begin(at: CGPoint(x: 0.5, y: 0.5), time: 0)
        // Diagonal but clearly vertical-dominant (dy well over ratio × dx).
        flick.track(centroid: CGPoint(x: 0.55, y: 0.75), velocity: CGVector(dx: 0.4, dy: 2.2), time: 0.05,
                    velocityThreshold: 0.8, axisLockRatio: 1.4)
        let out = classify(flick)
        XCTAssertEqual(out?.dx, 0)
        XCTAssertEqual(out?.dy, 1, "the dominant axis wins; the resolve is axis-locked")
    }

    // MARK: - 2. Recognizer notch mode (two-finger only, falls through)

    func testNotchFastUpFlickEmitsExactlyOnce() {
        let delegate = MockDelegate()
        let r = makeRecognizer(makeSettings(), delegate: delegate)
        r.notchConversationActive = true

        r.feed(frame(2, x: 0.5, y: 0.3, t: 0))                          // begin
        r.feed(frame(2, x: 0.5, y: 0.48, vy: 2.0, t: 0.05))             // fast travel up
        r.feed(frame(0, x: 0, y: 0, t: 0.08))                           // prompt lift → flick
        r.feed(frame(0, x: 0, y: 0, t: 0.1))                            // stray re-lift → no-op

        XCTAssertEqual(delegate.notchResolves.count, 1)
        XCTAssertEqual(delegate.notchResolves.first?.dx, 0)
        XCTAssertEqual(delegate.notchResolves.first?.dy, 1)
        XCTAssertEqual(delegate.activateCount, 0, "no switcher involvement")
    }

    func testNotchSoftScrubEmitsNothing() {
        let delegate = MockDelegate()
        let r = makeRecognizer(makeSettings(), delegate: delegate)
        r.notchConversationActive = true

        r.feed(frame(2, x: 0.5, y: 0.3, t: 0))
        for i in 1...8 {                                                 // slow reading-scroll
            r.feed(frame(2, x: 0.5, y: 0.3 + CGFloat(i) * 0.04, vy: 0.3, t: Double(i) * 0.06))
        }
        r.feed(frame(0, x: 0, y: 0, t: 0.6))

        XCTAssertTrue(delegate.notchResolves.isEmpty, "soft scrolling never resolves the conversation")
    }

    func testNotchModeThreeFingerSwipeStillLatchesTheSwitcher() {
        let delegate = MockDelegate()
        let settings = makeSettings()
        let r = makeRecognizer(settings, delegate: delegate)
        r.notchConversationActive = true

        // A pure three-finger horizontal scrub — the notch mode must not swallow it.
        r.feed(frame(3, x: 0.3, y: 0.5, t: 0))
        r.feed(frame(3, x: 0.3 + CGFloat(settings.activationThreshold) + 0.02, y: 0.5, t: 0.05))
        XCTAssertEqual(delegate.activateCount, 1, "the switcher latches exactly as with no conversation open")
        XCTAssertTrue(delegate.notchResolves.isEmpty)
    }

    func testNotchTwoToThreeMorphFallsThroughToTheSwitcher() {
        let delegate = MockDelegate()
        let settings = makeSettings()
        let r = makeRecognizer(settings, delegate: delegate)
        r.notchConversationActive = true

        r.feed(frame(2, x: 0.3, y: 0.5, t: 0))                          // notch tracking begins
        r.feed(frame(3, x: 0.31, y: 0.5, t: 0.03))                      // third finger lands → falls through
        r.feed(frame(3, x: 0.31 + CGFloat(settings.activationThreshold) + 0.02, y: 0.5, t: 0.08))
        r.feed(frame(0, x: 0, y: 0, t: 0.12))

        XCTAssertEqual(delegate.activateCount, 1, "the growing gesture is handed to the switcher latch")
        XCTAssertTrue(delegate.notchResolves.isEmpty, "the abandoned flick excursion never emits")
    }

    func testCanvasModeTakesPrecedenceOverNotchMode() {
        let delegate = MockDelegate()
        let r = makeRecognizer(makeSettings(), delegate: delegate)
        r.notchConversationActive = true
        r.launcherCanvasResolutionActive = true                          // the foreground modal wins

        r.feed(frame(2, x: 0.5, y: 0.3, t: 0))
        r.feed(frame(2, x: 0.5, y: 0.48, vy: 2.0, t: 0.05))
        r.feed(frame(0, x: 0, y: 0, t: 0.08))

        XCTAssertEqual(delegate.canvasResolves.count, 1, "the canvas grammar consumed the flick")
        XCTAssertTrue(delegate.notchResolves.isEmpty)
    }

    // MARK: - 3. Audit purge (the ledger's single removal operation)

    private func record(_ s: AgentSessionID, tool: String, t: Double) -> AuditRecord {
        AuditRecord(sessionID: s, tool: tool, policy: .auto, argumentsSummary: "a",
                    outcome: .done, wasBackground: true, timestamp: Date(timeIntervalSince1970: t))
    }

    func testInMemoryPurgeRemovesOnlyTheTargetSession() {
        let log = InMemoryAuditLog(cap: 100)
        let a = AgentSessionID(); let b = AgentSessionID()
        log.record(record(a, tool: "a1", t: 1))
        log.record(record(b, tool: "b1", t: 2))
        log.record(record(a, tool: "a2", t: 3))

        log.purge(sessionID: a)
        XCTAssertEqual(log.recent(limit: 10).map(\.tool), ["b1"], "only the purged session's records vanish")
    }

    func testDiskPurgeRewritesTheFileAndSurvivesRelaunch() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-audit-purge-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit.jsonl")
        let a = AgentSessionID(); let b = AgentSessionID()
        let log = DiskAuditLog(fileURL: url, cap: 100)
        log.record(record(a, tool: "a1", t: 1))
        log.record(record(b, tool: "b1", t: 2))
        log.record(record(a, tool: "a2", t: 3))

        log.purge(sessionID: a)
        XCTAssertEqual(log.recent(limit: 10).map(\.tool), ["b1"], "the ring is purged synchronously")

        // The durable rewrite lands on the off-main writer queue — poll a fresh instance over the file.
        let deadline = Date().addingTimeInterval(3)
        var reopenedTools: [String] = []
        while Date() < deadline {
            reopenedTools = DiskAuditLog(fileURL: url, cap: 100).recent(limit: 10).map(\.tool)
            if reopenedTools == ["b1"] { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(reopenedTools, ["b1"],
                       "a relaunch (fresh instance over the same file) shows no purged-session record")
    }

    func testFailablePurgeKeepsRingPurgedAndSurfacesPersistError() {
        let log = FailableInMemoryAuditLog(cap: 100)
        let a = AgentSessionID(); let b = AgentSessionID()
        log.record(record(a, tool: "a1", t: 1))
        log.record(record(b, tool: "b1", t: 2))
        log.failPersist = true

        log.purge(sessionID: a)
        XCTAssertEqual(log.recent(limit: 10).map(\.tool), ["b1"], "the ring is purged even when persist fails")
        XCTAssertNotNil(log.lastPersistError, "the rewrite failure surfaces on the bounded channel")
    }
}
