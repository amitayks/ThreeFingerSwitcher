import XCTest
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for `SwitcherLayout.contentWidth(for:withRowIndicator:)`.
///
/// The expected numbers are derived from the layout constants (asserted independently below):
///   cardInnerWidth     = 200
///   cardPadding        = 8   -> cardOuterWidth = 200 + 2*8       = 216
///   interCardSpacing   = 14
///   stripPadding       = 20  -> stripPadding*2                  = 40
///   rowIndicatorGutter = 26
///
/// contentWidth(count) = stripPadding*2
///                       + (withRowIndicator ? rowIndicatorGutter : 0)
///                       + count * cardOuterWidth
///                       + (count - 1) * interCardSpacing       (only when count > 0)
final class SwitcherLayoutTests: XCTestCase {

    // Floating-point comparison tolerance; values are integral but keep it robust.
    private let eps: CGFloat = 1e-9

    // MARK: - Constant sanity (pins the numbers the width math depends on)

    func testLayoutConstantsHaveExpectedValues() {
        // Arrange / Act / Assert
        XCTAssertEqual(SwitcherLayout.cardInnerWidth, 200, accuracy: eps)
        XCTAssertEqual(SwitcherLayout.cardPadding, 8, accuracy: eps)
        XCTAssertEqual(SwitcherLayout.interCardSpacing, 14, accuracy: eps)
        XCTAssertEqual(SwitcherLayout.stripPadding, 20, accuracy: eps)
        XCTAssertEqual(SwitcherLayout.rowIndicatorGutter, 26, accuracy: eps)
    }

    func testCardOuterWidthEqualsInnerPlusTwicePadding() {
        // cardOuterWidth = cardInnerWidth + 2 * cardPadding = 200 + 16 = 216
        XCTAssertEqual(SwitcherLayout.cardOuterWidth, 216, accuracy: eps)
        XCTAssertEqual(
            SwitcherLayout.cardOuterWidth,
            SwitcherLayout.cardInnerWidth + 2 * SwitcherLayout.cardPadding,
            accuracy: eps
        )
    }

    // MARK: - count == 0

    func testCountZeroWithoutRowIndicatorReturnsJustStripPadding() {
        // stripPadding*2 = 40, no gutter, no cards.
        let width = SwitcherLayout.contentWidth(for: 0)
        XCTAssertEqual(width, 40, accuracy: eps)
    }

    func testCountZeroWithRowIndicatorAddsGutter() {
        // stripPadding*2 + rowIndicatorGutter = 40 + 26 = 66.
        let width = SwitcherLayout.contentWidth(for: 0, withRowIndicator: true)
        XCTAssertEqual(width, 66, accuracy: eps)
    }

    func testCountZeroDefaultParameterMatchesExplicitFalse() {
        // Default value of withRowIndicator is false.
        XCTAssertEqual(
            SwitcherLayout.contentWidth(for: 0),
            SwitcherLayout.contentWidth(for: 0, withRowIndicator: false),
            accuracy: eps
        )
    }

    // MARK: - count == 1

    func testCountOneWithoutRowIndicator() {
        // 40 + 1*216 + 0*14 = 256.
        let width = SwitcherLayout.contentWidth(for: 1)
        XCTAssertEqual(width, 256, accuracy: eps)
    }

    func testCountOneWithRowIndicator() {
        // 40 + 26 + 1*216 + 0*14 = 282.
        let width = SwitcherLayout.contentWidth(for: 1, withRowIndicator: true)
        XCTAssertEqual(width, 282, accuracy: eps)
    }

    func testCountOneRowIndicatorDeltaIsExactlyGutter() {
        // Turning the indicator on adds exactly rowIndicatorGutter (26) regardless of count.
        let off = SwitcherLayout.contentWidth(for: 1, withRowIndicator: false)
        let on = SwitcherLayout.contentWidth(for: 1, withRowIndicator: true)
        XCTAssertEqual(on - off, SwitcherLayout.rowIndicatorGutter, accuracy: eps)
    }

    // MARK: - count == 2 (smallest case exercising interCardSpacing)

    func testCountTwoWithoutRowIndicator() {
        // 40 + 2*216 + 1*14 = 40 + 432 + 14 = 486.
        let width = SwitcherLayout.contentWidth(for: 2)
        XCTAssertEqual(width, 486, accuracy: eps)
    }

    func testCountTwoWithRowIndicator() {
        // 486 + 26 = 512.
        let width = SwitcherLayout.contentWidth(for: 2, withRowIndicator: true)
        XCTAssertEqual(width, 512, accuracy: eps)
    }

    // MARK: - count == N (general case)

    func testCountFiveWithoutRowIndicator() {
        // 40 + 5*216 + 4*14 = 40 + 1080 + 56 = 1176.
        let width = SwitcherLayout.contentWidth(for: 5)
        XCTAssertEqual(width, 1176, accuracy: eps)
    }

    func testCountFiveWithRowIndicator() {
        // 1176 + 26 = 1202.
        let width = SwitcherLayout.contentWidth(for: 5, withRowIndicator: true)
        XCTAssertEqual(width, 1202, accuracy: eps)
    }

    func testCountTenWithoutRowIndicator() {
        // 40 + 10*216 + 9*14 = 40 + 2160 + 126 = 2326.
        let width = SwitcherLayout.contentWidth(for: 10)
        XCTAssertEqual(width, 2326, accuracy: eps)
    }

    func testCountTenWithRowIndicator() {
        // 2326 + 26 = 2352.
        let width = SwitcherLayout.contentWidth(for: 10, withRowIndicator: true)
        XCTAssertEqual(width, 2352, accuracy: eps)
    }

    // MARK: - Formula cross-checks (independent recomputation from the constants)

    func testWidthMatchesFormulaAcrossRange() {
        let strip = SwitcherLayout.stripPadding * 2
        let outer = SwitcherLayout.cardOuterWidth
        let inter = SwitcherLayout.interCardSpacing
        let gutter = SwitcherLayout.rowIndicatorGutter

        for count in 1...12 {
            let n = CGFloat(count)
            let expectedNoGutter = strip + n * outer + (n - 1) * inter
            let expectedWithGutter = expectedNoGutter + gutter

            XCTAssertEqual(
                SwitcherLayout.contentWidth(for: count, withRowIndicator: false),
                expectedNoGutter,
                accuracy: eps,
                "count=\(count) without row indicator"
            )
            XCTAssertEqual(
                SwitcherLayout.contentWidth(for: count, withRowIndicator: true),
                expectedWithGutter,
                accuracy: eps,
                "count=\(count) with row indicator"
            )
        }
    }

    func testRowIndicatorDeltaIsConstantGutterForAllCounts() {
        for count in 0...8 {
            let off = SwitcherLayout.contentWidth(for: count, withRowIndicator: false)
            let on = SwitcherLayout.contentWidth(for: count, withRowIndicator: true)
            XCTAssertEqual(
                on - off,
                SwitcherLayout.rowIndicatorGutter,
                accuracy: eps,
                "row-indicator delta should equal the gutter for count=\(count)"
            )
        }
    }

    func testWidthIsStrictlyMonotonicInCount() {
        // Each additional card adds cardOuterWidth + interCardSpacing once count >= 1.
        var previous = SwitcherLayout.contentWidth(for: 1)
        for count in 2...12 {
            let current = SwitcherLayout.contentWidth(for: count)
            XCTAssertGreaterThan(current, previous, "width must increase with count (count=\(count))")
            XCTAssertEqual(
                current - previous,
                SwitcherLayout.cardOuterWidth + SwitcherLayout.interCardSpacing,
                accuracy: eps,
                "per-card increment should be cardOuterWidth + interCardSpacing (count=\(count))"
            )
            previous = current
        }
    }
}
