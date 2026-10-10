import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// `keep-awake-agent-curtain`: who may act while the guard is up (InputTrustPolicy), the curtain
/// lifecycle (swallow → ONE Touch ID check → owner restores without a lock / failure locks or stays
/// curtained), the fail-closed fallback, the crash watchdog's rules, and the decode-safe item option.
/// All against fakes — no real taps, Touch ID, processes or displays.
@MainActor
final class KeepAwakeCurtainTests: XCTestCase {

    // MARK: - InputTrustPolicy

    private func policy(_ table: [pid_t: String], trusted: Set<String> = ["ai.shift.vex.desktop"]) -> InputTrustPolicy {
        InputTrustPolicy(trustedBundleIDs: trusted, selfPID: 999, resolveBundleID: { table[$0] })
    }

    func testHardwareInputIsNeverTrusted() {
        XCTAssertEqual(policy([:]).classify(sourcePID: 0), .hardware)
        XCTAssertFalse(policy([:]).classify(sourcePID: 0).isTrusted)
    }

    func testOwnProcessIsTrusted() {
        XCTAssertTrue(policy([:]).classify(sourcePID: 999).isTrusted)
    }

    func testTrustedAppHelperIsTrusted() {
        // vexcu (pid 42) resolves to its responsible app, Vex.
        XCTAssertEqual(policy([42: "ai.shift.vex.desktop"]).classify(sourcePID: 42), .trusted("ai.shift.vex.desktop"))
    }

    func testUntrustedAndUnknownSynthesizersTripTheGuard() {
        let p = policy([7: "com.example.remote"])
        XCTAssertEqual(p.classify(sourcePID: 7), .untrusted("com.example.remote"))
        XCTAssertEqual(p.classify(sourcePID: 8), .untrusted(nil), "unresolvable PID fails closed")
    }

    func testUserAddedAppBecomesTrusted() {
        let p = policy([7: "com.example.remote"], trusted: ["ai.shift.vex.desktop", "com.example.remote"])
        XCTAssertTrue(p.classify(sourcePID: 7).isTrusted)
    }

    // MARK: - Curtain fakes

    private final class Rec {
        var sequence: [String] = []
        var onIntrusion: ((String) -> Void)?
        var curtainAvailable = true
        var authStarts = 0
        var authAllowPassword: [Bool] = []
        var authCompletion: ((GuardAuthResult) -> Void)?
        var authStartResult = (started: true, needsPassThrough: false)
        var passThrough: [Bool] = []
        var watchdogStarts = 0
        var watchdogStops = 0
        var notes: [String] = []
        var monitorInput: (() -> Void)?
        var clock: TimeInterval = 1000
        // Silent listener fakes (nil-by-default = no Touch ID: the visible-prompt path).
        var listenerAvailable = false
        var listenerResult: ((SilentOwnerListener.Result) -> Void)?
        var attends = 0
        var pauses: [Bool] = []
        var listenerEnds = 0
        var listenerPasswordMode: [Bool] = []
        var pending: [(TimeInterval, () -> Void)] = []
    }

    private func effects(_ r: Rec) -> KeepAwakeController.Effects {
        var e = KeepAwakeController.Effects(
            activeDisplays: { [1] },
            getBrightness: { _ in 0.7 },
            setBrightness: { id, _ in r.sequence.append("display(\(id))") },
            beginActivity: { NSObject() },
            endActivity: { _ in r.sequence.append("endActivity") },
            declareUserActive: {})
        e.lockScreen = { r.sequence.append("lock") }
        e.beginInputMonitoring = { cb in r.monitorInput = cb; r.sequence.append("monitor"); return NSObject() }
        e.endInputMonitoring = { _ in r.sequence.append("endMonitor") }
        e.beginCurtain = { cb in
            guard r.curtainAvailable else { return nil }
            r.onIntrusion = cb; r.sequence.append("curtain"); return NSObject()
        }
        e.endCurtain = { _ in r.sequence.append("endCurtain") }
        e.setCurtainPassThrough = { _, on in r.passThrough.append(on) }
        e.authenticate = { allow, completion in
            r.authStarts += 1; r.authAllowPassword.append(allow); r.authCompletion = completion
            return r.authStartResult
        }
        e.cancelAuthentication = { r.sequence.append("cancelAuth") }
        e.startWatchdog = { r.watchdogStarts += 1; return true }
        e.stopWatchdog = { r.watchdogStops += 1; r.sequence.append("endWatchdog") }
        e.notify = { ev, _ in r.notes.append(ev) }
        e.now = { r.clock }
        e.beginListener = { pw, cb in
            guard r.listenerAvailable else { return nil }
            r.listenerPasswordMode.append(pw)
            r.listenerResult = cb; r.sequence.append("listener"); return NSObject()
        }
        e.endListener = { _ in r.listenerEnds += 1; r.sequence.append("endListener") }
        e.attendListener = { _ in r.attends += 1 }
        e.pauseListener = { _, on in r.pauses.append(on) }
        e.after = { delay, block in r.pending.append((delay, block)) }
        return e
    }

    /// Start + arm (the triggering gesture lifts) so the guard is installed.
    private func armed(_ r: Rec, lock: Bool = false, curtain: Bool = true) -> KeepAwakeController {
        let c = KeepAwakeController(effects: effects(r), heartbeatInterval: 1_000_000)
        c.start(.init(dimLevel: 0, dimKeyboard: false, lockOnStop: lock, curtain: curtain))
        c.noteTouch(fingerCount: 0)
        return c
    }

    // MARK: - Curtain lifecycle

    func testArmInstallsCurtainAndWatchdogNotThePassiveMonitor() {
        let r = Rec()
        let c = armed(r)
        XCTAssertTrue(c.isCurtained)
        XCTAssertEqual(r.watchdogStarts, 1)
        XCTAssertFalse(r.sequence.contains("monitor"), "the passive monitor is only the fallback")
        c.stop()
    }

    func testCurtainIsNotInstalledBeforeArming() {
        let r = Rec()
        let c = KeepAwakeController(effects: effects(r), heartbeatInterval: 1_000_000)
        c.start(.init(curtain: true))
        c.noteTouch(fingerCount: 3)          // the firing gesture is still down
        XCTAssertFalse(c.isCurtained)
        c.stop()
    }

    func testIntrusionOpensExactlyOneOwnerCheck() {
        let r = Rec()
        let c = armed(r)
        r.onIntrusion?("keyDown from hardware")
        r.onIntrusion?("mouseMoved from hardware")
        c.noteTouch(fingerCount: 1)
        XCTAssertEqual(r.authStarts, 1, "one prompt at a time")
        XCTAssertEqual(r.notes, ["intrusion"], "the hook hears the first intrusion once")
        XCTAssertTrue(c.isActive, "a swallowed input never ends the session by itself")
        c.stop()
    }

    func testTrackpadContactBehindCurtainAsksInsteadOfStopping() {
        // The Touch ID complaint: a palm on the trackpad while reaching for Touch ID must not lock.
        let r = Rec()
        let c = armed(r, lock: true, curtain: false)
        c.noteTouch(fingerCount: 1)
        XCTAssertTrue(c.isActive)
        XCTAssertFalse(r.sequence.contains("lock"))
        XCTAssertEqual(r.authStarts, 1)
        c.stop()
    }

    func testOwnerTouchIDRestoresWithoutLocking() {
        let r = Rec()
        let c = armed(r, lock: true, curtain: false)
        r.onIntrusion?("type14 from hardware")      // the Touch ID / power button press
        r.authCompletion?(.success)
        XCTAssertFalse(c.isActive)
        XCTAssertFalse(r.sequence.contains("lock"), "the owner never meets the lock screen")
        XCTAssertTrue(r.sequence.contains("endCurtain"))
        XCTAssertEqual(r.watchdogStops, 1, "clean stop disarms the watchdog")
        XCTAssertEqual(r.notes, ["intrusion", "auth-ok"])
    }

    func testLockModeFailureLocksBeforeCurtainAndRestore() {
        let r = Rec()
        let c = armed(r, lock: true, curtain: false)
        r.onIntrusion?("keyDown from hardware")
        r.authCompletion?(.failure)
        XCTAssertFalse(c.isActive)
        let lock = r.sequence.firstIndex(of: "lock")!
        XCTAssertLessThan(lock, r.sequence.firstIndex(of: "endCurtain")!, "no gap between curtain and lock")
        XCTAssertLessThan(lock, r.sequence.lastIndex(of: "display(1)")!, "lock before restore (no flash)")
        XCTAssertEqual(r.notes, ["intrusion", "auth-failed"])
    }

    func testCurtainModeFailureStaysCurtainedWithCooldown() {
        let r = Rec()
        let c = armed(r)
        r.onIntrusion?("keyDown from hardware")
        r.authCompletion?(.failure)
        XCTAssertTrue(c.isActive)
        XCTAssertTrue(c.isCurtained)
        XCTAssertFalse(r.sequence.contains("lock"))
        r.onIntrusion?("keyDown from hardware")
        XCTAssertEqual(r.authStarts, 1, "cooldown: a resting palm can't loop the prompt")
        r.clock += KeepAwakeController.authCooldown + 0.1
        r.onIntrusion?("keyDown from hardware")
        XCTAssertEqual(r.authStarts, 2)
        c.stop()
    }

    func testPasswordFallbackOnlyInCurtainModeAndPassThroughIsBounded() {
        let r = Rec()
        r.authStartResult = (true, true)              // no biometrics → password prompt needs keys
        let c = armed(r)
        r.onIntrusion?("keyDown from hardware")
        XCTAssertEqual(r.authAllowPassword, [true])
        XCTAssertEqual(r.passThrough, [true])
        r.authCompletion?(.failure)
        XCTAssertEqual(r.passThrough, [true, false], "the curtain closes again when the check ends")
        c.stop()

        let r2 = Rec()
        let c2 = armed(r2, lock: true, curtain: false)
        r2.onIntrusion?("keyDown from hardware")
        XCTAssertEqual(r2.authAllowPassword, [false], "lock mode: the real lock screen handles passwords")
        c2.stop()
    }

    func testCheckThatCannotStartCountsAsFailure() {
        let r = Rec()
        r.authStartResult = (false, false)            // no biometrics, password not allowed
        let c = armed(r, lock: true, curtain: false)
        r.onIntrusion?("keyDown from hardware")
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(r.sequence.contains("lock"))
    }

    func testCurtainUnavailableFallsBackToMonitorAndFailsClosed() {
        let r = Rec()
        r.curtainAvailable = false                    // no Accessibility → no tap
        let c = armed(r)                              // curtain wanted, lockOnStop off
        XCTAssertFalse(c.isCurtained)
        XCTAssertTrue(r.sequence.contains("monitor"))
        XCTAssertEqual(r.watchdogStarts, 0)
        r.monitorInput?()
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(r.sequence.contains("lock"), "never leave the Mac open when the curtain is missing")
    }

    func testExplicitStopMidCheckCancelsItAndNeverLocks() {
        let r = Rec()
        let c = armed(r, lock: true, curtain: false)
        r.onIntrusion?("keyDown from hardware")
        c.stop(reason: .explicit)
        XCTAssertTrue(r.sequence.contains("cancelAuth"))
        XCTAssertFalse(r.sequence.contains("lock"))
        r.authCompletion?(.failure)                   // a late answer after stop is ignored
        XCTAssertFalse(r.sequence.contains("lock"))
    }

    func testUnguardedSessionInstallsNothing() {
        let r = Rec()
        let c = armed(r, lock: false, curtain: false)
        XCTAssertFalse(c.isCurtained)
        XCTAssertFalse(r.sequence.contains("monitor"))
        c.noteTouch(fingerCount: 1)
        XCTAssertFalse(c.isActive, "plain Keep Awake: first touch ends it")
    }

    // MARK: - Silent Touch ID (keep-awake-silent-touch-id)

    private func silent(lock: Bool = false, curtain: Bool = true) -> (Rec, KeepAwakeController) {
        let r = Rec()
        r.listenerAvailable = true
        return (r, armed(r, lock: lock, curtain: curtain))
    }

    func testArmStartsTheSilentListenerBehindTheCurtain() {
        let (r, c) = silent()
        XCTAssertEqual(r.sequence.filter { $0 == "listener" }.count, 1)
        c.stop()
        XCTAssertEqual(r.listenerEnds, 1)
    }

    func testCurtainModeListenerHandlesWrongFingerWithBlindPasswordLockModeDoesNot() {
        let (r, c) = silent()
        XCTAssertEqual(r.listenerPasswordMode, [true], "Curtain: password entry lives in the listener")
        c.stop()
        let (r2, c2) = silent(lock: true, curtain: false)
        XCTAssertEqual(r2.listenerPasswordMode, [false], "Lock: a wrong finger locks")
        c2.stop()
    }

    func testPersonInputShowsNoPromptOnlyAttends() {
        // The owner's complaint: a touch on the trackpad or keyboard must not raise the prompt.
        let (r, c) = silent()
        r.onIntrusion?("keyDown from hardware")
        c.noteTouch(fingerCount: 2)
        r.onIntrusion?("mouseDown from hardware")
        XCTAssertEqual(r.authStarts, 0, "no visible message for a stranger")
        XCTAssertEqual(r.attends, 1, "a burst of touches hands focus over ONCE (throttled)")
        XCTAssertEqual(r.notes, ["intrusion"])
        XCTAssertTrue(c.isActive)
        XCTAssertTrue(r.pending.isEmpty, "Curtain mode has no deadline")
        c.stop()
    }

    func testInputStormNeverDrivesPerEventFocusWork() {
        // Perf audit 2026-10-10: per-event re-focus leaked thousands of text-cursor indicators and
        // pinned WindowServer. 1,000 swallowed events in under a second → at most one attend.
        let (r, c) = silent()
        for i in 0..<1000 {
            r.clock = 1000 + Double(i) * 0.0009
            r.onIntrusion?("mouseMoved from hardware")
        }
        XCTAssertEqual(r.attends, 1)
        r.clock += KeepAwakeController.attendInterval
        r.onIntrusion?("mouseMoved from hardware")
        XCTAssertEqual(r.attends, 2, "a person still touching gets focus re-checked once per interval")
        c.stop()
    }

    func testOwnerFingerEndsTheSessionSilentlyWithoutLock() {
        let (r, c) = silent(lock: true, curtain: false)
        r.listenerResult?(.success)                    // a finger alone, no prior touch
        XCTAssertFalse(c.isActive)
        XCTAssertFalse(r.sequence.contains("lock"))
        XCTAssertEqual(r.authStarts, 0)
        XCTAssertEqual(r.notes, ["auth-ok"])
    }

    func testUnrecognizedFingerOpensPromptWithPasswordInCurtainMode() {
        let (r, c) = silent()
        r.authStartResult = (true, true)
        r.listenerResult?(.failed)
        XCTAssertEqual(r.authAllowPassword, [true], "the prompt offers the password")
        XCTAssertEqual(r.passThrough, [true], "the owner can type into the prompt")
        XCTAssertEqual(r.pauses, [true], "the listener yields focus to the prompt")
        r.authCompletion?(.success)
        XCTAssertFalse(c.isActive)
        XCTAssertFalse(r.sequence.contains("lock"))
    }

    func testPasswordPromptFailureResumesSilentListening() {
        let (r, c) = silent()
        r.authStartResult = (true, true)
        r.listenerResult?(.failed)
        r.authCompletion?(.failure)
        XCTAssertTrue(c.isActive)
        XCTAssertEqual(r.passThrough, [true, false])
        XCTAssertEqual(r.pauses, [true, false])
        c.stop()
    }

    func testUnrecognizedFingerLocksInLockMode() {
        let (r, c) = silent(lock: true, curtain: false)
        r.listenerResult?(.failed)
        XCTAssertFalse(c.isActive)
        XCTAssertEqual(r.authStarts, 0)
        let lock = r.sequence.firstIndex(of: "lock")!
        XCTAssertLessThan(lock, r.sequence.firstIndex(of: "endCurtain")!)
        XCTAssertLessThan(r.sequence.firstIndex(of: "endListener")!, lock, "focus is handed back before the lock")
    }

    func testLockModeSilentDeadlineLocks() {
        let (r, c) = silent(lock: true, curtain: false)
        r.onIntrusion?("keyDown from hardware")
        r.onIntrusion?("keyDown from hardware")
        XCTAssertEqual(r.pending.count, 1, "one deadline per session")
        XCTAssertEqual(r.pending.first?.0, KeepAwakeController.authTimeout)
        r.pending.first?.1()
        XCTAssertFalse(c.isActive)
        XCTAssertTrue(r.sequence.contains("lock"))
    }

    func testDeadlineAfterOwnerFingerIsIgnored() {
        let (r, c) = silent(lock: true, curtain: false)
        r.onIntrusion?("keyDown from hardware")
        r.listenerResult?(.success)
        r.pending.first?.1()
        XCTAssertFalse(c.isActive)
        XCTAssertFalse(r.sequence.contains("lock"), "a stale deadline never locks the owner")
    }

    func testListenerResultAfterStopIsIgnored() {
        let (r, c) = silent()
        c.stop()
        r.listenerResult?(.failed)
        XCTAssertEqual(r.authStarts, 0)
        XCTAssertFalse(r.sequence.contains("lock"))
    }


    func testNoMatchWatcherFiresOncePerNoMatchLine() {
        var hits = 0
        let w = NoMatchWatcher { hits += 1 }
        w.consume("Filtering the log data using \"process == \"coreauthd\" AND composedMessage CONTAINS \"received no-match\"\"\n")
        w.consume("2026-10-10 20:03:55.116 Df coreauthd[955:aa839] [com.apple.LocalAuthentication:Server] MechanismTouchId[378](run) has received no-")
        XCTAssertEqual(hits, 0, "the stream's banner echoes the predicate and must not count; a split line waits")
        w.consume("match from <private> (lockout state:1)\n2026-10-10 20:04:04 Df coreauthd[955] has matched by <private>\n")
        XCTAssertEqual(hits, 1)
    }

    // MARK: - Watchdog rules

    func testWatchdogArgParsing() {
        XCTAssertNil(CurtainWatchdog.parse(["app"]))
        XCTAssertNil(CurtainWatchdog.parse(["app", "--curtain-watchdog", "1", "/m"]), "pid 1 refused")
        XCTAssertNil(CurtainWatchdog.parse(["app", "--curtain-watchdog", "123"]))
        let p = CurtainWatchdog.parse(["app", "--curtain-watchdog", "123", "/tmp/m"])
        XCTAssertEqual(p?.pid, 123)
        XCTAssertEqual(p?.marker, "/tmp/m")
    }

    func testWatchdogVerdicts() {
        XCTAssertEqual(CurtainWatchdog.verdict(ownerAlive: true, markerPresent: true), .keepWatching)
        XCTAssertEqual(CurtainWatchdog.verdict(ownerAlive: false, markerPresent: true), .lockAndExit)
        XCTAssertEqual(CurtainWatchdog.verdict(ownerAlive: true, markerPresent: false), .exitQuietly)
        XCTAssertEqual(CurtainWatchdog.verdict(ownerAlive: false, markerPresent: false), .exitQuietly,
                       "a clean stop removed the marker: never lock")
    }

    // MARK: - Item model

    func testGuardModeMapping() {
        XCTAssertEqual(KeepAwakeGuardMode(lockOnStop: false, curtain: false), .off)
        XCTAssertEqual(KeepAwakeGuardMode(lockOnStop: true, curtain: false), .lock)
        XCTAssertEqual(KeepAwakeGuardMode(lockOnStop: false, curtain: true), .curtain)
        XCTAssertEqual(KeepAwakeGuardMode(lockOnStop: true, curtain: true), .lock, "lock wins")
    }

    func testCurtainOptionRoundTripsAndLegacyDecodesToNil() throws {
        let item = LaunchItem(title: "Keep Awake", icon: .sfSymbol("cup.and.saucer.fill"),
                              kind: .automation(.keepAwake, dimPercent: 0, curtain: true))
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)

        let legacy = LaunchItem(title: "Keep Awake", icon: .sfSymbol("cup.and.saucer.fill"),
                                kind: .automation(.keepAwake, dimPercent: 0, lockOnStop: true))
        let back = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(legacy))
        guard case let .automation(_, _, _, lock, curtain) = back.kind else { return XCTFail() }
        XCTAssertEqual(lock, true)
        XCTAssertNil(curtain, "a pre-curtain record decodes with the curtain off")
    }

    func testTrustedAppsDefaultIsVex() {
        XCTAssertEqual(AppSettings.Defaults.keepAwakeTrustedApps, ["ai.shift.vex.desktop"])
    }
}
