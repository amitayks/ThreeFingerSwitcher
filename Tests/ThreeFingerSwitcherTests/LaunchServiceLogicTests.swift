import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the pure decision logic of `LaunchService` (no system access): app-strategy
/// resolution (item override → band default; non-app → nil) and preset flattening (ordered,
/// cycle-safe, depth-first through nested presets).
final class LaunchServiceLogicTests: XCTestCase {

    private func app(_ strategy: AppStrategy?) -> LaunchItem {
        LaunchItem(title: "App", icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/X.app"), strategy: strategy))
    }

    // MARK: - resolvedStrategy

    func testItemOverrideWinsOverBandDefault() {
        let item = app(.alwaysNewWindow)
        XCTAssertEqual(LaunchService.resolvedStrategy(for: item, bandDefault: .bringExistingHere), .alwaysNewWindow)
    }

    func testItemInheritsBandDefaultWhenUnset() {
        let item = app(nil)
        XCTAssertEqual(LaunchService.resolvedStrategy(for: item, bandDefault: .bringExistingHere), .bringExistingHere)
    }

    func testNonAppKindHasNoStrategy() {
        let path = LaunchItem(title: "P", icon: .fileIcon, kind: .path(URL(fileURLWithPath: "/tmp")))
        let script = LaunchItem(title: "S", icon: .appDefault, kind: .script(.shell("ls")))
        XCTAssertNil(LaunchService.resolvedStrategy(for: path, bandDefault: .smart))
        XCTAssertNil(LaunchService.resolvedStrategy(for: script, bandDefault: .smart))
    }

    // MARK: - presetFireOrder

    func testPresetFiresLeafItemsInStoredOrder() {
        let a = app(nil)
        let b = LaunchItem(title: "Folder", icon: .fileIcon, kind: .path(URL(fileURLWithPath: "/tmp")))
        let c = LaunchItem(title: "Script", icon: .appDefault, kind: .script(.shell("echo")))
        let preset = LaunchItem(title: "Work", icon: .emoji("🧑‍💻"), kind: .preset(itemIDs: [a.id, b.id, c.id]))
        let band = ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1), items: [a, b, c, preset])
        let fav = Favorites(bands: [band])

        let order = LaunchService.presetFireOrder(preset, in: fav)
        XCTAssertEqual(order.map(\.id), [a.id, b.id, c.id])
    }

    func testNestedPresetExpandsDepthFirst() {
        let a = app(nil)
        let b = LaunchItem(title: "B", icon: .fileIcon, kind: .path(URL(fileURLWithPath: "/b")))
        let inner = LaunchItem(title: "Inner", icon: .emoji("➡️"), kind: .preset(itemIDs: [a.id, b.id]))
        let c = LaunchItem(title: "C", icon: .fileIcon, kind: .path(URL(fileURLWithPath: "/c")))
        let outer = LaunchItem(title: "Outer", icon: .emoji("📦"), kind: .preset(itemIDs: [inner.id, c.id]))
        let band = ContextBand(name: "B", color: ItemColor(red: 0, green: 0, blue: 0), items: [a, b, inner, c, outer])
        let fav = Favorites(bands: [band])

        let order = LaunchService.presetFireOrder(outer, in: fav)
        XCTAssertEqual(order.map(\.id), [a.id, b.id, c.id], "nested preset flattens depth-first, in order")
    }

    func testCyclicPresetTerminates() {
        // Two presets referencing each other must not loop forever.
        let leaf = app(nil)
        let p1ID = UUID(); let p2ID = UUID()
        let p1 = LaunchItem(id: p1ID, title: "P1", icon: .emoji("1"), kind: .preset(itemIDs: [leaf.id, p2ID]))
        let p2 = LaunchItem(id: p2ID, title: "P2", icon: .emoji("2"), kind: .preset(itemIDs: [p1ID]))
        let band = ContextBand(name: "C", color: ItemColor(red: 0, green: 0, blue: 0), items: [leaf, p1, p2])
        let fav = Favorites(bands: [band])

        let order = LaunchService.presetFireOrder(p1, in: fav)
        XCTAssertEqual(order.map(\.id), [leaf.id], "cycle guard stops re-entry; only the leaf fires")
    }

    func testSelfReferencingPresetTerminates() {
        let selfID = UUID()
        let p = LaunchItem(id: selfID, title: "P", icon: .emoji("∞"), kind: .preset(itemIDs: [selfID]))
        let band = ContextBand(name: "C", color: ItemColor(red: 0, green: 0, blue: 0), items: [p])
        let fav = Favorites(bands: [band])
        XCTAssertEqual(LaunchService.presetFireOrder(p, in: fav).count, 0, "a self-referencing preset fires nothing, no hang")
    }

    func testMissingReferenceIsSkipped() {
        let a = app(nil)
        let preset = LaunchItem(title: "P", icon: .emoji("P"), kind: .preset(itemIDs: [a.id, UUID()]))
        let band = ContextBand(name: "C", color: ItemColor(red: 0, green: 0, blue: 0), items: [a, preset])
        let fav = Favorites(bands: [band])
        XCTAssertEqual(LaunchService.presetFireOrder(preset, in: fav).map(\.id), [a.id], "dangling references are skipped")
    }

    func testPromptStartDirectoryPrefersLastFolderElseHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        let last = URL(fileURLWithPath: "/tmp/proj")
        XCTAssertEqual(LaunchService.promptStartDirectory(lastFolder: last, home: home), last,
                       "the chooser opens at the remembered last folder when set")
        XCTAssertEqual(LaunchService.promptStartDirectory(lastFolder: nil, home: home), home,
                       "and at home when no folder has been chosen yet")
    }
}
