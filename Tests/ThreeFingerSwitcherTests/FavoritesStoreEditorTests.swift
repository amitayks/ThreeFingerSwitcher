import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the editor mutations on `FavoritesStore` (used by the favorites editor): add/remove/
/// reorder bands and items, in-place band/item edits, and that every mutation persists immediately.
@MainActor
final class FavoritesStoreEditorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThreeFingerSwitcherTests.FavoritesEditor.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    private func emptyStore() -> FavoritesStore {
        let store = FavoritesStore(defaults: defaults)
        store.mutate { $0.bands = [] }   // start from a known-empty tree (ignore the first-run seed)
        return store
    }

    private func gray() -> ItemColor { ItemColor(red: 0.5, green: 0.5, blue: 0.5) }
    private func appItem(_ name: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), strategy: nil))
    }

    // MARK: - Bands

    func testAddBandReturnsIdAndAppends() {
        let store = emptyStore()
        let id = store.addBand(name: "Dev", color: gray())
        XCTAssertEqual(store.favorites.bands.count, 1)
        XCTAssertEqual(store.favorites.bands.first?.id, id)
        XCTAssertEqual(store.favorites.bands.first?.name, "Dev")
    }

    func testRemoveBandAlsoClearsHomeBand() {
        let store = emptyStore()
        let id = store.addBand(name: "Dev", color: gray())
        store.mutate { $0.homeBandID = id }
        store.removeBand(id)
        XCTAssertTrue(store.favorites.bands.isEmpty)
        XCTAssertNil(store.favorites.homeBandID)
    }

    func testMoveBandsReordersStoredOrder() {
        let store = emptyStore()
        _ = store.addBand(name: "A", color: gray())
        _ = store.addBand(name: "B", color: gray())
        let c = store.addBand(name: "C", color: gray())
        store.moveBands(fromOffsets: IndexSet(integer: 2), toOffset: 0)   // C to front
        XCTAssertEqual(store.favorites.bands.first?.id, c)
        XCTAssertEqual(store.favorites.bands.map(\.name), ["C", "A", "B"])
    }

    func testUpdateBandEditsInPlace() {
        let store = emptyStore()
        let id = store.addBand(name: "Dev", color: gray())
        store.updateBand(id) { $0.name = "Development"; $0.defaultAppStrategy = .quitAndReopenHere }
        XCTAssertEqual(store.favorites.bands.first?.name, "Development")
        XCTAssertEqual(store.favorites.bands.first?.defaultAppStrategy, .quitAndReopenHere)
    }

    // MARK: - Items

    func testReorderItemsWithinBand() {
        let store = emptyStore()
        let band = store.addBand(name: "Dev", color: gray())
        store.addItem(appItem("Alpha"), toBand: band)
        store.addItem(appItem("Bravo"), toBand: band)
        store.addItem(appItem("Charlie"), toBand: band)
        store.moveItems(inBand: band, fromOffsets: IndexSet(integer: 0), toOffset: 3)   // Alpha to end
        XCTAssertEqual(store.favorites.bands.first?.items.map(\.title), ["Bravo", "Charlie", "Alpha"])
    }

    func testRemoveItemByID() {
        let store = emptyStore()
        let band = store.addBand(name: "Dev", color: gray())
        let target = appItem("Bravo")
        store.addItem(appItem("Alpha"), toBand: band)
        store.addItem(target, toBand: band)
        store.removeItem(target.id, fromBand: band)
        XCTAssertEqual(store.favorites.bands.first?.items.map(\.title), ["Alpha"])
    }

    func testUpdateItemTitleAndStrategy() {
        let store = emptyStore()
        let band = store.addBand(name: "Dev", color: gray())
        let item = appItem("Alpha")
        store.addItem(item, toBand: band)
        store.updateItem(item.id, inBand: band) { i in
            i.title = "Renamed"
            if case let .app(url, _) = i.kind { i.kind = .app(bundleURL: url, strategy: .alwaysNewWindow) }
        }
        let stored = store.favorites.bands.first?.items.first
        XCTAssertEqual(stored?.title, "Renamed")
        XCTAssertEqual(LaunchService.resolvedStrategy(for: stored!, bandDefault: .smart), .alwaysNewWindow)
    }

    // MARK: - Persistence

    func testMutationsPersistImmediately() {
        let store = emptyStore()
        let band = store.addBand(name: "Dev", color: gray())
        store.addItem(appItem("Alpha"), toBand: band)

        // A fresh store over the same defaults must see the edits (no explicit save needed).
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favorites.bands.map(\.name), ["Dev"])
        XCTAssertEqual(reloaded.favorites.bands.first?.items.map(\.title), ["Alpha"])
    }
}
