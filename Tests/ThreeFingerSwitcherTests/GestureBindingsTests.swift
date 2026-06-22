import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `GestureBindings` model (Gesture/GestureBindings.swift) and its persistence
/// through `AppSettings`.
///
/// Covers: defaults reproduce today's mapping for all three surfaces; `assigning(...)` swaps on conflict
/// and never double-maps an excursion; reserved excursions are absent from the vocabularies; and the
/// `reverseDirection` / `reverseVerticalDirection` accessors round-trip through the switcher binding.
final class GestureBindingsTests: XCTestCase {

    // MARK: - Defaults reproduce today's behavior

    /// The AI canvas default is exactly today's hardcoded mapping: down = commit, horizontal = dismiss
    /// (bound to left), up = ignore.
    func testCanvasDefaultsMatchTodaysMapping() {
        let c = GestureBindings.CanvasBinding.default
        XCTAssertEqual(c.commit, .swipeDown, "default down = commit")
        XCTAssertEqual(c.dismiss, .swipeLeft, "default horizontal (left) = dismiss")
        XCTAssertEqual(c.ignore, .swipeUp, "default up = ignore")
    }

    /// The Files-drill default is exactly today's mapping: lift = open, +1-finger = Open-With,
    /// four-finger horizontal = discard.
    func testFilesDrillDefaultsMatchTodaysMapping() {
        let f = GestureBindings.FilesDrillBinding.default
        XCTAssertEqual(f.open, .lift, "default lift = open")
        XCTAssertEqual(f.openWith, .plusOneFingerLift, "default +1-finger = Open-With")
        XCTAssertEqual(f.discard, .fourFingerHorizontal, "default four-finger horizontal = discard")
    }

    /// The switcher default is both axes normal (no reversal) — exactly today's behavior.
    func testSwitcherDefaultsAreBothAxesNormal() {
        let s = GestureBindings.SwitcherBinding.default
        XCTAssertEqual(s.windowsAxis, .normal)
        XCTAssertEqual(s.spacesAxis, .normal)
        XCTAssertFalse(s.windowsAxis.isReversed)
        XCTAssertFalse(s.spacesAxis.isReversed)
    }

    /// The aggregate default wires all three surfaces to their per-surface defaults.
    func testAggregateDefaultComposesPerSurfaceDefaults() {
        let g = GestureBindings.default
        XCTAssertEqual(g.canvas, .default)
        XCTAssertEqual(g.filesDrill, .default)
        XCTAssertEqual(g.switcher, .default)
    }

    // MARK: - Reserved / invalid excursions are absent from the vocabularies

    /// Single-finger motion and the canvas's sub-threshold two-finger scroll are never bindable — the
    /// canvas vocabulary is exactly the four two-finger swipe excursions, nothing else.
    func testCanvasVocabularyExcludesReservedExcursions() {
        let all = Set(GestureBindings.CanvasExcursion.allCases.map(\.rawValue))
        XCTAssertEqual(all, ["swipeUp", "swipeDown", "swipeLeft", "swipeRight"])
        // No single-finger / scroll/read member exists.
        XCTAssertFalse(all.contains { $0.lowercased().contains("single") })
        XCTAssertFalse(all.contains { $0.lowercased().contains("scroll") })
        XCTAssertFalse(all.contains { $0.lowercased().contains("read") })
        XCTAssertFalse(all.contains { $0.lowercased().contains("pan") })
    }

    /// The Files-drill vocabulary is exactly its three excursions; single-finger is not a member.
    func testFilesVocabularyExcludesReservedExcursions() {
        let all = Set(GestureBindings.FilesExcursion.allCases.map(\.rawValue))
        XCTAssertEqual(all, ["lift", "plusOneFingerLift", "fourFingerHorizontal"])
        XCTAssertFalse(all.contains { $0.lowercased().contains("single") })
    }

    // MARK: - Canvas: assign swaps on conflict, never double-maps

    /// Assigning a taken excursion swaps the two actions so the mapping stays one-to-one. Spec scenario:
    /// swipe-down is bound to commit; assigning swipe-down to dismiss makes commit inherit dismiss's old
    /// excursion (no excursion maps to two actions).
    func testCanvasAssignSwapsOnConflict() {
        let c = GestureBindings.CanvasBinding.default   // commit=down, dismiss=left, ignore=up
        let r = c.assigning(.swipeDown, to: .dismiss)

        XCTAssertEqual(r.dismiss, .swipeDown, "dismiss now holds the requested excursion")
        XCTAssertEqual(r.commit, .swipeLeft, "commit inherited dismiss's former excursion (the swap)")
        XCTAssertEqual(r.ignore, .swipeUp, "the uninvolved action is untouched")
        assertCanvasOneToOne(r)
    }

    /// Assigning the excursion an action already holds is a no-op (returns an equal binding).
    func testCanvasAssignSameExcursionIsNoOp() {
        let c = GestureBindings.CanvasBinding.default
        XCTAssertEqual(c.assigning(.swipeDown, to: .commit), c)
    }

    /// Assigning the spare (4th) excursion — not held by any action — moves it to the target without a
    /// swap, leaving the previously-held excursion now spare; the mapping stays one-to-one.
    func testCanvasAssignSpareExcursionLeavesNoConflict() {
        let c = GestureBindings.CanvasBinding.default   // right is the spare
        let r = c.assigning(.swipeRight, to: .commit)

        XCTAssertEqual(r.commit, .swipeRight)
        XCTAssertEqual(r.dismiss, .swipeLeft, "untouched")
        XCTAssertEqual(r.ignore, .swipeUp, "untouched")
        assertCanvasOneToOne(r)
    }

    /// After ANY canvas assignment the mapping is one-to-one (no excursion maps to two actions).
    func testCanvasAssignmentsStayOneToOne() {
        var c = GestureBindings.CanvasBinding.default
        for action in GestureBindings.CanvasAction.allCases {
            for excursion in GestureBindings.CanvasExcursion.allCases {
                c = c.assigning(excursion, to: action)
                XCTAssertEqual(c.excursion(for: action), excursion, "the target action holds the requested excursion")
                assertCanvasOneToOne(c)
            }
        }
    }

    // MARK: - Files: assign swaps on conflict, never double-maps

    /// Files: assigning a taken excursion swaps the two actions so the mapping stays one-to-one.
    func testFilesAssignSwapsOnConflict() {
        let f = GestureBindings.FilesDrillBinding.default   // open=lift, openWith=+1, discard=4f
        let r = f.assigning(.lift, to: .discard)

        XCTAssertEqual(r.discard, .lift, "discard now holds the requested excursion")
        XCTAssertEqual(r.open, .fourFingerHorizontal, "open inherited discard's former excursion (the swap)")
        XCTAssertEqual(r.openWith, .plusOneFingerLift, "uninvolved action untouched")
        assertFilesOneToOne(r)
    }

    /// Files: every assignment over the full vocabulary stays one-to-one (3 excursions, 3 actions).
    func testFilesAssignmentsStayOneToOne() {
        var f = GestureBindings.FilesDrillBinding.default
        for action in GestureBindings.FilesAction.allCases {
            for excursion in GestureBindings.FilesExcursion.allCases {
                f = f.assigning(excursion, to: action)
                XCTAssertEqual(f.excursion(for: action), excursion)
                assertFilesOneToOne(f)
            }
        }
    }

    // MARK: - reverseDirection accessors round-trip through the switcher binding

    /// `AxisDirection(reversed:)` / `.isReversed` are exact inverses, so the boolean accessors round-trip.
    func testAxisDirectionBooleanRoundTrip() {
        XCTAssertEqual(GestureBindings.AxisDirection(reversed: true), .reversed)
        XCTAssertEqual(GestureBindings.AxisDirection(reversed: false), .normal)
        XCTAssertTrue(GestureBindings.AxisDirection.reversed.isReversed)
        XCTAssertFalse(GestureBindings.AxisDirection.normal.isReversed)
    }

    /// The `AppSettings.reverseDirection` / `reverseVerticalDirection` computed accessors are backed by
    /// the switcher binding: writing the boolean updates the axis, and reading the binding reflects it.
    @MainActor
    func testReverseAccessorsRoundTripThroughSwitcherBinding() {
        let suite = "ThreeFingerSwitcherTests.GestureBindings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        // Defaults: both axes normal -> both booleans false.
        XCTAssertFalse(settings.reverseDirection)
        XCTAssertFalse(settings.reverseVerticalDirection)

        settings.reverseDirection = true
        XCTAssertEqual(settings.gestureBindings.switcher.windowsAxis, .reversed, "the boolean drives the windows axis")
        XCTAssertTrue(settings.reverseDirection, "and reads back through it")
        XCTAssertFalse(settings.reverseVerticalDirection, "the other axis is untouched")

        settings.reverseVerticalDirection = true
        XCTAssertEqual(settings.gestureBindings.switcher.spacesAxis, .reversed, "drives the Spaces axis")
        XCTAssertTrue(settings.reverseVerticalDirection)

        // Mutating the binding directly is reflected by the booleans (single source of truth).
        settings.gestureBindings.switcher.windowsAxis = .normal
        XCTAssertFalse(settings.reverseDirection)
    }

    /// The gesture bindings persist across `AppSettings` instances on the same suite, and a reverse
    /// choice made via the boolean accessor survives the reload (folded into the switcher binding).
    @MainActor
    func testBindingsPersistAcrossInstances() {
        let suite = "ThreeFingerSwitcherTests.GestureBindings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let writer = AppSettings(defaults: defaults)
        writer.reverseDirection = true
        writer.gestureBindings.canvas = writer.gestureBindings.canvas.assigning(.swipeRight, to: .commit)

        let reader = AppSettings(defaults: defaults)
        XCTAssertTrue(reader.reverseDirection, "the reverse choice survived the reload")
        XCTAssertEqual(reader.gestureBindings.canvas.commit, .swipeRight, "the canvas remap survived the reload")
    }

    /// `resetToDefaults()` restores every gesture binding (including the folded reverse axes) to default.
    @MainActor
    func testResetRestoresDefaultBindings() {
        let suite = "ThreeFingerSwitcherTests.GestureBindings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.reverseDirection = true
        settings.reverseVerticalDirection = true
        settings.gestureBindings.canvas = settings.gestureBindings.canvas.assigning(.swipeRight, to: .commit)
        settings.gestureBindings.filesDrill = settings.gestureBindings.filesDrill.assigning(.lift, to: .discard)

        settings.resetToDefaults()

        XCTAssertEqual(settings.gestureBindings, .default, "all bindings reset to default")
        XCTAssertFalse(settings.reverseDirection, "the folded reverse axes reset too")
        XCTAssertFalse(settings.reverseVerticalDirection)
    }

    // MARK: - Codable round-trip

    /// The whole model JSON-round-trips intact (the persistence shape used by `AppSettings`).
    func testCodableRoundTrip() throws {
        var g = GestureBindings.default
        g.canvas = g.canvas.assigning(.swipeRight, to: .commit)
        g.filesDrill = g.filesDrill.assigning(.lift, to: .discard)
        g.switcher.spacesAxis = .reversed

        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(GestureBindings.self, from: data)
        XCTAssertEqual(decoded, g)
    }

    // MARK: - Helpers

    /// Assert the canvas mapping is one-to-one: the three bound actions hold three distinct excursions.
    private func assertCanvasOneToOne(_ c: GestureBindings.CanvasBinding) {
        let bound = [c.commit, c.dismiss, c.ignore]
        XCTAssertEqual(Set(bound).count, bound.count, "no excursion is bound to two actions")
    }

    /// Assert the Files mapping is one-to-one: the three actions hold three distinct excursions.
    private func assertFilesOneToOne(_ f: GestureBindings.FilesDrillBinding) {
        let bound = [f.open, f.openWith, f.discard]
        XCTAssertEqual(Set(bound).count, bound.count, "no excursion is bound to two actions")
    }
}
