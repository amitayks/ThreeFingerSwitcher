import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure `GestureBindings` model (Gesture/GestureBindings.swift) and its persistence
/// through `AppSettings`.
///
/// Covers: defaults reproduce today's behavior; the `reverseDirection` / `reverseVerticalDirection`
/// accessors round-trip through the switcher binding; persistence + reset; Codable round-trip (including
/// tolerance of retired surfaces' extra keys in older stored blobs).
final class GestureBindingsTests: XCTestCase {

    // MARK: - Defaults reproduce today's behavior

    /// The switcher default is both axes normal (no reversal) — exactly today's behavior.
    func testSwitcherDefaultsAreBothAxesNormal() {
        let s = GestureBindings.SwitcherBinding.default
        XCTAssertEqual(s.windowsAxis, .normal)
        XCTAssertEqual(s.spacesAxis, .normal)
        XCTAssertFalse(s.windowsAxis.isReversed)
        XCTAssertFalse(s.spacesAxis.isReversed)
    }

    /// The aggregate default wires the switcher surface to its per-surface default.
    func testAggregateDefaultComposesPerSurfaceDefaults() {
        let g = GestureBindings.default
        XCTAssertEqual(g.switcher, .default)
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

        let reader = AppSettings(defaults: defaults)
        XCTAssertTrue(reader.reverseDirection, "the reverse choice survived the reload")
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

        settings.resetToDefaults()

        XCTAssertEqual(settings.gestureBindings, .default, "all bindings reset to default")
        XCTAssertFalse(settings.reverseDirection, "the folded reverse axes reset too")
        XCTAssertFalse(settings.reverseVerticalDirection)
    }

    // MARK: - Codable round-trip

    /// The whole model JSON-round-trips intact (the persistence shape used by `AppSettings`).
    func testCodableRoundTrip() throws {
        var g = GestureBindings.default
        g.switcher.spacesAxis = .reversed

        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(GestureBindings.self, from: data)
        XCTAssertEqual(decoded, g)
    }

    /// An OLDER stored blob still carries the retired canvas / files-drill surfaces as extra JSON keys;
    /// decoding must ignore them and keep the switcher binding (JSONDecoder skips unknown keys).
    func testOlderBlobWithRetiredSurfacesStillDecodes() throws {
        let legacy = """
        {"canvas":{"commit":"swipeDown","dismiss":"swipeLeft","ignore":"swipeUp"},
         "filesDrill":{"open":"lift","openWith":"plusOneFingerLift","discard":"fourFingerHorizontal"},
         "switcher":{"windowsAxis":"reversed","spacesAxis":"normal"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GestureBindings.self, from: legacy)
        XCTAssertEqual(decoded.switcher.windowsAxis, .reversed, "the switcher binding survives")
        XCTAssertEqual(decoded.switcher.spacesAxis, .normal)
    }
}
