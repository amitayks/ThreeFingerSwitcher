import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the playground tour's fixed band composition (Onboarding/WizardTourBands.swift):
/// flame (every app across the user's bands, deduped), display (the twelve window actions),
/// sparkles only when AI is on, clipboard only when provided — and nothing more.
final class WizardTourBandsTests: XCTestCase {
    private func app(_ name: String, _ path: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: path), strategy: nil))
    }

    private func userBands() -> [ContextBand] {
        [
            ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1), items: [
                app("Terminal", "/Apps/Terminal.app"),
                LaunchItem(title: "Site", icon: .sfSymbol("globe"),
                           kind: .url(URL(string: "https://example.com")!))
            ]),
            ContextBand(name: "Comms", color: ItemColor(red: 0, green: 1, blue: 0), items: [
                app("Mail", "/Apps/Mail.app"),
                app("Terminal", "/Apps/Terminal.app")   // duplicate across bands
            ])
        ]
    }

    private func seededAI() -> ContextBand {
        ContextBand(name: "AI", color: ItemColor(red: 1, green: 0, blue: 1),
                    icon: .sfSymbol("sparkles"),
                    items: [LaunchItem(title: "Seeded", icon: .sfSymbol("sparkles"),
                                       kind: .script(.shell("echo")))])
    }

    func testBaseCompositionIsFlameThenDisplayAndNothingMore() {
        let bands = WizardTourBands.compose(userBands: userBands(), aiOn: false,
                                            seededAIBand: seededAI, clipboardBand: nil)
        XCTAssertEqual(bands.count, 2, "flame + display — nothing more")
        XCTAssertEqual(bands[0].icon, .sfSymbol("flame.fill"))
        XCTAssertEqual(bands[1].icon, .sfSymbol("display"))
    }

    func testFlameGathersEveryAppOnceAndOnlyApps() {
        let bands = WizardTourBands.compose(userBands: userBands(), aiOn: false,
                                            seededAIBand: seededAI, clipboardBand: nil)
        let flame = bands[0]
        XCTAssertEqual(flame.items.map(\.title), ["Terminal", "Mail"],
                       "deduped by bundle URL, original order, URLs/scripts excluded")
        for item in flame.items {
            guard case .app = item.kind else { return XCTFail("flame holds apps only") }
        }
    }

    func testDisplayHoldsExactlyTheTwelveWindowActions() {
        let bands = WizardTourBands.compose(userBands: [], aiOn: false,
                                            seededAIBand: seededAI, clipboardBand: nil)
        let display = bands[1]
        XCTAssertEqual(display.items.count, 12, "two exact rows of the six-column grid")
        for item in display.items {
            guard case let .action(action, _, _) = item.kind else {
                return XCTFail("display holds system actions only")
            }
            XCTAssertEqual(action.category, .window, "every action manages windows")
        }
        XCTAssertEqual(Set(WizardTourBands.windowActions).count, 12, "no duplicates")
    }

    func testAIBandUsesTheUsersOwnCommandsWhenTheyHaveAny() {
        var bands = userBands()
        let owned = LaunchItem(title: "My command", icon: .sfSymbol("sparkles"),
                               kind: .aiCommand(AICommand(name: "My command",
                                                          icon: .sfSymbol("sparkles"),
                                                          input: .selection,
                                                          promptTemplate: "{selection}",
                                                          output: .replaceSelection)))
        bands[0].items.append(owned)
        let composed = WizardTourBands.compose(userBands: bands, aiOn: true,
                                               seededAIBand: seededAI, clipboardBand: nil)
        XCTAssertEqual(composed.count, 3)
        XCTAssertEqual(composed[2].items.map(\.title), ["My command"])
    }

    func testAIBandFallsBackToTheSeededSet() {
        let composed = WizardTourBands.compose(userBands: userBands(), aiOn: true,
                                               seededAIBand: seededAI, clipboardBand: nil)
        XCTAssertEqual(composed[2].items.map(\.title), ["Seeded"])
    }

    func testClipboardBandComesLastWhenProvided() {
        let clipboard = ClipboardBandBuilder.build(from: WizardSampleContent.clipboardEntries())
        let composed = WizardTourBands.compose(userBands: userBands(), aiOn: true,
                                               seededAIBand: seededAI, clipboardBand: clipboard)
        XCTAssertEqual(composed.count, 4)
        XCTAssertTrue(ClipboardBandBuilder.isClipboardBand(composed[3]))
    }
}
