import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure switchability filter (Windows/WindowFilter.swift) — the
/// refine-window-filtering change: strict parity with the historical gate, the relaxed three-tier
/// gate (allowlist / denylist / real-window discriminators), the degenerate floor, per-app rules,
/// and phantom-duplicate suppression.
final class WindowFilterTests: XCTestCase {

    // MARK: - Fixtures

    private let windowRole = kAXWindowRole as String
    private let standard = kAXStandardWindowSubrole as String
    private let dialog = kAXDialogSubrole as String
    private let systemDialog = kAXSystemDialogSubrole as String
    private let floating = kAXFloatingWindowSubrole as String
    private let systemFloating = kAXSystemFloatingWindowSubrole as String
    private let unknown = kAXUnknownSubrole as String

    private func candidate(role: String? = kAXWindowRole as String,
                           subrole: String? = nil,
                           title: String? = nil,
                           size: CGSize = CGSize(width: 800, height: 600),
                           hasCloseButton: Bool = false,
                           isMinimized: Bool = false) -> WindowCandidate {
        WindowCandidate(role: role, subrole: subrole, title: title, size: size,
                        hasCloseButton: hasCloseButton, isMinimized: isMinimized)
    }

    private let strictPolicy = WindowFilterPolicy(relaxed: false, includeMinimized: false)
    private let relaxedPolicy = WindowFilterPolicy(relaxed: true, includeMinimized: false)

    // MARK: - Strict mode: byte-identical to the historical gate

    func testStrictListsStandardSubrole() {
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: standard), policy: strictPolicy), .listed)
    }

    func testStrictListsMissingSubrole() {
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: nil), policy: strictPolicy), .listed)
    }

    func testStrictDropsNonStandardSubrole() {
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: dialog), policy: strictPolicy),
                       .dropped(.nonStandardSubrole))
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: unknown), policy: strictPolicy),
                       .dropped(.nonStandardSubrole))
    }

    func testStrictIgnoresSizeTitleAndChrome() {
        // Strict never size-gated — a tiny standard window lists (historical behavior).
        let tiny = candidate(subrole: standard, title: nil, size: CGSize(width: 30, height: 30))
        XCTAssertEqual(WindowFilter.verdict(tiny, policy: strictPolicy), .listed)
    }

    func testNonWindowRoleDropsEverywhere() {
        let sheet = candidate(role: "AXSheet", subrole: standard)
        XCTAssertEqual(WindowFilter.verdict(sheet, policy: strictPolicy), .dropped(.notAWindow))
        XCTAssertEqual(WindowFilter.verdict(sheet, policy: relaxedPolicy), .dropped(.notAWindow))
    }

    func testMinimizedGateFollowsOptIn() {
        let min = candidate(subrole: standard, isMinimized: true)
        XCTAssertEqual(WindowFilter.verdict(min, policy: strictPolicy), .dropped(.minimized))
        let optIn = WindowFilterPolicy(relaxed: false, includeMinimized: true)
        XCTAssertEqual(WindowFilter.verdict(min, policy: optIn), .listed)
    }

    // MARK: - Relaxed mode: monotonic over strict (the Finder copy-progress regression)

    func testRelaxedListsSmallStandardWindow() {
        // The root bug: a 430×90 standard-subrole window (Finder's copy progress) was DROPPED by the
        // old relaxed gate (both dims ≥ 100) even though strict mode listed it. Tier 1 fixes this.
        let progress = candidate(subrole: standard, title: "Copying…",
                                 size: CGSize(width: 430, height: 90), hasCloseButton: true)
        XCTAssertEqual(WindowFilter.verdict(progress, policy: relaxedPolicy), .listed)
    }

    func testRelaxedListsEverythingStrictLists() {
        // Monotonicity sweep: any candidate strict lists, relaxed lists too.
        let strictListed: [WindowCandidate] = [
            candidate(subrole: standard),
            candidate(subrole: nil),
            candidate(subrole: standard, size: CGSize(width: 430, height: 90)),
            candidate(subrole: nil, title: "Prefs", size: CGSize(width: 300, height: 80), hasCloseButton: true),
        ]
        for c in strictListed where WindowFilter.verdict(c, policy: strictPolicy) == .listed {
            XCTAssertEqual(WindowFilter.verdict(c, policy: relaxedPolicy), .listed,
                           "relaxed dropped a window strict lists: \(c)")
        }
    }

    func testRelaxedListsDialogs() {
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: dialog), policy: relaxedPolicy), .listed)
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: systemDialog), policy: relaxedPolicy), .listed)
    }

    func testRelaxedDropsFloatingPalettes() {
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: floating), policy: relaxedPolicy),
                       .dropped(.junkSubrole))
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: systemFloating), policy: relaxedPolicy),
                       .dropped(.junkSubrole))
    }

    // MARK: - Relaxed tier 3: the discriminators

    func testEmulatorToolbarStillDrops() {
        // The case the old scalar was calibrated on: 61×515, empty title, no chrome, unknown subrole.
        let toolbar = candidate(subrole: unknown, title: "", size: CGSize(width: 61, height: 515))
        XCTAssertEqual(WindowFilter.verdict(toolbar, policy: relaxedPolicy), .dropped(.phantom))
    }

    func testAirDropPhantomCloneDrops() {
        // Live-probed 2026-07-19: one AirDrop share births three Finder-owned untitled chromeless
        // clones at the host window's exact 316×601 frame, lingering after dismissal. Size must
        // never admit an identity-less window — this is the regression that killed the size signal.
        let clone = candidate(subrole: unknown, title: "", size: CGSize(width: 316, height: 601))
        XCTAssertEqual(WindowFilter.verdict(clone, policy: relaxedPolicy), .dropped(.phantom))
    }

    func testTitledEmulatorDeviceWindowLists() {
        // The emulator's real windows carry titles ("Android Emulator - Pixel_10_Pro:5554") — the
        // title discriminator covers them without any size signal. A truly titleless real window is
        // recovered via the per-app include rule, not a size guess.
        let device = candidate(subrole: unknown, title: "Android Emulator - Pixel_10_Pro:5554",
                               size: CGSize(width: 372, height: 700))
        XCTAssertEqual(WindowFilter.verdict(device, policy: relaxedPolicy), .listed)
        let untitledBig = candidate(subrole: unknown, title: "", size: CGSize(width: 372, height: 700))
        XCTAssertEqual(WindowFilter.verdict(untitledBig, policy: relaxedPolicy), .dropped(.phantom),
                       "untitled + chromeless is phantom regardless of size")
    }

    func testMissingSubroleListsUntitled() {
        // Strict lists a no-subrole window unconditionally — relaxed must too (monotonicity), even
        // untitled and chromeless.
        let bare = candidate(subrole: nil, title: "", size: CGSize(width: 200, height: 200))
        XCTAssertEqual(WindowFilter.verdict(bare, policy: strictPolicy), .listed)
        XCTAssertEqual(WindowFilter.verdict(bare, policy: relaxedPolicy), .listed)
    }

    func testTitledSmallUnknownWindowLists() {
        let titled = candidate(subrole: unknown, title: "Progress", size: CGSize(width: 300, height: 70))
        XCTAssertEqual(WindowFilter.verdict(titled, policy: relaxedPolicy), .listed)
    }

    func testWhitespaceTitleDoesNotCountAsTitled() {
        let blank = candidate(subrole: unknown, title: "  \n", size: CGSize(width: 500, height: 500))
        XCTAssertEqual(WindowFilter.verdict(blank, policy: relaxedPolicy), .dropped(.phantom))
    }

    func testChromedSmallUnknownWindowLists() {
        let chromed = candidate(subrole: unknown, title: nil,
                                size: CGSize(width: 90, height: 90), hasCloseButton: true)
        XCTAssertEqual(WindowFilter.verdict(chromed, policy: relaxedPolicy), .listed)
    }

    func testDegenerateSliverDropsEvenWithTitle() {
        let sliver = candidate(subrole: unknown, title: "x", size: CGSize(width: 800, height: 10))
        XCTAssertEqual(WindowFilter.verdict(sliver, policy: relaxedPolicy), .dropped(.degenerateSize))
    }

    // MARK: - Per-app rules

    func testExcludeRuleDropsEverything() {
        let pol = WindowFilterPolicy(relaxed: true, includeMinimized: true, appRule: .exclude)
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: standard), policy: pol),
                       .dropped(.appExcluded))
    }

    func testIncludeRuleBypassesHeuristics() {
        let pol = WindowFilterPolicy(relaxed: false, includeMinimized: false, appRule: .include)
        // Untitled, chromeless, small, unknown subrole — phantom by heuristics, listed by rule.
        let phantom = candidate(subrole: unknown, title: "", size: CGSize(width: 61, height: 515))
        XCTAssertEqual(WindowFilter.verdict(phantom, policy: pol), .listed)
        // But the degenerate floor still applies.
        let sliver = candidate(subrole: unknown, size: CGSize(width: 5, height: 500))
        XCTAssertEqual(WindowFilter.verdict(sliver, policy: pol), .dropped(.degenerateSize))
        // And a non-window role still drops.
        XCTAssertEqual(WindowFilter.verdict(candidate(role: "AXSheet"), policy: pol), .dropped(.notAWindow))
    }

    func testStrictRuleOverridesRelaxedGlobal() {
        let pol = WindowFilterPolicy(relaxed: true, includeMinimized: false, appRule: .strict)
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: unknown, title: "Real"), policy: pol),
                       .dropped(.nonStandardSubrole))
        XCTAssertEqual(WindowFilter.verdict(candidate(subrole: standard), policy: pol), .listed)
    }

    // MARK: - Phantom-duplicate suppression

    private struct Row {
        let pid: pid_t
        let title: String?
        let frame: CGRect
        let minimized: Bool
        let rank: Int
    }

    private func dedupe(_ rows: [Row], exempt: Set<pid_t> = []) -> [Row] {
        WindowFilter.dedupe(rows, exemptPids: exempt,
                            key: { WindowFilter.DedupeKey(pid: $0.pid, title: $0.title,
                                                          frame: $0.frame, isMinimized: $0.minimized) },
                            rank: { $0.rank })
    }

    func testClonesCollapseToFrontmost() {
        // The AirDrop case: four identical Finder-owned windows — one survivor, the lowest z.
        let frame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let rows = (0..<4).map { Row(pid: 42, title: "AirDrop", frame: frame, minimized: false, rank: 10 - $0) }
        let out = dedupe(rows)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rank, 7)
    }

    func testDistinctTitlesKept() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let rows = [Row(pid: 1, title: "Doc A", frame: frame, minimized: false, rank: 0),
                    Row(pid: 1, title: "Doc B", frame: frame, minimized: false, rank: 1)]
        XCTAssertEqual(dedupe(rows).count, 2, "two maximized windows with different titles both list")
    }

    func testDistinctFramesKept() {
        let rows = [Row(pid: 1, title: "Same", frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: false, rank: 0),
                    Row(pid: 1, title: "Same", frame: CGRect(x: 20, y: 0, width: 800, height: 600), minimized: false, rank: 1)]
        XCTAssertEqual(dedupe(rows).count, 2)
    }

    func testCrossAppClonesKept() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let rows = [Row(pid: 1, title: "Same", frame: frame, minimized: false, rank: 0),
                    Row(pid: 2, title: "Same", frame: frame, minimized: false, rank: 1)]
        XCTAssertEqual(dedupe(rows).count, 2)
    }

    func testMinimizedStateSplitsIdentity() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let rows = [Row(pid: 1, title: "Same", frame: frame, minimized: false, rank: 0),
                    Row(pid: 1, title: "Same", frame: frame, minimized: true, rank: 1)]
        XCTAssertEqual(dedupe(rows).count, 2)
    }

    func testExemptPidBypassesDedup() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let rows = (0..<3).map { Row(pid: 9, title: "Clone", frame: frame, minimized: false, rank: $0) }
        XCTAssertEqual(dedupe(rows, exempt: [9]).count, 3)
    }

    func testZeroFramesNeverCollapse() {
        // A frame that did not resolve carries no identity — two unreadable off-Space windows of the
        // same app must never merge into one.
        let rows = [Row(pid: 1, title: "", frame: .zero, minimized: false, rank: 0),
                    Row(pid: 1, title: "", frame: .zero, minimized: false, rank: 1)]
        XCTAssertEqual(dedupe(rows).count, 2)
    }

    func testSurvivorOrderPreserved() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        let rows = [Row(pid: 1, title: "A", frame: frame, minimized: false, rank: 0),
                    Row(pid: 2, title: "B", frame: CGRect(x: 50, y: 50, width: 300, height: 200), minimized: false, rank: 1),
                    Row(pid: 1, title: "A", frame: frame, minimized: false, rank: 2)]
        let out = dedupe(rows)
        XCTAssertEqual(out.map(\.rank), [0, 1], "order-preserving; the rank-2 clone dropped")
    }
}

/// Persistence tests for the per-app rules dictionary (`AppSettings.windowAppRules`), following the
/// isolated-suite pattern of `AppSettingsTests`.
@MainActor
final class WindowAppRulesSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WindowAppRulesSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsEmpty() {
        XCTAssertTrue(AppSettings(defaults: defaults).windowAppRules.isEmpty)
        XCTAssertTrue(AppSettings.Defaults.windowAppRules.isEmpty)
    }

    func testRoundTripPersistence() {
        let writer = AppSettings(defaults: defaults)
        writer.windowAppRules = ["com.apple.finder": .include, "qemu-system-aarch64": .exclude]
        let reader = AppSettings(defaults: defaults)
        XCTAssertEqual(reader.windowAppRules["com.apple.finder"], .include)
        XCTAssertEqual(reader.windowAppRules["qemu-system-aarch64"], .exclude)
        XCTAssertEqual(reader.windowAppRules.count, 2)
    }

    func testSubscriptMutationPersists() {
        let writer = AppSettings(defaults: defaults)
        writer.windowAppRules["com.example.app"] = .strict
        writer.windowAppRules.removeValue(forKey: "missing")
        XCTAssertEqual(AppSettings(defaults: defaults).windowAppRules["com.example.app"], .strict)
    }

    func testResetClearsRules() {
        let settings = AppSettings(defaults: defaults)
        settings.windowAppRules = ["com.example.app": .exclude]
        settings.resetToDefaults()
        XCTAssertTrue(settings.windowAppRules.isEmpty)
        XCTAssertTrue(AppSettings(defaults: defaults).windowAppRules.isEmpty, "reset persists")
    }
}
