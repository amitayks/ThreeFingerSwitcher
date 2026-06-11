import XCTest
@testable import ThreeFingerSwitcherCore

/// Invariant tests for the shipped AI command catalog (task §2.9 + review hardening). These guard the
/// catalog as the single source of truth: every preset is fireable, every category is represented, the
/// curated `seeded()` subset resolves by name, and category-wide output/input conventions hold (e.g.
/// vision presets are preview-only, `{lang}` presets declare a language parameter). A failure here is a
/// real catalog inconsistency, not a unit under test.
final class AICommandCatalogTests: XCTestCase {

    // MARK: - Fireability

    func testEveryPresetIsFireable() {
        for entry in AICommandCatalog.entries {
            XCTAssertFalse(entry.command.name.isEmpty,
                           "every preset has a non-empty name")
            XCTAssertFalse(entry.command.promptTemplate.isEmpty,
                           "preset \(entry.command.name) has a non-empty prompt template")
        }
    }

    // MARK: - Coverage

    func testAllCategoriesPresent() {
        for category in AICommandCatalog.Category.allCases {
            XCTAssertFalse(AICommandCatalog.commands(in: category).isEmpty,
                           "category \(category.title) has at least one preset")
        }
        XCTAssertEqual(AICommandCatalog.Category.allCases.count, 9,
                       "all 9 categories are declared")
        XCTAssertGreaterThanOrEqual(AICommandCatalog.entries.count, 50,
                                    "the catalog ships a substantial set of presets")
    }

    // MARK: - copy(of:)

    func testCopyMintsFreshIdWithoutMutatingOriginal() {
        let original = AICommandCatalog.entries[0].command
        let first = AICommandCatalog.copy(of: original)
        let second = AICommandCatalog.copy(of: original)

        XCTAssertNotEqual(first.id, second.id, "each copy mints a distinct id")
        XCTAssertNotEqual(first.id, original.id, "the first copy differs from the original's id")
        XCTAssertNotEqual(second.id, original.id, "the second copy differs from the original's id")

        for copy in [first, second] {
            XCTAssertEqual(copy.name, original.name, "copy preserves the name")
            XCTAssertEqual(copy.promptTemplate, original.promptTemplate, "copy preserves the template")
            XCTAssertEqual(copy.input, original.input, "copy preserves the input source")
            XCTAssertEqual(copy.output, original.output, "copy preserves the output target")
        }
    }

    // MARK: - Category conventions

    func testVisionPresetsArePreviewOnlyScreenRegion() {
        let vision = AICommandCatalog.commands(in: .vision)
        XCTAssertFalse(vision.isEmpty, "the vision category ships presets")
        for command in vision {
            XCTAssertEqual(command.input, .screenRegion,
                           "vision preset \(command.name) reads a screen region")
            XCTAssertEqual(command.output, .previewOnly,
                           "vision preset \(command.name) is preview-only")
        }
    }

    func testLangPresetsDeclareLanguageParameter() {
        let langPresets = AICommandCatalog.entries
            .map(\.command)
            .filter { $0.promptTemplate.contains("{lang}") }
        XCTAssertFalse(langPresets.isEmpty, "at least one preset uses the {lang} token")
        for command in langPresets {
            // `languageDefault` is non-nil for any `.languageChoice` (human OR programming language),
            // so this guards every `{lang}` preset without pattern-matching a specific case.
            XCTAssertNotNil(command.runtimeParameter?.languageDefault,
                            "preset \(command.name) uses {lang} so it declares a language-choice parameter")
        }
    }

    func testCommentaryPresetsArePreviewOnly() {
        let understand = AICommandCatalog.commands(in: .understand)
        XCTAssertFalse(understand.isEmpty, "the understand category ships presets")
        for command in understand {
            XCTAssertEqual(command.output, .previewOnly,
                           "understand preset \(command.name) is preview-only")
        }
    }

    // MARK: - seeded()

    func testSeededResolvesAllCuratedNames() {
        let expected = ["Fix Grammar", "Make Concise", "Improve Writing", "Translate",
                        "Explain", "Summarize", "Draft a Reply", "Add to Calendar"]
        let seeded = AICommandCatalog.seeded()
        XCTAssertEqual(seeded.count, expected.count,
                       "seeded() resolves every curated name (a typo'd name would silently drop)")
        XCTAssertEqual(seeded.map(\.name), expected,
                       "seeded() emits the curated commands in the curated order")
    }
}
