import XCTest
import OpenMultitouchSupport
@testable import ThreeFingerSwitcherCore

/// Unit tests for `TouchEngine.isContact`, the static contact-state classifier that
/// decides whether a raw `OMSState` represents a finger physically on the trackpad.
///
/// Contract under test (see TouchEngine.swift):
///   - Contacts (true):      .starting, .making, .touching, .lingering
///   - Non-contacts (false): .notTouching, .hovering, .breaking, .leaving
///
/// `TouchEngine` is `@MainActor`, so `isContact` is main-actor-isolated; every test
/// method that calls it is annotated `@MainActor`.
final class TouchEngineTests: XCTestCase {

    // MARK: - Contacts (expected true)

    @MainActor
    func testStartingIsContact() {
        // Arrange
        let state = OMSState.starting
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertTrue(result, ".starting must be classified as a contact")
    }

    @MainActor
    func testMakingIsContact() {
        // Arrange
        let state = OMSState.making
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertTrue(result, ".making must be classified as a contact")
    }

    @MainActor
    func testTouchingIsContact() {
        // Arrange
        let state = OMSState.touching
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertTrue(result, ".touching must be classified as a contact")
    }

    @MainActor
    func testLingeringIsContact() {
        // Arrange
        let state = OMSState.lingering
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertTrue(result, ".lingering must be classified as a contact")
    }

    // MARK: - Non-contacts (expected false)

    @MainActor
    func testNotTouchingIsNotContact() {
        // Arrange
        let state = OMSState.notTouching
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertFalse(result, ".notTouching must NOT be classified as a contact")
    }

    @MainActor
    func testHoveringIsNotContact() {
        // Arrange
        let state = OMSState.hovering
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertFalse(result, ".hovering must NOT be classified as a contact")
    }

    @MainActor
    func testBreakingIsNotContact() {
        // Arrange
        let state = OMSState.breaking
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertFalse(result, ".breaking must NOT be classified as a contact")
    }

    @MainActor
    func testLeavingIsNotContact() {
        // Arrange
        let state = OMSState.leaving
        // Act
        let result = TouchEngine.isContact(state)
        // Assert
        XCTAssertFalse(result, ".leaving must NOT be classified as a contact")
    }

    // MARK: - Exhaustive / data-driven coverage of every OMSState case

    /// Drives `isContact` over the full, explicitly enumerated set of `OMSState`
    /// values and asserts each against its expected classification. This guards
    /// against a case being accidentally re-classified.
    @MainActor
    func testAllStatesClassifiedAsExpected() {
        // Arrange: the complete, hand-maintained truth table.
        let expectations: [(state: OMSState, isContact: Bool)] = [
            (.starting, true),
            (.making, true),
            (.touching, true),
            (.lingering, true),
            (.notTouching, false),
            (.hovering, false),
            (.breaking, false),
            (.leaving, false),
        ]

        // Act + Assert
        for (state, expected) in expectations {
            XCTAssertEqual(
                TouchEngine.isContact(state),
                expected,
                "isContact(\(state.rawValue)) should be \(expected)"
            )
        }
    }

    /// Sanity check on the truth table itself: exactly 4 contact states and
    /// 4 non-contact states, totalling the 8 known `OMSState` cases. If a new
    /// state is added to `OMSState`, this count becomes a prompt to revisit
    /// the classifier and these tests.
    @MainActor
    func testContactPartitionCounts() {
        // Arrange
        let knownStates: [OMSState] = [
            .notTouching, .starting, .hovering, .making,
            .touching, .breaking, .lingering, .leaving,
        ]

        // Act
        let contacts = knownStates.filter { TouchEngine.isContact($0) }
        let nonContacts = knownStates.filter { !TouchEngine.isContact($0) }

        // Assert
        XCTAssertEqual(knownStates.count, 8, "OMSState is expected to have exactly 8 cases")
        XCTAssertEqual(contacts.count, 4, "Exactly 4 states should classify as contacts")
        XCTAssertEqual(nonContacts.count, 4, "Exactly 4 states should classify as non-contacts")
        XCTAssertEqual(
            Set(contacts.map { $0.rawValue }),
            Set(["starting", "making", "touching", "lingering"]),
            "Contact set must be exactly {starting, making, touching, lingering}"
        )
        XCTAssertEqual(
            Set(nonContacts.map { $0.rawValue }),
            Set(["notTouching", "hovering", "breaking", "leaving"]),
            "Non-contact set must be exactly {notTouching, hovering, breaking, leaving}"
        )
    }

    // MARK: - Determinism

    /// `isContact` is a pure function: repeated calls with the same input must
    /// return the same result, with no order- or call-count-dependence.
    @MainActor
    func testIsContactIsDeterministic() {
        // Arrange
        let states: [OMSState] = [
            .starting, .making, .touching, .lingering,
            .notTouching, .hovering, .breaking, .leaving,
        ]

        // Act + Assert
        for state in states {
            let first = TouchEngine.isContact(state)
            let second = TouchEngine.isContact(state)
            let third = TouchEngine.isContact(state)
            XCTAssertEqual(first, second, "isContact(\(state.rawValue)) must be stable across calls")
            XCTAssertEqual(second, third, "isContact(\(state.rawValue)) must be stable across calls")
        }
    }
}
