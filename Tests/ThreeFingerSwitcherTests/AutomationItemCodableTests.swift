import XCTest
@testable import ThreeFingerSwitcherCore

/// Backward-compatible persistence for the new `.automation` launch-item kind (spec: `launch-items`).
/// The associated `AutomationKind` is a plain synthesized-`Codable` enum, so no `Favorites` schema bump
/// is needed and pre-automation favorites decode unchanged (the `.url`/`.action` optional-value precedent).
@MainActor
final class AutomationItemCodableTests: XCTestCase {

    func testAutomationItemRoundTrips() throws {
        // No dim level set → decodes back with nil (interpreted as minimum).
        let item = LaunchItem(title: "Keep Awake",
                              icon: .sfSymbol("cup.and.saucer.fill"),
                              kind: .automation(.keepAwake))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: data)
        XCTAssertEqual(decoded, item)
        guard case let .automation(kind, dimPercent, _, _) = decoded.kind else {
            return XCTFail("expected .automation, got \(decoded.kind)")
        }
        XCTAssertEqual(kind, .keepAwake)
        XCTAssertNil(dimPercent, "no dim level set → nil (minimum)")
    }

    func testAutomationItemWithDimLevelRoundTrips() throws {
        let item = LaunchItem(title: "Keep Awake",
                              icon: .sfSymbol("cup.and.saucer.fill"),
                              kind: .automation(.keepAwake, dimPercent: 30))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: data)
        XCTAssertEqual(decoded, item)
        guard case let .automation(kind, dimPercent, _, _) = decoded.kind else {
            return XCTFail("expected .automation, got \(decoded.kind)")
        }
        XCTAssertEqual(kind, .keepAwake)
        XCTAssertEqual(dimPercent, 30)
    }

    /// The `keep-awake-guard-effects` options ride the same decode-safe optional pattern.
    func testAutomationItemWithOptionsRoundTrips() throws {
        let item = LaunchItem(title: "Keep Awake",
                              icon: .sfSymbol("cup.and.saucer.fill"),
                              kind: .automation(.keepAwake, dimPercent: 30,
                                                dimKeyboard: true, lockOnStop: true))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: data)
        XCTAssertEqual(decoded, item)
        guard case let .automation(_, dimPercent, dimKeyboard, lockOnStop) = decoded.kind else {
            return XCTFail("expected .automation, got \(decoded.kind)")
        }
        XCTAssertEqual(dimPercent, 30)
        XCTAssertEqual(dimKeyboard, true)
        XCTAssertEqual(lockOnStop, true)
    }

    /// An item encoded WITHOUT the options (nil → key omitted) is byte-identical to a pre-option
    /// record, so this doubles as the legacy-decode proof: absent keys decode to nil (= off).
    func testAutomationItemWithoutOptionsDecodesToNilOptions() throws {
        let item = LaunchItem(title: "Keep Awake",
                              icon: .sfSymbol("cup.and.saucer.fill"),
                              kind: .automation(.keepAwake, dimPercent: 30))
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: data)
        guard case let .automation(_, dimPercent, dimKeyboard, lockOnStop) = decoded.kind else {
            return XCTFail("expected .automation, got \(decoded.kind)")
        }
        XCTAssertEqual(dimPercent, 30)
        XCTAssertNil(dimKeyboard, "absent option decodes to nil (off)")
        XCTAssertNil(lockOnStop, "absent option decodes to nil (off)")
    }

    func testAutomationKindRoundTrips() throws {
        for kind in AutomationKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(AutomationKind.self, from: data), kind)
        }
    }

    /// Favorites written before automations existed (here: an ordinary `.action` item and an `.app`)
    /// still decode — the new case adds no required field and no schema bump.
    func testLegacyFavoritesStillDecode() throws {
        let legacy = ContextBand(
            name: "Work",
            color: ItemColor(red: 0.2, green: 0.4, blue: 0.9),
            items: [
                LaunchItem(title: "Mute", icon: .sfSymbol("speaker.slash.fill"), kind: .action(.mute)),
                LaunchItem(title: "Notes", icon: .appDefault,
                           kind: .app(bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app"), strategy: nil))
            ])
        let favorites = Favorites(bands: [legacy])
        let data = try JSONEncoder().encode(favorites)
        let decoded = try JSONDecoder().decode(Favorites.self, from: data)
        XCTAssertEqual(decoded, favorites)
    }
}
